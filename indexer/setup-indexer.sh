#!/usr/bin/env bash
#
# setup-indexer.sh
#
# Builds a new Splunk Enterprise indexer instance on Linux, in one of three
# roles:
#
#   standalone  Single indexer: receives forwarder data on 9997, holds indexes,
#               Splunk Web on 8000.
#   manager     Indexer cluster manager node. Holds the cluster config and the
#               configuration bundle (indexes + receiving input) that it pushes
#               to every peer. Does not index forwarder data itself.
#   peer        Indexer cluster peer. Joins the manager, gets its indexes and
#               receiving input from the manager's bundle, Splunk Web disabled.
#
# Build order for a cluster: manager first, then each peer, then point
# forwarders at the peers.
#
# Supports .tgz, .deb and .rpm packages, either from a local file or a URL.
# Safe to re-run: config files are rewritten, the package is only installed if
# Splunk is not already present (use --force to reinstall/upgrade).
# Requires Splunk Enterprise 9.0+ (uses manager/peer clustering terms).
#
# Examples:
#   # Standalone indexer
#   sudo -E ./setup-indexer.sh --role standalone \
#     --package-file ./splunk-9.3.1-0b8d769cb912-Linux-x86_64.tgz \
#     --index linux_os:500000 --index wineventlog
#
#   # Cluster manager (3 peers, RF 3 / SF 2)
#   sudo -E ./setup-indexer.sh --role manager \
#     --package-file ./splunk-9.3.1-0b8d769cb912-Linux-x86_64.tgz \
#     --replication-factor 3 --search-factor 2 --cluster-label prod \
#     --index linux_os --index wineventlog
#
#   # Cluster peer
#   sudo -E ./setup-indexer.sh --role peer \
#     --package-file ./splunk-9.3.1-0b8d769cb912-Linux-x86_64.tgz \
#     --manager-uri https://splunk-cm.corp.local:8089
#
# Secrets come from the environment, or are prompted for if unset:
#   SPLUNK_PASSWORD        local admin password (fresh install only)
#   SPLUNK_CLUSTER_SECRET  cluster pass4SymmKey (manager and peer roles;
#                          must be identical on every cluster member)

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
ROLE=""
SPLUNK_HOME="/opt/splunk"
SPLUNK_USER="splunk"
SPLUNK_ADMIN="admin"
PACKAGE_FILE=""
PACKAGE_URL=""
SERVER_NAME=""
RECEIVING_PORT=9997
REPLICATION_PORT=9887
MANAGER_URI=""
REPLICATION_FACTOR=3
SEARCH_FACTOR=2
CLUSTER_LABEL=""
LICENSE_FILE=""
LICENSE_MANAGER=""
INDEXES=()
OPEN_FIREWALL=0
SKIP_BUNDLE_APPLY=0
FORCE=0
TMPDIR_DL=""

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

cleanup() { [[ -z "$TMPDIR_DL" ]] || rm -rf "$TMPDIR_DL"; }
trap cleanup EXIT

# Run a command as the service account (sudo isn't always installed).
as_splunk() {
  if command -v runuser &>/dev/null; then
    runuser -u "$SPLUNK_USER" -- "$@"
  else
    sudo -u "$SPLUNK_USER" "$@"
  fi
}

usage() {
  cat <<EOF
Usage: sudo $0 --role standalone|manager|peer [options]

Package source (one required unless Splunk is already installed):
  --package-file PATH        Local splunk .tgz/.deb/.rpm (Splunk Enterprise, not the UF)
  --package-url URL          URL to download the package from

All roles:
  --role ROLE                standalone, manager or peer (required)
  --server-name NAME         serverName for this instance (default: hostname)
  --license-file PATH        Install an Enterprise license on this instance
  --license-manager URI      Use a remote license manager, e.g. https://lm:8089
  --open-firewall            Open the role's ports in firewalld or ufw
  --splunk-home DIR          Install location (default: $SPLUNK_HOME)
  --splunk-user USER         Service account (default: $SPLUNK_USER)
  --admin-user USER          Local admin username (default: $SPLUNK_ADMIN)
  --force                    Reinstall/upgrade even if Splunk is already present
  -h, --help                 Show this help

standalone and manager:
  --index NAME[:MAX_MB]      Create an index, optionally capped at MAX_MB. Repeatable.
                             On a manager these go into the bundle for the peers.
  --receiving-port PORT      Forwarder receiving port (default: $RECEIVING_PORT)

manager:
  --replication-factor N     Copies of each bucket (default: $REPLICATION_FACTOR, needs >= N peers)
  --search-factor N          Searchable copies (default: $SEARCH_FACTOR)
  --cluster-label LABEL      Cluster name shown in Monitoring Console
  --skip-bundle-apply        Write the bundle but don't run 'apply cluster-bundle'

peer:
  --manager-uri URI          Cluster manager, e.g. https://cm.corp.local:8089 (required)
  --replication-port PORT    Bucket replication port between peers (default: $REPLICATION_PORT)

Environment:
  SPLUNK_PASSWORD            Admin password (prompted if unset)
  SPLUNK_CLUSTER_SECRET      Cluster pass4SymmKey (prompted if unset; manager/peer)
EOF
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)               ROLE="$2"; shift 2 ;;
    --package-file)       PACKAGE_FILE="$2"; shift 2 ;;
    --package-url)        PACKAGE_URL="$2"; shift 2 ;;
    --server-name)        SERVER_NAME="$2"; shift 2 ;;
    --index)              INDEXES+=("$2"); shift 2 ;;
    --receiving-port)     RECEIVING_PORT="$2"; shift 2 ;;
    --replication-port)   REPLICATION_PORT="$2"; shift 2 ;;
    --manager-uri)        MANAGER_URI="$2"; shift 2 ;;
    --replication-factor) REPLICATION_FACTOR="$2"; shift 2 ;;
    --search-factor)      SEARCH_FACTOR="$2"; shift 2 ;;
    --cluster-label)      CLUSTER_LABEL="$2"; shift 2 ;;
    --license-file)       LICENSE_FILE="$2"; shift 2 ;;
    --license-manager)    LICENSE_MANAGER="$2"; shift 2 ;;
    --open-firewall)      OPEN_FIREWALL=1; shift ;;
    --skip-bundle-apply)  SKIP_BUNDLE_APPLY=1; shift ;;
    --splunk-home)        SPLUNK_HOME="$2"; shift 2 ;;
    --splunk-user)        SPLUNK_USER="$2"; shift 2 ;;
    --admin-user)         SPLUNK_ADMIN="$2"; shift 2 ;;
    --force)              FORCE=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    usage; die "Unknown option: $1" ;;
  esac
done

SPLUNK_BIN="$SPLUNK_HOME/bin/splunk"

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
[[ "$(uname -s)" == "Linux" ]] || die "This script supports Linux only."

case "$ROLE" in
  standalone|manager|peer) ;;
  "") usage; die "--role is required." ;;
  *)  die "Invalid --role '$ROLE' (expected standalone, manager or peer)." ;;
esac

[[ -z "$PACKAGE_FILE" || -z "$PACKAGE_URL" ]] \
  || die "Use only one of --package-file or --package-url."
[[ -z "$LICENSE_FILE" || -f "$LICENSE_FILE" ]] || die "License file not found: $LICENSE_FILE"
[[ -z "$LICENSE_FILE" || -z "$LICENSE_MANAGER" ]] \
  || die "Use only one of --license-file or --license-manager."

is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
is_port "$RECEIVING_PORT"   || die "Invalid --receiving-port '$RECEIVING_PORT'"
is_port "$REPLICATION_PORT" || die "Invalid --replication-port '$REPLICATION_PORT'"

validate_uri() {
  [[ "$1" =~ ^https://[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] \
    || die "Invalid URI '$1' (expected https://host:port)"
}
[[ -z "$LICENSE_MANAGER" ]] || validate_uri "$LICENSE_MANAGER"

if [[ "$ROLE" == "peer" ]]; then
  [[ -n "$MANAGER_URI" ]] || die "--manager-uri is required for the peer role."
  validate_uri "$MANAGER_URI"
  [[ ${#INDEXES[@]} -eq 0 ]] \
    || warn "--index is ignored on a peer; peers get their indexes from the manager's bundle."
fi

if [[ "$ROLE" == "manager" ]]; then
  [[ "$REPLICATION_FACTOR" =~ ^[1-9][0-9]*$ ]] || die "Invalid --replication-factor"
  [[ "$SEARCH_FACTOR" =~ ^[1-9][0-9]*$ ]]      || die "Invalid --search-factor"
  (( SEARCH_FACTOR <= REPLICATION_FACTOR )) \
    || die "--search-factor cannot exceed --replication-factor."
fi

# ${arr[@]+...} keeps 'set -u' happy on bash < 4.4 when the array is empty.
for spec in ${INDEXES[@]+"${INDEXES[@]}"}; do
  IFS=':' read -r i_name i_max <<<"$spec"
  [[ "$i_name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || die "Invalid index name '$i_name' (lowercase letters, digits, _ and - only)"
  [[ "$i_name" != _* ]] || die "Index names starting with _ are reserved: $i_name"
  [[ -z "${i_max:-}" || "$i_max" =~ ^[0-9]+$ ]] || die "Invalid max size for index '$i_name': $i_max"
done

ALREADY_INSTALLED=0
[[ -x "$SPLUNK_BIN" ]] && ALREADY_INSTALLED=1

if [[ $ALREADY_INSTALLED -eq 0 || $FORCE -eq 1 ]]; then
  [[ -n "$PACKAGE_FILE" || -n "$PACKAGE_URL" ]] \
    || die "No package given. Use --package-file or --package-url."
fi

read_secret() {
  # read_secret VAR "prompt"
  local __var="$1" __prompt="$2" __a __b
  read -r -s -p "$__prompt: " __a; echo
  read -r -s -p "Confirm: " __b; echo
  [[ "$__a" == "$__b" ]] || die "Values do not match."
  printf -v "$__var" '%s' "$__a"
}

NEEDS_SEED=0
if [[ $ALREADY_INSTALLED -eq 0 || $FORCE -eq 1 || ! -f "$SPLUNK_HOME/etc/passwd" ]]; then
  NEEDS_SEED=1
fi

# The admin password is needed to seed a fresh install, and for CLI calls
# that require auth (license install, bundle apply).
NEEDS_AUTH=0
[[ -z "$LICENSE_FILE" ]] || NEEDS_AUTH=1
[[ "$ROLE" != "manager" || $SKIP_BUNDLE_APPLY -eq 1 ]] || NEEDS_AUTH=1

if [[ -z "${SPLUNK_PASSWORD:-}" && ( $NEEDS_SEED -eq 1 || $NEEDS_AUTH -eq 1 ) ]]; then
  read_secret SPLUNK_PASSWORD "Admin password for this instance (min 8 chars)"
fi
if [[ -n "${SPLUNK_PASSWORD:-}" && ${#SPLUNK_PASSWORD} -lt 8 ]]; then
  die "Password must be at least 8 characters."
fi

if [[ "$ROLE" != "standalone" && -z "${SPLUNK_CLUSTER_SECRET:-}" ]]; then
  read_secret SPLUNK_CLUSTER_SECRET "Cluster secret (pass4SymmKey, same on every cluster member)"
fi
if [[ "$ROLE" != "standalone" && ${#SPLUNK_CLUSTER_SECRET} -lt 12 ]]; then
  warn "Cluster secret is shorter than 12 characters; consider a longer one."
fi

# Reachability: warn only - the manager may not be up yet when peers are staged.
check_port() {
  local host="$1" port="$2"
  if timeout 5 bash -c ">/dev/tcp/$host/$port" 2>/dev/null; then
    log "Reachable: $host:$port"
  else
    warn "Cannot reach $host:$port - check DNS/firewall (or start that instance first)."
  fi
}
uri_hostport() { local hp="${1#https://}"; echo "${hp%:*} ${hp##*:}"; }
if [[ "$ROLE" == "peer" ]]; then
  # shellcheck disable=SC2046
  check_port $(uri_hostport "$MANAGER_URI")
fi
if [[ -n "$LICENSE_MANAGER" ]]; then
  # shellcheck disable=SC2046
  check_port $(uri_hostport "$LICENSE_MANAGER")
fi

# Indexers need real disk; warn early rather than fail later.
check_disk() {
  local dir="$SPLUNK_HOME"
  while [[ ! -d "$dir" ]]; do dir="$(dirname "$dir")"; done
  local free_gb
  free_gb=$(( $(df -Pk "$dir" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if (( free_gb < 50 )); then
    warn "Only ${free_gb}GB free under $dir; indexers normally need far more (and Splunk stops indexing below 5GB free)."
  else
    log "Free space under $dir: ${free_gb}GB"
  fi
}
check_disk

# ----------------------------------------------------------------------------
# OS preparation
# ----------------------------------------------------------------------------
ensure_user() {
  if ! id "$SPLUNK_USER" &>/dev/null; then
    log "Creating service account '$SPLUNK_USER'"
    useradd --system --create-home --home-dir "/home/$SPLUNK_USER" \
      --shell /bin/bash "$SPLUNK_USER"
  fi
}

# Splunk recommends disabling Transparent Huge Pages on indexers; THP causes
# large memory and latency problems for splunkd. (File/process limits are set
# by the systemd unit that 'enable boot-start' generates.)
disable_thp() {
  [[ -d /sys/kernel/mm/transparent_hugepage ]] || return 0
  log "Disabling Transparent Huge Pages"
  if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
    cat >/etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (Splunk)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=Splunkd.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
    systemctl daemon-reload
    systemctl enable --now disable-thp.service \
      || warn "Could not start disable-thp.service; check 'systemctl status disable-thp'."
  elif { echo never >/sys/kernel/mm/transparent_hugepage/enabled &&
         echo never >/sys/kernel/mm/transparent_hugepage/defrag; } 2>/dev/null; then
    warn "No systemd: THP disabled until next reboot only."
  else
    warn "Could not disable THP (read-only /sys?); disable it on the host."
  fi
}

open_firewall() {
  local ports=(8089/tcp)
  case "$ROLE" in
    standalone) ports+=(8000/tcp "$RECEIVING_PORT/tcp") ;;
    manager)    ports+=(8000/tcp) ;;
    peer)       ports+=("$RECEIVING_PORT/tcp" "$REPLICATION_PORT/tcp") ;;
  esac
  if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
    for p in "${ports[@]}"; do firewall-cmd --permanent --add-port="$p" >/dev/null; done
    firewall-cmd --reload >/dev/null
    log "Opened in firewalld: ${ports[*]}"
  elif command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
    for p in "${ports[@]}"; do ufw allow "$p" >/dev/null; done
    log "Opened in ufw: ${ports[*]}"
  else
    warn "No active firewalld/ufw found; open ${ports[*]} manually if a firewall is in use."
  fi
}

# ----------------------------------------------------------------------------
# Install
# ----------------------------------------------------------------------------
stop_existing() {
  if [[ -x "$SPLUNK_BIN" ]]; then
    log "Stopping existing Splunk"
    if systemctl list-unit-files 2>/dev/null | grep -q '^Splunkd.service'; then
      systemctl stop Splunkd || true
    else
      as_splunk "$SPLUNK_BIN" stop || true
    fi
  fi
}

install_package() {
  local pkg="$PACKAGE_FILE"

  if [[ -n "$PACKAGE_URL" ]]; then
    TMPDIR_DL="$(mktemp -d)"
    pkg="$TMPDIR_DL/$(basename "${PACKAGE_URL%%\?*}")"
    log "Downloading $PACKAGE_URL"
    if command -v curl &>/dev/null; then
      curl -fSL --retry 3 -o "$pkg" "$PACKAGE_URL"
    elif command -v wget &>/dev/null; then
      wget -q -O "$pkg" "$PACKAGE_URL"
    else
      die "Neither curl nor wget is available."
    fi
  fi

  [[ -f "$pkg" ]] || die "Package not found: $pkg"
  [[ "$(basename "$pkg")" != splunkforwarder* ]] \
    || die "That is a Universal Forwarder package; indexers need Splunk Enterprise (splunk-*)."

  stop_existing
  ensure_user

  case "$pkg" in
    *.tgz|*.tar.gz)
      # Extract over any existing install in place (this is also how a .tgz
      # upgrade is done) so local config is preserved.
      log "Extracting $pkg to $SPLUNK_HOME"
      mkdir -p "$SPLUNK_HOME"
      tar -xzf "$pkg" -C "$SPLUNK_HOME" --strip-components=1
      ;;
    *.deb)
      [[ "$SPLUNK_HOME" == "/opt/splunk" ]] \
        || die ".deb packages always install to /opt/splunk; use a .tgz for --splunk-home."
      log "Installing $pkg with dpkg"
      dpkg -i "$pkg"
      ;;
    *.rpm)
      log "Installing $pkg with rpm"
      if [[ "$SPLUNK_HOME" == "/opt/splunk" ]]; then
        rpm -Uvh --replacepkgs "$pkg"
      else
        rpm -Uvh --replacepkgs --prefix="$(dirname "$SPLUNK_HOME")" "$pkg"
      fi
      ;;
    *)
      die "Unrecognised package type: $pkg (expected .tgz, .deb or .rpm)"
      ;;
  esac

  ensure_user
  [[ -x "$SPLUNK_BIN" ]] || die "Install failed: $SPLUNK_BIN not found."
}

disable_thp

if [[ $ALREADY_INSTALLED -eq 0 || $FORCE -eq 1 ]]; then
  install_package
else
  log "Splunk already installed at $SPLUNK_HOME (use --force to reinstall/upgrade)"
  stop_existing
fi

[[ $OPEN_FIREWALL -eq 0 ]] || open_firewall

# ----------------------------------------------------------------------------
# Configuration
#
# Instance settings go in a role-specific app rather than etc/system/local so
# they're easy to find, diff and remove.
# ----------------------------------------------------------------------------
BASE_APP="org_indexer_base"
BASE_LOCAL="$SPLUNK_HOME/etc/apps/$BASE_APP/local"

# Start each run from a clean base app so switching roles doesn't leave stale
# config behind.
rm -rf "$SPLUNK_HOME/etc/apps/$BASE_APP"
mkdir -p "$BASE_LOCAL" "$SPLUNK_HOME/etc/apps/$BASE_APP/metadata"

write_meta() {
  cat >"$1/metadata/local.meta" <<'EOF'
[]
access = read : [ * ], write : [ admin ]
export = system
EOF
}
write_meta "$SPLUNK_HOME/etc/apps/$BASE_APP"

# Seed the admin account on first start only (Splunk deletes this file once
# it has been consumed).
if [[ $NEEDS_SEED -eq 1 && -n "${SPLUNK_PASSWORD:-}" ]]; then
  log "Writing user-seed.conf"
  mkdir -p "$SPLUNK_HOME/etc/system/local"
  ( umask 077
    cat >"$SPLUNK_HOME/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = $SPLUNK_ADMIN
PASSWORD = $SPLUNK_PASSWORD
EOF
  )
fi

# indexes.conf body for the requested indexes. Clustered indexes need
# repFactor = auto so the manager replicates them.
indexes_conf() {
  local clustered="$1"
  for spec in "${INDEXES[@]}"; do
    IFS=':' read -r i_name i_max <<<"$spec"
    echo "[$i_name]"
    echo "homePath   = \$SPLUNK_DB/$i_name/db"
    echo "coldPath   = \$SPLUNK_DB/$i_name/colddb"
    echo "thawedPath = \$SPLUNK_DB/$i_name/thaweddb"
    [[ -z "${i_max:-}" ]] || echo "maxTotalDataSizeMB = $i_max"
    [[ "$clustered" != 1 ]] || echo "repFactor = auto"
    echo
  done
}

receiving_input() {
  cat <<EOF
[splunktcp://$RECEIVING_PORT]
disabled = false
connection_host = ip
EOF
}

# server.conf, built up per role.
{
  echo "[general]"
  echo "serverName = ${SERVER_NAME:-$(hostname -s)}"
  echo
  if [[ -n "$LICENSE_MANAGER" ]]; then
    echo "[license]"
    echo "manager_uri = $LICENSE_MANAGER"
    echo
  fi
  case "$ROLE" in
    manager)
      echo "[clustering]"
      echo "mode = manager"
      echo "replication_factor = $REPLICATION_FACTOR"
      echo "search_factor = $SEARCH_FACTOR"
      echo "pass4SymmKey = $SPLUNK_CLUSTER_SECRET"
      [[ -z "$CLUSTER_LABEL" ]] || echo "cluster_label = $CLUSTER_LABEL"
      ;;
    peer)
      echo "[replication_port://$REPLICATION_PORT]"
      echo
      echo "[clustering]"
      echo "mode = peer"
      echo "manager_uri = $MANAGER_URI"
      echo "pass4SymmKey = $SPLUNK_CLUSTER_SECRET"
      ;;
  esac
} >"$BASE_LOCAL/server.conf"
chmod 600 "$BASE_LOCAL/server.conf"

case "$ROLE" in
  standalone)
    log "Writing receiving input (:$RECEIVING_PORT) and ${#INDEXES[@]} index(es)"
    receiving_input >"$BASE_LOCAL/inputs.conf"
    [[ ${#INDEXES[@]} -eq 0 ]] || indexes_conf 0 >"$BASE_LOCAL/indexes.conf"
    ;;

  manager)
    # Everything under manager-apps is pushed to all peers as the
    # configuration bundle. The receiving input lives here so every peer
    # listens on the same port.
    BUNDLE_APP="$SPLUNK_HOME/etc/manager-apps/org_all_indexers"
    log "Writing cluster bundle app $BUNDLE_APP (receiving :$RECEIVING_PORT, ${#INDEXES[@]} index(es))"
    rm -rf "$BUNDLE_APP"
    mkdir -p "$BUNDLE_APP/local" "$BUNDLE_APP/metadata"
    write_meta "$BUNDLE_APP"
    receiving_input >"$BUNDLE_APP/local/inputs.conf"
    [[ ${#INDEXES[@]} -eq 0 ]] || indexes_conf 1 >"$BUNDLE_APP/local/indexes.conf"
    ;;

  peer)
    # Peers are managed through the bundle and searched via the cluster;
    # nobody should log into their web UI.
    cat >"$BASE_LOCAL/web.conf" <<'EOF'
[settings]
startwebserver = 0
EOF
    ;;
esac

chown -R "$SPLUNK_USER:$SPLUNK_USER" "$SPLUNK_HOME"

# ----------------------------------------------------------------------------
# First start + boot-start
# ----------------------------------------------------------------------------
# Remove any previous boot-start config first: once systemd-managed, a plain
# 'splunk start' hands off to systemctl, which the service account can't do.
"$SPLUNK_BIN" disable boot-start &>/dev/null || true

log "Starting Splunk once to accept the license and apply config"
as_splunk "$SPLUNK_BIN" start --accept-license --answer-yes --no-prompt
as_splunk "$SPLUNK_BIN" stop

if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
  log "Enabling boot-start (systemd)"
  "$SPLUNK_BIN" enable boot-start -systemd-managed 1 -user "$SPLUNK_USER" --accept-license --answer-yes --no-prompt
  systemctl daemon-reload
  systemctl enable --now Splunkd
else
  log "Enabling boot-start (init.d)"
  "$SPLUNK_BIN" enable boot-start -user "$SPLUNK_USER" --accept-license --answer-yes --no-prompt
  as_splunk "$SPLUNK_BIN" start
fi

# Wait for splunkd's management port before making CLI calls against it.
log "Waiting for splunkd to come up"
for _ in $(seq 1 60); do
  if as_splunk "$SPLUNK_BIN" status 2>/dev/null | grep -q 'splunkd is running' \
     && timeout 2 bash -c '>/dev/tcp/127.0.0.1/8089' 2>/dev/null; then
    break
  fi
  sleep 2
done
as_splunk "$SPLUNK_BIN" status | grep -q 'splunkd is running' \
  || die "splunkd is not running. Check $SPLUNK_HOME/var/log/splunk/splunkd.log"
log "splunkd is running."

# Note: -auth is briefly visible to other local users via 'ps'. On a freshly
# built indexer that's normally acceptable; rotate the password afterwards if
# untrusted users have shell access.
splunk_auth() {
  as_splunk "$SPLUNK_BIN" "$@" -auth "$SPLUNK_ADMIN:$SPLUNK_PASSWORD"
}

if [[ -n "$LICENSE_FILE" ]]; then
  log "Installing license $LICENSE_FILE"
  lic_copy="$SPLUNK_HOME/var/run/$(basename "$LICENSE_FILE")"
  install -o "$SPLUNK_USER" -g "$SPLUNK_USER" -m 600 "$LICENSE_FILE" "$lic_copy"
  if splunk_auth add licenses "$lic_copy"; then
    log "License installed; restarting to activate it"
    if systemctl is-enabled Splunkd &>/dev/null; then systemctl restart Splunkd; else as_splunk "$SPLUNK_BIN" restart; fi
  else
    warn "License install failed (already installed?). Check Settings > Licensing."
  fi
  rm -f "$lic_copy"
fi

if [[ "$ROLE" == "manager" && $SKIP_BUNDLE_APPLY -eq 0 ]]; then
  log "Validating and applying the cluster bundle"
  if splunk_auth apply cluster-bundle --answer-yes; then
    log "Bundle applied. Peers that join later download it automatically."
  else
    warn "Bundle apply did not complete (normal before any peers have joined)."
    warn "Once peers are up, run on this host: $SPLUNK_BIN apply cluster-bundle --answer-yes"
  fi
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
echo
echo "Indexer setup complete."
echo "  Role        : $ROLE"
echo "  SPLUNK_HOME : $SPLUNK_HOME (run as $SPLUNK_USER)"
echo "  Config app  : $BASE_LOCAL"
case "$ROLE" in
  standalone)
    echo "  Receiving   : $HOST_FQDN:$RECEIVING_PORT"
    echo "  Web         : https://$HOST_FQDN:8000 (http unless SSL is enabled in web.conf)"
    echo
    echo "Point forwarders at it with: --indexers \"$HOST_FQDN:$RECEIVING_PORT\""
    ;;
  manager)
    echo "  Bundle app  : $SPLUNK_HOME/etc/manager-apps/org_all_indexers"
    echo "  RF / SF     : $REPLICATION_FACTOR / $SEARCH_FACTOR (needs at least $REPLICATION_FACTOR peers)"
    echo
    echo "Next: run this script with --role peer --manager-uri https://$HOST_FQDN:8089 on each peer,"
    echo "using the same SPLUNK_CLUSTER_SECRET. Check status with:"
    echo "  $SPLUNK_BIN show cluster-status -auth $SPLUNK_ADMIN"
    echo "To add or change indexes later, re-run with --role manager and the full --index list."
    ;;
  peer)
    echo "  Manager     : $MANAGER_URI"
    echo "  Receiving   : $HOST_FQDN:$RECEIVING_PORT (from the manager's bundle)"
    echo "  Replication : $REPLICATION_PORT"
    echo
    echo "Confirm the peer appears on the manager: Settings > Indexer clustering."
    ;;
esac
