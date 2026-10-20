#!/usr/bin/env bash
#
# deploy-universal-forwarder.sh
#
# Installs and configures a Splunk Universal Forwarder (UF) on a Linux host and
# points it at an on-prem Splunk Enterprise deployment (indexers and/or a
# deployment server).
#
# Supports .tgz, .deb and .rpm packages, either from a local file or a URL.
# Safe to re-run: config files are rewritten, the package is only installed if
# the forwarder is not already present (use --force to reinstall).
#
# Example:
#   sudo ./deploy-universal-forwarder.sh \
#     --package-url "https://download.splunk.com/products/universalforwarder/releases/9.3.1/linux/splunkforwarder-9.3.1-0b8d769cb912-Linux-x86_64.tgz" \
#     --indexers "splunk-idx01.corp.local:9997,splunk-idx02.corp.local:9997" \
#     --deployment-server "splunk-ds.corp.local:8089" \
#     --monitor "/var/log/syslog:linux_os:syslog" \
#     --monitor "/var/log/auth.log:linux_secure:linux_secure"
#
# The admin password is read from $SPLUNK_PASSWORD, or prompted for if unset.

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
SPLUNK_HOME="/opt/splunkforwarder"
SPLUNK_USER="splunkfwd"
SPLUNK_ADMIN="admin"
PACKAGE_FILE=""
PACKAGE_URL=""
INDEXERS=""
DEPLOYMENT_SERVER=""
CLIENT_NAME=""
MONITORS=()
FORCE=0
USE_TLS=0
SSL_VERIFY=0
CA_CERT=""
APP_NAME="org_uf_base"
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
Usage: sudo $0 [options]

Package source (one required unless the UF is already installed):
  --package-file PATH        Local splunkforwarder .tgz/.deb/.rpm
  --package-url URL          URL to download the package from

Destination (at least one required):
  --indexers LIST            Comma-separated host:port receivers (e.g. idx1:9997,idx2:9997)
  --deployment-server HOST:PORT
                             Deployment server management URI (usually port 8089)

Optional:
  --monitor PATH[:INDEX[:SOURCETYPE]]
                             File/dir to monitor. Repeatable.
  --client-name NAME         clientName reported to the deployment server
  --splunk-home DIR          Install location (default: $SPLUNK_HOME)
  --splunk-user USER         Service account (default: $SPLUNK_USER)
  --admin-user USER          Local UF admin username (default: $SPLUNK_ADMIN)
  --tls                      Send to indexers over TLS (indexer must have an SSL input)
  --ca-cert PATH             CA bundle used to verify the indexer certs (implies --tls)
  --force                    Reinstall even if the UF is already present
  -h, --help                 Show this help

Environment:
  SPLUNK_PASSWORD            Admin password for the UF (prompted if unset)
EOF
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-file)       PACKAGE_FILE="$2"; shift 2 ;;
    --package-url)        PACKAGE_URL="$2"; shift 2 ;;
    --indexers)           INDEXERS="$2"; shift 2 ;;
    --deployment-server)  DEPLOYMENT_SERVER="$2"; shift 2 ;;
    --monitor)            MONITORS+=("$2"); shift 2 ;;
    --client-name)        CLIENT_NAME="$2"; shift 2 ;;
    --splunk-home)        SPLUNK_HOME="$2"; shift 2 ;;
    --splunk-user)        SPLUNK_USER="$2"; shift 2 ;;
    --admin-user)         SPLUNK_ADMIN="$2"; shift 2 ;;
    --tls)                USE_TLS=1; shift ;;
    --ca-cert)            CA_CERT="$2"; USE_TLS=1; SSL_VERIFY=1; shift 2 ;;
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
[[ -n "$INDEXERS" || -n "$DEPLOYMENT_SERVER" ]] \
  || die "Specify --indexers and/or --deployment-server."
[[ -z "$PACKAGE_FILE" || -z "$PACKAGE_URL" ]] \
  || die "Use only one of --package-file or --package-url."
[[ -z "$CA_CERT" || -f "$CA_CERT" ]] || die "CA cert not found: $CA_CERT"

ALREADY_INSTALLED=0
[[ -x "$SPLUNK_BIN" ]] && ALREADY_INSTALLED=1

if [[ $ALREADY_INSTALLED -eq 0 || $FORCE -eq 1 ]]; then
  [[ -n "$PACKAGE_FILE" || -n "$PACKAGE_URL" ]] \
    || die "No package given. Use --package-file or --package-url."
fi

validate_hostport() {
  local hp="$1"
  [[ "$hp" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] || die "Invalid host:port '$hp'"
}

if [[ -n "$INDEXERS" ]]; then
  IFS=',' read -r -a _idx <<<"$INDEXERS"
  for hp in "${_idx[@]}"; do validate_hostport "$hp"; done
fi
[[ -z "$DEPLOYMENT_SERVER" ]] || validate_hostport "$DEPLOYMENT_SERVER"

if [[ -z "${SPLUNK_PASSWORD:-}" ]]; then
  if [[ $ALREADY_INSTALLED -eq 1 && $FORCE -eq 0 ]]; then
    : # existing install already has credentials; password only needed for a fresh seed
  else
    read -r -s -p "Enter admin password for the forwarder (min 8 chars): " SPLUNK_PASSWORD; echo
    read -r -s -p "Confirm password: " _confirm; echo
    [[ "$SPLUNK_PASSWORD" == "$_confirm" ]] || die "Passwords do not match."
  fi
fi
if [[ -n "${SPLUNK_PASSWORD:-}" && ${#SPLUNK_PASSWORD} -lt 8 ]]; then
  die "Password must be at least 8 characters."
fi

# Warn (don't fail) if destinations aren't reachable yet - firewalls are often
# opened after the forwarder is staged.
check_port() {
  local host="${1%:*}" port="${1##*:}"
  if timeout 5 bash -c ">/dev/tcp/$host/$port" 2>/dev/null; then
    log "Reachable: $host:$port"
  else
    warn "Cannot reach $host:$port - check DNS/firewall."
  fi
}
if [[ -n "$INDEXERS" ]]; then
  for hp in "${_idx[@]}"; do check_port "$hp"; done
fi
[[ -z "$DEPLOYMENT_SERVER" ]] || check_port "$DEPLOYMENT_SERVER"

# ----------------------------------------------------------------------------
# Service account
# ----------------------------------------------------------------------------
ensure_user() {
  if ! id "$SPLUNK_USER" &>/dev/null; then
    log "Creating service account '$SPLUNK_USER'"
    useradd --system --create-home --home-dir "/home/$SPLUNK_USER" \
      --shell /bin/bash "$SPLUNK_USER"
  fi
}

# ----------------------------------------------------------------------------
# Install
# ----------------------------------------------------------------------------
stop_existing() {
  if [[ -x "$SPLUNK_BIN" ]]; then
    log "Stopping existing forwarder"
    if systemctl list-unit-files 2>/dev/null | grep -q '^SplunkForwarder.service'; then
      systemctl stop SplunkForwarder || true
    else
      "$SPLUNK_BIN" stop || true
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
      [[ "$SPLUNK_HOME" == "/opt/splunkforwarder" ]] \
        || die ".deb packages always install to /opt/splunkforwarder; use a .tgz for --splunk-home."
      log "Installing $pkg with dpkg"
      dpkg -i "$pkg"
      ;;
    *.rpm)
      log "Installing $pkg with rpm"
      if [[ "$SPLUNK_HOME" == "/opt/splunkforwarder" ]]; then
        rpm -Uvh --replacepkgs "$pkg"
      else
        rpm -Uvh --replacepkgs --prefix="$(dirname "$SPLUNK_HOME")" "$pkg"
      fi
      ;;
    *)
      die "Unrecognised package type: $pkg (expected .tgz, .deb or .rpm)"
      ;;
  esac

  # Packages from 9.1+ create 'splunkfwd' themselves; make sure ours exists
  # and owns the tree either way.
  ensure_user
  [[ -x "$SPLUNK_BIN" ]] || die "Install failed: $SPLUNK_BIN not found."
}

if [[ $ALREADY_INSTALLED -eq 0 || $FORCE -eq 1 ]]; then
  install_package
else
  log "Forwarder already installed at $SPLUNK_HOME (use --force to reinstall)"
  stop_existing
fi

# ----------------------------------------------------------------------------
# Configuration
#
# Settings go in a dedicated app rather than etc/system/local so they can be
# removed cleanly or taken over by the deployment server later.
# ----------------------------------------------------------------------------
APP_LOCAL="$SPLUNK_HOME/etc/apps/$APP_NAME/local"
mkdir -p "$APP_LOCAL" "$SPLUNK_HOME/etc/apps/$APP_NAME/metadata"

cat >"$SPLUNK_HOME/etc/apps/$APP_NAME/metadata/local.meta" <<'EOF'
[]
access = read : [ * ], write : [ admin ]
export = system
EOF

# Seed the admin account on first start only (Splunk deletes this file once
# it has been consumed).
if [[ -n "${SPLUNK_PASSWORD:-}" && ( ! -f "$SPLUNK_HOME/etc/passwd" || $FORCE -eq 1 ) ]]; then
  log "Writing user-seed.conf"
  umask 077
  cat >"$SPLUNK_HOME/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = $SPLUNK_ADMIN
PASSWORD = $SPLUNK_PASSWORD
EOF
  umask 022
fi

if [[ -n "$INDEXERS" ]]; then
  log "Writing outputs.conf -> $INDEXERS"
  {
    echo "[tcpout]"
    echo "defaultGroup = primary_indexers"
    echo
    echo "[tcpout:primary_indexers]"
    echo "server = $INDEXERS"
    echo "useACK = true"
    echo "autoLBFrequency = 30"
    if [[ $USE_TLS -eq 1 ]]; then
      echo "useSSL = true"
      if [[ $SSL_VERIFY -eq 1 ]]; then
        cp "$CA_CERT" "$SPLUNK_HOME/etc/auth/org_ca.pem"
        echo "sslVerifyServerCert = true"
        echo "sslRootCAPath = \$SPLUNK_HOME/etc/auth/org_ca.pem"
      else
        echo "sslVerifyServerCert = false"
      fi
    fi
  } >"$APP_LOCAL/outputs.conf"
else
  rm -f "$APP_LOCAL/outputs.conf"
fi

if [[ -n "$DEPLOYMENT_SERVER" ]]; then
  log "Writing deploymentclient.conf -> $DEPLOYMENT_SERVER"
  {
    echo "[deployment-client]"
    [[ -z "$CLIENT_NAME" ]] || echo "clientName = $CLIENT_NAME"
    echo
    echo "[target-broker:deploymentServer]"
    echo "targetUri = $DEPLOYMENT_SERVER"
  } >"$APP_LOCAL/deploymentclient.conf"
else
  rm -f "$APP_LOCAL/deploymentclient.conf"
fi

if [[ ${#MONITORS[@]} -gt 0 ]]; then
  log "Writing inputs.conf (${#MONITORS[@]} monitor(s))"
  : >"$APP_LOCAL/inputs.conf"
  for spec in "${MONITORS[@]}"; do
    IFS=':' read -r m_path m_index m_sourcetype <<<"$spec"
    [[ -e "$m_path" ]] || warn "Monitor path does not exist yet: $m_path"
    {
      echo "[monitor://$m_path]"
      echo "disabled = false"
      [[ -z "${m_index:-}" ]] || echo "index = $m_index"
      [[ -z "${m_sourcetype:-}" ]] || echo "sourcetype = $m_sourcetype"
      echo
    } >>"$APP_LOCAL/inputs.conf"
  done
else
  rm -f "$APP_LOCAL/inputs.conf"
fi

chown -R "$SPLUNK_USER:$SPLUNK_USER" "$SPLUNK_HOME"

# Grant read access to monitored files that root owns (e.g. /var/log/*) via
# ACLs, so the forwarder doesn't need to run as root.
if [[ ${#MONITORS[@]} -gt 0 ]] && command -v setfacl &>/dev/null; then
  for spec in "${MONITORS[@]}"; do
    m_path="${spec%%:*}"
    [[ -e "$m_path" ]] || continue
    if ! setfacl -R -m "u:$SPLUNK_USER:rX" "$m_path" 2>/dev/null; then
      warn "Could not set ACL on $m_path; ensure $SPLUNK_USER can read it."
      continue
    fi
    setfacl -m "u:$SPLUNK_USER:rx" "$(dirname "$m_path")" 2>/dev/null || true
    # Default ACL so rotated/new files stay readable.
    if [[ -d "$m_path" ]]; then
      setfacl -R -d -m "u:$SPLUNK_USER:rX" "$m_path" 2>/dev/null || true
    fi
  done
elif [[ ${#MONITORS[@]} -gt 0 ]]; then
  warn "setfacl not found; ensure $SPLUNK_USER can read the monitored paths."
fi

# ----------------------------------------------------------------------------
# First start + boot-start
# ----------------------------------------------------------------------------
# Remove any previous boot-start config first: once systemd-managed, a plain
# 'splunk start' hands off to systemctl, which the service account can't do.
"$SPLUNK_BIN" disable boot-start &>/dev/null || true

log "Starting forwarder (accepting license)"
as_splunk "$SPLUNK_BIN" start --accept-license --answer-yes --no-prompt
as_splunk "$SPLUNK_BIN" stop

if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
  log "Enabling boot-start (systemd)"
  "$SPLUNK_BIN" enable boot-start -systemd-managed 1 -user "$SPLUNK_USER" --accept-license --answer-yes --no-prompt
  systemctl daemon-reload
  systemctl enable --now SplunkForwarder
else
  log "Enabling boot-start (init.d)"
  "$SPLUNK_BIN" enable boot-start -user "$SPLUNK_USER" --accept-license --answer-yes --no-prompt
  as_splunk "$SPLUNK_BIN" start
fi

# ----------------------------------------------------------------------------
# Verify
# ----------------------------------------------------------------------------
sleep 5
if as_splunk "$SPLUNK_BIN" status | grep -q 'splunkd is running'; then
  log "Forwarder is running."
else
  die "splunkd is not running. Check $SPLUNK_HOME/var/log/splunk/splunkd.log"
fi

if [[ -n "$INDEXERS" ]]; then
  log "Connection status (may take ~30s to establish):"
  grep -E 'TcpOutputProc|Connected to idx' "$SPLUNK_HOME/var/log/splunk/splunkd.log" 2>/dev/null \
    | tail -n 5 || true
fi

cat <<EOF

Deployment complete.
  SPLUNK_HOME : $SPLUNK_HOME
  Run as      : $SPLUNK_USER
  Config app  : $SPLUNK_HOME/etc/apps/$APP_NAME/local
  Indexers    : ${INDEXERS:-<none - expecting outputs from deployment server>}
  Deploy srv  : ${DEPLOYMENT_SERVER:-<none>}

Verify on the Splunk Enterprise side:
  index=_internal host=$(hostname) sourcetype=splunkd | head 10
EOF
