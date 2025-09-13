#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Prometheus (user-mode) installer for RHEL 9.x
# - Installs official Prometheus + promtool for the *primary login user* (not system-wide)
# - Binaries go under $HOME/bin so you can update later without sudo
# - Uses /etc/prometheus and /app/prometheus created earlier by the bootstrap script
# - Copies web assets (consoles + console_libraries) *if present* in the tarball
# - Creates a systemd --user unit and starts it (logs via journald)
# - Safe perms (UMask=007). No SupplementaryGroups to avoid user-manager GROUP errors.
#
# Usage:
#   chmod +x install_prometheus_user.sh
#   sudo ./install_prometheus_user.sh
#
# Verify:
#   systemctl --user status prometheus
#   journalctl _SYSTEMD_USER_UNIT=prometheus.service -f
#   curl -sf localhost:9090/-/ready && echo READY
#
# WAL compression flag is NOT set explicitly (modern Prometheus enables it by default).
# To force-disable later, add: --storage.tsdb.wal-compression=false to ExecStart.

set -euo pipefail
IFS=$'\n\t'

# ----------------------------- Tunables ---------------------------------------
PROM_VERSION="${PROM_VERSION:-3.5.0}"     # change via env if needed
PORT="${PORT:-9090}"                      # Prometheus web port
RETENTION="${RETENTION:-15d}"             # e.g., 15d / 30d / 6w
# ------------------------------------------------------------------------------

# Detect the real login user even under sudo (so we target their $HOME)
RUN_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
RUN_UID="$(id -u "$RUN_USER")"
RUN_GID="$(id -g "$RUN_USER")"
RUN_HOME="$(getent passwd "$RUN_USER" | awk -F: '{print $6}')"
BIN_DIR="$RUN_HOME/bin"

# Expected layout from bootstrap
PROM_ETC="/etc/prometheus"
PROM_DIR="/app/prometheus"
RULES_DIR="$PROM_ETC/rules.d"
CONS_DIR="$PROM_ETC/consoles"
CONSLIB_DIR="$PROM_ETC/console_libraries"

# Helpers
info(){ echo -e "\e[1;32m==> $*\e[0m"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }
die(){  echo -e "\e[31m[ERR]\e[0m  $*" >&2; exit 1; }

# Ensure a command exists; if running as root and dnf available, install it; otherwise fail.
need_cmd(){
  command -v "$1" &>/dev/null && return 0
  if [[ ${EUID:-$UID} -eq 0 ]] && command -v dnf &>/dev/null; then
    info "Installing missing tool: $1"
    dnf install -y "$2" >/dev/null
  else
    die "Missing command: $1 (install package: $2)"
  fi
}

# Minimal deps
need_cmd curl curl
need_cmd tar tar
need_cmd sha256sum coreutils
need_cmd systemctl systemd

# Ensure bootstrap-created paths exist and are writable
[[ -d "$PROM_ETC" && -w "$PROM_ETC" ]] || die "$PROM_ETC missing or not writable. Run bootstrap first."
[[ -d "$PROM_DIR" && -w "$PROM_DIR" ]] || die "$PROM_DIR missing or not writable. Run bootstrap first."
mkdir -p "$RULES_DIR"

# Prepare $HOME/bin for binaries
info "Preparing binaries directory for $RUN_USER: $BIN_DIR"
mkdir -p "$BIN_DIR"
chown -R "$RUN_UID:$RUN_GID" "$BIN_DIR"
chmod 0755 "$BIN_DIR"

# Download official release tarball + checksums, then verify SHA256
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"
TARBALL="prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
BASE_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}"

info "Downloading Prometheus v${PROM_VERSION}..."
curl -fsSLO "${BASE_URL}/${TARBALL}"
curl -fsSLO "${BASE_URL}/sha256sums.txt"

info "Verifying SHA256..."
grep -E "  ${TARBALL}\$" sha256sums.txt | sha256sum -c -

# Extract the tarball
info "Extracting..."
tar xf "$TARBALL"
cd "prometheus-${PROM_VERSION}.linux-amd64"

# Install binaries under $HOME/bin (not system-wide)
info "Installing binaries to $BIN_DIR"
install -o "$RUN_UID" -g "$RUN_GID" -m 0755 prometheus "$BIN_DIR/prometheus"
install -o "$RUN_UID" -g "$RUN_GID" -m 0755 promtool   "$BIN_DIR/promtool"

# Copy web UI assets (consoles + console_libraries) if present
COPIED_CONSOLES=0
if [[ -d consoles && -d console_libraries ]]; then
  info "Copying web assets (consoles + console_libraries) into $PROM_ETC"
  rm -rf "$CONS_DIR" "$CONSLIB_DIR"
  cp -a consoles "$CONS_DIR"
  cp -a console_libraries "$CONSLIB_DIR"
  chown -R "$RUN_UID:$RUN_GID" "$CONS_DIR" "$CONSLIB_DIR"
  chmod -R 2750 "$CONS_DIR" "$CONSLIB_DIR"
  COPIED_CONSOLES=1
else
  warn "Web assets not found in tarball; Prometheus will run without console templates"
fi

# Seed a minimal config if none exists (safe perms 0660; group inherited by setgid on /etc/prometheus)
if [[ ! -f "$PROM_ETC/prometheus.yml" ]]; then
  info "Writing default $PROM_ETC/prometheus.yml"
  cat > "$PROM_ETC/prometheus.yml" <<'YML'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'pushgateway'
    honor_labels: true
    static_configs:
      - targets: ['localhost:9091']

  # - job_name: 'custom_exporter'
  #   static_configs:
  #     - targets: ['localhost:9200']   # example
YML
  chown "$RUN_UID:$RUN_GID" "$PROM_ETC/prometheus.yml"
  chmod 0660 "$PROM_ETC/prometheus.yml"
else
  info "Existing config found; leaving it untouched."
fi

# Ensure rules directory exists and is group-writable
mkdir -p "$RULES_DIR"
chown -R "$RUN_UID:$RUN_GID" "$RULES_DIR"
chmod 2770 "$RULES_DIR"

# Restore SELinux contexts if available (uses any existing fcontext rules you set)
if command -v restorecon &>/dev/null; then
  info "Restoring SELinux contexts (if applicable)..."
  restorecon -RF "$PROM_ETC" "$PROM_DIR" || true
fi

# Create the user-mode systemd unit under ~/.config/systemd/user/
USER_SYSTEMD_DIR="$RUN_HOME/.config/systemd/user"
UNIT_PATH="$USER_SYSTEMD_DIR/prometheus.service"
info "Creating user systemd unit: $UNIT_PATH"
mkdir -p "$USER_SYSTEMD_DIR"
chown -R "$RUN_UID:$RUN_GID" "$RUN_HOME/.config" "$USER_SYSTEMD_DIR"

# Build optional console flags only if copied
CONSOLE_FLAGS=""
if [[ "$COPIED_CONSOLES" -eq 1 ]]; then
  CONSOLE_FLAGS="\\
  --web.console.templates=/etc/prometheus/consoles \\ 
  --web.console.libraries=/etc/prometheus/console_libraries \\" 
fi

cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Prometheus (user)
Documentation=https://prometheus.io/docs/introduction/overview/
After=network.target

[Service]
Type=simple
# Ensure new files are group-writable; works with setgid on /etc and /app trees
UMask=007
# Good default working directory for relative paths
WorkingDirectory=/app/prometheus

# Validate config before start
ExecStartPre=%h/bin/promtool check config /etc/prometheus/prometheus.yml

# Main process (no explicit WAL flag; default behavior is used)
ExecStart=%h/bin/prometheus \\ 
  --config.file=/etc/prometheus/prometheus.yml ${CONSOLE_FLAGS}
  --storage.tsdb.path=/app/prometheus \\
  --web.listen-address=:${PORT} \\
  --storage.tsdb.retention.time=${RETENTION} \\
  --log.level=warn

# Reload config on SIGHUP
ExecReload=/bin/kill -HUP \$MAINPID

# Tag entries in journald
SyslogIdentifier=prometheus

# Reliability/limits
Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s
LimitNOFILE=65536

[Install]
WantedBy=default.target
UNIT

chown "$RUN_UID:$RUN_GID" "$UNIT_PATH"
chmod 0644 "$UNIT_PATH"

# DBus env for user commands when invoked via sudo/non-interactive shells
RUN_ENV=( "XDG_RUNTIME_DIR=/run/user/${RUN_UID}" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${RUN_UID}/bus" )

# Reload the user systemd instance to pick up the new unit
info "Reloading user systemd daemon..."
sudo -u "$RUN_USER" env "${RUN_ENV[@]}" systemctl --user daemon-reload

# Ensure lingering is enabled so the unit auto-starts after reboot
if loginctl show-user "$RUN_USER" | grep -q 'Linger=yes'; then
  info "Linger=yes for $RUN_USER (auto-start on boot enabled)"
else
  if [[ ${EUID:-$UID} -eq 0 ]]; then
    info "Enabling lingering for $RUN_USER"
    loginctl enable-linger "$RUN_USER" || warn "Could not enable lingering automatically"
  else
    warn "Lingering not enabled. Ask an admin to: sudo loginctl enable-linger $RUN_USER"
  fi
fi

# Enable + start the user unit
info "Enabling and starting Prometheus (user unit)..."
sudo -u "$RUN_USER" env "${RUN_ENV[@]}" systemctl --user enable --now prometheus.service || true

# Final summary
PROM_VER_STR="$("$BIN_DIR/prometheus" --version 2>/dev/null | head -n1 || echo "prometheus $PROM_VERSION")"
info "========== INSTALLATION COMPLETE =========="
echo "Binary:     $PROM_VER_STR"
echo "Unit:       $UNIT_PATH"
echo "Config:     $PROM_ETC/prometheus.yml"
echo "TSDB dir:   $PROM_DIR"
echo "Web UI:     http://$(hostname -f 2>/dev/null || hostname):${PORT}"
echo
echo "Manage:     systemctl --user status prometheus"
echo "Logs:       journalctl _SYSTEMD_USER_UNIT=prometheus.service -f"
echo "Health:     curl -sf localhost:${PORT}/-/ready && echo READY"
