# splunk-infra

Scripts for building an on-prem Splunk Enterprise deployment and connecting
forwarders to it.

| Script | Platform | Purpose |
|---|---|---|
| `indexer/setup-indexer.sh` | Linux | New indexer: standalone, cluster manager or cluster peer |
| `forwarder/deploy-universal-forwarder.sh` | Linux | Install and configure a Universal Forwarder |
| `forwarder/Deploy-UniversalForwarder.ps1` | Windows | Install and configure a Universal Forwarder |

All scripts are re-runnable and write their settings to a dedicated app
(`org_*`) rather than `etc/system/local`.

## Build order

1. **Indexers** — either one standalone indexer, or a cluster manager followed
   by its peers.
2. **Forwarders** — point them at the standalone indexer or at the peers.

## Indexers

Needs the Splunk Enterprise package (`splunk-*.tgz/.deb/.rpm`, not the
forwarder package), version 9.0 or later.

### Standalone

```bash
export SPLUNK_PASSWORD='choose-a-strong-password'

sudo -E ./indexer/setup-indexer.sh --role standalone \
  --package-file ./splunk-9.3.1-0b8d769cb912-Linux-x86_64.tgz \
  --index linux_os:500000 --index wineventlog \
  --license-file ./splunk-enterprise.lic \
  --open-firewall
```

Receives forwarder data on 9997, Splunk Web on 8000. `--index NAME:MAX_MB`
caps an index's size; without a cap Splunk's default (500 GB) applies.

### Indexer cluster

Use the same `SPLUNK_CLUSTER_SECRET` on every member.

```bash
export SPLUNK_PASSWORD='choose-a-strong-password'
export SPLUNK_CLUSTER_SECRET='long-random-shared-secret'

# 1. Manager node
sudo -E ./indexer/setup-indexer.sh --role manager \
  --package-file ./splunk-9.3.1-0b8d769cb912-Linux-x86_64.tgz \
  --replication-factor 3 --search-factor 2 --cluster-label prod \
  --index linux_os --index wineventlog \
  --license-manager https://splunk-lm.corp.local:8089 \
  --open-firewall

# 2. Each peer (at least as many as the replication factor)
sudo -E ./indexer/setup-indexer.sh --role peer \
  --package-file ./splunk-9.3.1-0b8d769cb912-Linux-x86_64.tgz \
  --manager-uri https://splunk-cm.corp.local:8089 \
  --license-manager https://splunk-lm.corp.local:8089 \
  --open-firewall

# 3. Back on the manager, once the peers have joined
sudo -u splunk /opt/splunk/bin/splunk apply cluster-bundle --answer-yes
sudo -u splunk /opt/splunk/bin/splunk show cluster-status
```

- Indexes and the 9997 receiving input are defined on the manager in
  `etc/manager-apps/org_all_indexers` and pushed to every peer. To add an
  index, re-run the manager step with the full `--index` list. The script
  applies the bundle for you unless you pass `--skip-bundle-apply`.
- Peers run with Splunk Web turned off and replicate buckets to each other
  on 9887.
- Single-site clustering only. Search heads, multisite and SmartStore are not
  set up by this script.

### What the indexer script also does

- Disables Transparent Huge Pages (a systemd unit that persists across
  reboots), as Splunk recommends for indexers.
- Warns if there's less than 50 GB free under the install directory.
- Runs Splunk as the `splunk` user with systemd boot-start. The generated
  unit sets the file and process limits.
- `--open-firewall` opens only the role's ports in firewalld or ufw:

  | Role | Ports |
  |---|---|
  | standalone | 8000, 8089, 9997 |
  | manager | 8000, 8089 |
  | peer | 8089, 9997, 9887 |

Run `./indexer/setup-indexer.sh --help` for every option.

## Forwarders

### Prerequisites on the Splunk Enterprise side


- Receiving enabled on each indexer. `indexer/setup-indexer.sh` does this
  for you; otherwise use `splunk enable listen 9997`.
- Any indexes referenced by `--monitor` already exist on the indexers.
- Firewall open from the forwarder to the indexers (9997) and the deployment
  server (8089), if used.

### Usage (Linux)

Download the forwarder package (.tgz, .deb or .rpm) from splunk.com, or copy its
download URL, then:

```bash
export SPLUNK_PASSWORD='choose-a-strong-password'

sudo -E ./forwarder/deploy-universal-forwarder.sh \
  --package-file ./splunkforwarder-9.3.1-0b8d769cb912-Linux-x86_64.tgz \
  --indexers "splunk-idx01.corp.local:9997,splunk-idx02.corp.local:9997" \
  --deployment-server "splunk-ds.corp.local:8089" \
  --monitor "/var/log/syslog:linux_os:syslog" \
  --monitor "/var/log/auth.log:linux_secure:linux_secure"
```

Run `./forwarder/deploy-universal-forwarder.sh --help` for all options (TLS, custom
install path, service account, client name, reinstall).

### Usage (Windows)

From an elevated PowerShell prompt:

```powershell
.\forwarder\Deploy-UniversalForwarder.ps1 `
  -PackageFile .\splunkforwarder-9.3.1-0b8d769cb912-x64-release.msi `
  -Indexers 'splunk-idx01.corp.local:9997','splunk-idx02.corp.local:9997' `
  -DeploymentServer 'splunk-ds.corp.local:8089' `
  -WinEventLogs Application,System,Security -EventLogIndex wineventlog `
  -Monitor 'C:\inetpub\logs\LogFiles|iis|ms:iis:auto'
```

You are prompted for the admin password, or pass `-AdminPassword` as a
SecureString. `-Monitor` uses `|` as its separator because Windows paths
contain `:`. Run `Get-Help .\forwarder\Deploy-UniversalForwarder.ps1 -Full` for all
options (TLS, `-UseLocalSystem`, install dir, reinstall).

If execution policy blocks the script, run it with
`powershell -ExecutionPolicy Bypass -File .\forwarder\Deploy-UniversalForwarder.ps1 ...`.

### Notes

Config is written to an app at `etc/apps/org_uf_base/local/` under the install directory
instead of `etc/system/local`, so the deployment server can take it over later.

### Verify

On the search head:

```
index=_internal host=<forwarder-hostname> sourcetype=splunkd | head 10
```
