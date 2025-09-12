#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Prometheus installer for RHEL 9.6 (x86_64)
# - Installs official release with SHA256 verification
# - Runs as invoking login user (SUDO_USER)
# - TSDB at /app/prometheus
# - Logs combined into /logs/prometheus/prometheus.log (plus journald) with logrotate
# - Preserves Prometheus defaults (no WAL compression, no custom retention)
# - Adds ExecReload to send SIGHUP via `systemctl reload prometheus`
# -----------------------------------------------------------------------------

PROM_VERSION="3.5.0"                    # sets the Prometheus release version to download
PROM_DIR="/app/prometheus"              # sets the TSDB data directory path
PROM_CONFIG_DIR="/etc/prometheus"       # sets the configuration directory path
PROM_LOG_DIR="/logs/prometheus"         # sets the log directory path
PORT="9090"                             # sets the HTTP listen port for the web UI and API

print_status(){ echo -e "\e[1;32m$1\e[0m"; }  # prints a green status line to stdout

# require root privileges to write binaries, units, and system paths
if [[ $EUID -ne 0 ]]; then
  echo "run with sudo/root" >&2
  exit 1
fi

# resolve the non-root login user to run the service under (prefers SUDO_USER)
RUN_USER="${SUDO_USER:-$(id -un)}"      # reads invoking user from env or current user
RUN_GROUP="$(id -gn "$RUN_USER")"       # reads the primary group for the resolved user

print_status "==> Service will run as: ${RUN_USER}:${RUN_GROUP}"

# map required commands to their RHEL packages and install if missing
declare -A CMD2PKG=(
  [curl]=curl                            # used to download release artifacts
  [tar]=tar                              # used to extract the tarball
  [sha256sum]=coreutils                  # used to verify checksums
  [systemctl]=systemd                    # used to manage the systemd service
  [tee]=coreutils                        # used for stream redirection when needed
  [logrotate]=logrotate                  # used to rotate log files
  [restorecon]=policycoreutils           # used to restore SELinux contexts
  [firewall-cmd]=firewalld               # used to manage firewall ports
)
for cmd in "${!CMD2PKG[@]}"; do
  command -v "$cmd" &>/dev/null || {      # checks if command is available
    print_status "==> Installing ${CMD2PKG[$cmd]}"
    dnf install -y "${CMD2PKG[$cmd]}" >/dev/null  # installs the corresponding package
  }
done

print_status "==> Creating directories..."
mkdir -p "$PROM_DIR" "$PROM_CONFIG_DIR" "$PROM_LOG_DIR"  # creates TSDB, config, and log directories
mkdir -p /logs                                          # ensures the parent /logs path exists

chown -R "$RUN_USER:$RUN_GROUP" "$PROM_DIR"             # sets ownership of TSDB directory to the service user
chmod 0750 "$PROM_DIR"                                  # sets TSDB directory permissions: rwx for owner, rx for group

chmod 1777 /logs                                        # sets mode on /logs to allow read/write/execute for all with sticky bit
chown -R "$RUN_USER:$RUN_GROUP" "$PROM_LOG_DIR"         # sets ownership of the log directory to the service user
chmod 1777 "$PROM_LOG_DIR"                              # sets log directory permissions with sticky bit

chmod 1777 "$PROM_CONFIG_DIR"                           # sets config directory permissions with sticky bit

print_status "==> Downloading Prometheus v${PROM_VERSION}..."
TMPDIR="$(mktemp -d)"                                   # allocates a temporary working directory
trap 'rm -rf "$TMPDIR"' EXIT                            # schedules removal of the temp directory on script exit
cd "$TMPDIR"                                            # changes current directory to the temporary workspace
TARBALL="prometheus-${PROM_VERSION}.linux-amd64.tar.gz" # defines the release tarball name
BASE_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}"  # defines the release base URL
curl -sSLO "${BASE_URL}/${TARBALL}"                     # downloads the release tarball
curl -sSLO "${BASE_URL}/sha256sums.txt}" || true        # downloads the checksums list (some releases use this name)
if [[ ! -f sha256sums.txt ]]; then                      # verifies checksum file name and falls back if needed
  curl -sSLO "${BASE_URL}/sha256sums.txt"
fi

print_status "==> Verifying checksum..."
grep -E "  ${TARBALL}\$" sha256sums.txt | sha256sum -c -  # validates the tarball against the expected checksum

print_status "==> Extracting and installing binaries..."
tar xf "$TARBALL"                                       # extracts the tarball contents
cd "prometheus-${PROM_VERSION}.linux-amd64"             # changes into the extracted release directory
install -o root -g root -m 0755 prometheus /usr/local/bin/prometheus  # installs the Prometheus binary into PATH
install -o root -g root -m 0755 promtool   /usr/local/bin/promtool    # installs the promtool utility into PATH

print_status "==> Installing configuration..."
install -o root -g "$RUN_GROUP" -m 0666 prometheus.yml "${PROM_CONFIG_DIR}/prometheus.yml" || true  # copies the default config file
[ -d consoles ] && cp -r consoles "${PROM_CONFIG_DIR}/"                  # copies the consoles directory if present
[ -d console_libraries ] && cp -r console_libraries "${PROM_CONFIG_DIR}/" # copies the console_libraries directory if present

if command -v restorecon &>/dev/null; then
  print_status "==> Restoring SELinux contexts..."
  restorecon -R /usr/local/bin "$PROM_CONFIG_DIR" "$PROM_DIR" "$PROM_LOG_DIR" || true  # restores SELinux labels recursively
fi

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

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
MemoryDenyWriteExecute=true
CapabilityBoundingSet=
ReadWritePaths=${PROM_DIR} ${PROM_CONFIG_DIR} ${PROM_LOG_DIR}

Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

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

if systemctl is-active --quiet firewalld; then
  print_status "==> Opening firewall port ${PORT}/tcp..."
  firewall-cmd --add-port=${PORT}/tcp --permanent >/dev/null || true  # adds the port rule to firewalld
  firewall-cmd --reload >/dev/null || true                            # reloads firewalld configuration
fi

print_status "==> Enabling and starting Prometheus..."
systemctl daemon-reload                                              # reloads systemd unit files
systemctl enable --now prometheus                                    # enables and starts the Prometheus service

chmod 0666 ${PROM_LOG_DIR}/*.log 2>/dev/null || true                 # ensures the log file permission mode
chown -R "${RUN_USER}:${RUN_GROUP}" "${PROM_DIR}" "${PROM_LOG_DIR}"  # ensures directory ownership

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"                   # reads the primary IP address
HOST="$(hostname -f 2>/dev/null || hostname)"                        # reads the FQDN or short hostname
print_status "========== INSTALLATION COMPLETE =========="
echo "Prometheus: $(/usr/local/bin/prometheus --version | head -n1)"
echo "Promtool:   $(/usr/local/bin/promtool --version | head -n1)"
echo "Web UI:     http://${IP:-$HOST}:${PORT}"
echo "Service:    systemctl status prometheus --no-pager -l"
echo "TSDB dir:   ${PROM_DIR}"
echo "Config dir: ${PROM_CONFIG_DIR}"
echo "Logs file:  ${PROM_LOG_DIR}/prometheus.log"
echo "Reload:     sudo systemctl reload prometheus"
echo "Logs tail:  tail -f ${PROM_LOG_DIR}/prometheus.log"
