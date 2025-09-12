#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Prometheus installer for RHEL 9.6 (x86_64)
# - Downloads official release tarball and verifies SHA256
# - Installs prometheus + promtool in /usr/local/bin
# - Stores TSDB data in /app/prometheus
# - Stores logs in /logs/prometheus/prometheus.log (with logrotate + journald)
# - Stores config in /etc/prometheus (world-writable by request)
# - Service runs as invoking user, supports reload via SIGHUP
# -----------------------------------------------------------------------------

PROM_VERSION="3.5.0"                                # Prometheus version
PROM_DIR="/app/prometheus"                          # TSDB data directory
PROM_CONFIG_DIR="/etc/prometheus"                   # Config directory
PROM_LOG_DIR="/logs/prometheus"                     # Log directory
PORT="9090"                                         # Web port

print_status(){ echo -e "\e[1;32m$1\e[0m"; }

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run with sudo/root" >&2
  exit 1
fi

# Detect which user should run the service
RUN_USER="${SUDO_USER:-$(id -un)}"                  # invoking login user
RUN_GROUP="$(id -gn "$RUN_USER")"                   # primary group
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

# Create directories for data, config, logs
print_status "==> Creating directories..."
mkdir -p "$PROM_DIR" "$PROM_CONFIG_DIR" "$PROM_LOG_DIR" /logs
chown -R "$RUN_USER:$RUN_GROUP" "$PROM_DIR" "$PROM_LOG_DIR"
chmod 0750 "$PROM_DIR"
chmod 1777 /logs "$PROM_LOG_DIR" "$PROM_CONFIG_DIR"

# Download Prometheus tarball and checksum
print_status "==> Downloading Prometheus v${PROM_VERSION}..."
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT; cd "$TMPDIR"
TARBALL="prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
BASE_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}"
curl -sSLO "${BASE_URL}/${TARBALL}"
curl -sSLO "${BASE_URL}/sha256sums.txt"

# Verify tarball checksum
print_status "==> Verifying checksum..."
grep -E "  ${TARBALL}\$" sha256sums.txt | sha256sum -c -

# Extract and install binaries
print_status "==> Extracting and installing binaries..."
tar xf "$TARBALL"
cd "prometheus-${PROM_VERSION}.linux-amd64"
install -o root -g root -m 0755 prometheus /usr/local/bin/prometheus
install -o root -g root -m 0755 promtool   /usr/local/bin/promtool

# Install default config
print_status "==> Installing configuration..."
install -o root -g "$RUN_GROUP" -m 0666 prometheus.yml "${PROM_CONFIG_DIR}/prometheus.yml" || true
[ -d consoles ] && cp -r consoles "${PROM_CONFIG_DIR}/"
[ -d console_libraries ] && cp -r console_libraries "${PROM_CONFIG_DIR}/"

# Restore SELinux contexts if available
if command -v restorecon &>/dev/null; then
  print_status "==> Restoring SELinux contexts..."
  restorecon -R /usr/local/bin "$PROM_CONFIG_DIR" "$PROM_DIR" "$PROM_LOG_DIR" || true
fi

# Create systemd unit file
print_status "==> Creating systemd service..."
cat > /etc/systemd/system/prometheus.service <<UNIT
[Unit]
Description=Prometheus Server
Documentation=https://prometheus.io/docs/introduction/overview/
Wants=network-online.target
After=network-online.target

[Service]
User=${RUN_USER}
Group=${RUN_GROUP}
Type=simple
ExecStartPre=/usr/local/bin/promtool check config ${PROM_CONFIG_DIR}/prometheus.yml
ExecStart=/bin/bash -c 'umask 000; /usr/local/bin/prometheus \
  --config.file=${PROM_CONFIG_DIR}/prometheus.yml \
  --storage.tsdb.path=${PROM_DIR} \
  --web.listen-address=:${PORT} \
  &>> ${PROM_LOG_DIR}/prometheus.log'
ExecReload=/bin/kill -HUP \$MAINPID

StandardOutput=journal
StandardError=journal
SyslogIdentifier=prometheus

Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

# Configure logrotate for logs
print_status "==> Setting up logrotate..."
cat > /etc/logrotate.d/prometheus <<LR
${PROM_LOG_DIR}/*.log {
  daily
  rotate 14
  compress
  missingok
  notifempty
  copytruncate
  create 0666 ${RUN_USER} ${RUN_GROUP}
}
LR

# Open firewall port if firewalld is active
if systemctl is-active --quiet firewalld; then
  print_status "==> Opening firewall port ${PORT}/tcp..."
  firewall-cmd --add-port=${PORT}/tcp --permanent >/dev/null || true
  firewall-cmd --reload >/dev/null || true
fi

# Enable and start service
print_status "==> Enabling and starting Prometheus..."
systemctl daemon-reload
systemctl enable --now prometheus

# Fix ownership and permissions
chmod 0666 ${PROM_LOG_DIR}/*.log 2>/dev/null || true
chown -R "${RUN_USER}:${RUN_GROUP}" "${PROM_DIR}" "${PROM_LOG_DIR}"

# Show summary
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST="$(hostname -f 2>/dev/null || hostname)"
print_status "========== INSTALLATION COMPLETE =========="
echo "Prometheus: $(/usr/local/bin/prometheus --version | head -n1)"
echo "Web UI:     http://${IP:-$HOST}:${PORT}"
echo "Service:    systemctl status prometheus --no-pager -l"
echo "TSDB dir:   ${PROM_DIR}"
echo "Config dir: ${PROM_CONFIG_DIR}"
echo "Logs file:  ${PROM_LOG_DIR}/prometheus.log"
echo "Reload:     sudo systemctl reload prometheus"
echo "Tail:       tail -f ${PROM_LOG_DIR}/prometheus.log"
