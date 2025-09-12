#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Grafana OSS installer for RHEL 9.6 (x86_64)
# - Downloads official OSS tarball and verifies SHA256
# - Installs Grafana under /usr/local/lib/grafana; binary in /usr/local/bin/grafana
# - Runs as invoking login user
# - Stores data in /app/grafana
# - Stores logs in /logs/grafana/grafana.log (with logrotate + journald)
# - Stores config in /etc/grafana/grafana.ini (world-writable by request)
# - Uses `grafana server` modern entrypoint
# - Service supports reload via SIGHUP
# -----------------------------------------------------------------------------

GRAFANA_VERSION="12.1.1"                                # Grafana OSS version
GRAFANA_PORT="3000"                                     # Web port

GRAFANA_PREFIX="/usr/local/lib/grafana"                 # Install path
GRAFANA_BIN="/usr/local/bin/grafana"                    # Binary path

GRAFANA_DATA="/app/grafana"                             # Data directory
GRAFANA_CONF_DIR="/etc/grafana"                         # Config directory
GRAFANA_CONF_FILE="${GRAFANA_CONF_DIR}/grafana.ini"     # Config file
GRAFANA_LOG_DIR="/logs/grafana"                         # Logs directory
GRAFANA_LOG_FILE="${GRAFANA_LOG_DIR}/grafana.log"       # Log file

print_status(){ echo -e "\e[1;32m$1\e[0m"; }

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run with sudo/root" >&2
  exit 1
fi

# Detect user/group
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "$RUN_USER")"
print_status "==> Service will run as: ${RUN_USER}:${RUN_GROUP}"

# Ensure required packages are installed
declare -A CMD2PKG=(
  [curl]=curl
  [tar]=tar
  [sha256sum]=coreutils
  [systemctl]=systemd
  [logrotate]=logrotate
  [restorecon]=policycoreutils
  [firewall-cmd]=firewalld
)
for cmd in "${!CMD2PKG[@]}"; do
  command -v "$cmd" &>/dev/null || { print_status "==> Installing ${CMD2PKG[$cmd]}"; dnf install -y "${CMD2PKG[$cmd]}" >/dev/null; }
done

# Create directories
print_status "==> Creating directories..."
mkdir -p "$GRAFANA_DATA" "$GRAFANA_CONF_DIR" "$GRAFANA_LOG_DIR" /logs
chown -R "$RUN_USER:$RUN_GROUP" "$GRAFANA_DATA" "$GRAFANA_LOG_DIR"
chmod 0750 "$GRAFANA_DATA"
chmod 1777 /logs "$GRAFANA_LOG_DIR" "$GRAFANA_CONF_DIR"

# Download tarball + sha256
print_status "==> Downloading Grafana OSS v${GRAFANA_VERSION}..."
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT; cd "$TMPDIR"
TARBALL="grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz"
BASE_URL="https://dl.grafana.com/oss/release"
curl -fSsLO "${BASE_URL}/${TARBALL}"
curl -fSsLO "${BASE_URL}/${TARBALL}.sha256" || true

# Verify checksum
print_status "==> Verifying checksum..."
if [[ -f "${TARBALL}.sha256" ]]; then
  if grep -qE '^[a-f0-9]{64}\s{2}' "${TARBALL}.sha256"; then
    sha256sum -c "${TARBALL}.sha256"
  else
    HASH="$(tr -d '\n' < "${TARBALL}.sha256")"
    echo "${HASH}  ${TARBALL}" | sha256sum -c -
  fi
else
  echo "WARNING: checksum file not found; computing local hash:" >&2
  sha256sum "${TARBALL}"
fi

# Extract and install
print_status "==> Extracting and installing..."
tar xf "$TARBALL"
SRC_DIR="grafana-${GRAFANA_VERSION}"
install -d "$GRAFANA_PREFIX"
cp -a "${SRC_DIR}/." "$GRAFANA_PREFIX/"
install -o root -g root -m 0755 "${GRAFANA_PREFIX}/bin/grafana" "$GRAFANA_BIN"

# Install config
print_status "==> Installing configuration..."
if [[ -f "${GRAFANA_PREFIX}/conf/sample.ini" ]]; then
  install -o root -g "$RUN_GROUP" -m 0666 "${GRAFANA_PREFIX}/conf/sample.ini" "$GRAFANA_CONF_FILE"
else
  install -o root -g "$RUN_GROUP" -m 0666 /dev/null "$GRAFANA_CONF_FILE"
fi

# Restore SELinux contexts
if command -v restorecon &>/dev/null; then
  print_status "==> Restoring SELinux contexts..."
  restorecon -R "$GRAFANA_PREFIX" "$GRAFANA_BIN" "$GRAFANA_DATA" "$GRAFANA_CONF_DIR" "$GRAFANA_LOG_DIR" || true
fi

# Create systemd service
print_status "==> Creating systemd service..."
cat > /etc/systemd/system/grafana.service <<UNIT
[Unit]
Description=Grafana Server
Documentation=https://grafana.com/docs/grafana/latest/
Wants=network-online.target
After=network-online.target

[Service]
User=${RUN_USER}
Group=${RUN_GROUP}
Type=simple

Environment=GF_PATHS_HOME=${GRAFANA_PREFIX}
Environment=GF_PATHS_CONFIG=${GRAFANA_CONF_FILE}
Environment=GF_PATHS_DATA=${GRAFANA_DATA}
Environment=GF_PATHS_LOGS=${GRAFANA_LOG_DIR}
Environment=GF_PATHS_PLUGINS=${GRAFANA_DATA}/plugins
Environment=GF_SERVER_HTTP_PORT=${GRAFANA_PORT}
Environment=GF_LOG_MODE=console

ExecStart=/bin/bash -c 'umask 000; exec ${GRAFANA_BIN} \
  server \
  --homepath=${GRAFANA_PREFIX} \
  --config=${GRAFANA_CONF_FILE} \
  &>> ${GRAFANA_LOG_FILE}'

ExecReload=/bin/kill -HUP \$MAINPID

StandardOutput=journal
StandardError=journal
SyslogIdentifier=grafana

Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

# Configure logrotate
print_status "==> Setting up logrotate..."
cat > /etc/logrotate.d/grafana <<LR
${GRAFANA_LOG_DIR}/*.log {
  daily
  rotate 14
  compress
  missingok
  notifempty
  copytruncate
  create 0666 ${RUN_USER} ${RUN_GROUP}
}
LR

# Open firewall port if firewalld active
if systemctl is-active --quiet firewalld; then
  print_status "==> Opening firewall port ${GRAFANA_PORT}/tcp..."
  firewall-cmd --add-port=${GRAFANA_PORT}/tcp --permanent >/dev/null || true
  firewall-cmd --reload >/dev/null || true
fi

# Enable and start service
print_status "==> Enabling and starting Grafana..."
systemctl daemon-reload
systemctl enable --now grafana

# Fix ownership and permissions
chmod 0666 "${GRAFANA_LOG_DIR}"/*.log 2>/dev/null || true
chown -R "${RUN_USER}:${RUN_GROUP}" "${GRAFANA_DATA}" "${GRAFANA_LOG_DIR}"

# Show summary
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST="$(hostname -f 2>/dev/null || hostname)"
print_status "========== INSTALLATION COMPLETE =========="
echo "Grafana: $(${GRAFANA_BIN} -v 2>&1 | head -n1)"
echo "Web UI:  http://${IP:-$HOST}:${GRAFANA_PORT}"
echo "Service: systemctl status grafana --no-pager -l"
echo "Data:    ${GRAFANA_DATA}"
echo "Config:  ${GRAFANA_CONF_FILE}"
echo "Logs:    ${GRAFANA_LOG_FILE}"
echo "Reload:  sudo systemctl reload grafana"
echo "Tail:    tail -f ${GRAFANA_LOG_FILE}"
