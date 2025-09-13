#!/bin/bash
# Node Exporter (user-mode) installer for RHEL 9.x
# - Installs official node_exporter for the primary login user (not system-wide)
# - Binaries go under $HOME/bin
# - Layout: /etc/exporters/node_exporter, /app/exporters/node_exporter, /logs/exporters/node_exporter
# - Creates a systemd --user unit and starts it (logs via journald)
#
# Usage:
#   chmod +x install_node_exporter_user.sh
#   sudo ./install_node_exporter_user.sh
#
# Tunables via env:
#   NE_VERSION=1.9.1 PORT=9100 ./install_node_exporter_user.sh
#   SHA256_EXPECTED=<sha>        # optional override

set -euo pipefail
IFS=$'\n\t'

# ----------------------------- Tunables ---------------------------------------
NE_VERSION="${NE_VERSION:-1.9.1}"
PORT="${PORT:-9100}"
# ------------------------------------------------------------------------------

# Detect login user
RUN_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
RUN_UID="$(id -u "$RUN_USER")"
RUN_GID="$(id -g "$RUN_USER")"
RUN_HOME="$(getent passwd "$RUN_USER" | awk -F: '{print $6}')"
BIN_DIR="$RUN_HOME/bin"

# Layout (under exporters/)
ETC_DIR="/etc/exporters/node_exporter"
APP_DIR="/app/exporters/node_exporter"
LOG_DIR="/logs/exporters/node_exporter"

info(){ echo -e "\e[1;32m==> $*\e[0m"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }
die(){  echo -e "\e[31m[ERR]\e[0m  $*" >&2; exit 1; }

need_cmd(){
  command -v "$1" &>/dev/null && return 0
  if [[ ${EUID:-$UID} -eq 0 ]] && command -v dnf &>/dev/null; then
    info "Installing missing tool: $1"
    dnf install -y "$2" >/dev/null
  else
    die "Missing command: $1 (install package: $2)"
  fi
}

need_cmd curl curl
need_cmd tar tar
need_cmd sha256sum coreutils
need_cmd systemctl systemd

# Ensure layout
[[ -d "$ETC_DIR" && -w "$ETC_DIR" ]] || mkdir -p "$ETC_DIR"
[[ -d "$APP_DIR" && -w "$APP_DIR" ]] || mkdir -p "$APP_DIR"
mkdir -p "$LOG_DIR"
chown -R "$RUN_UID:$RUN_GID" "$LOG_DIR" "$APP_DIR" "$ETC_DIR"
chmod 2770 "$LOG_DIR" "$APP_DIR" "$ETC_DIR"

# Prepare $HOME/bin
info "Preparing binaries directory for $RUN_USER: $BIN_DIR"
mkdir -p "$BIN_DIR"
chown -R "$RUN_UID:$RUN_GID" "$BIN_DIR"
chmod 0755 "$BIN_DIR"

# ---------------------- Download + verify ----------------------
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"

TARBALL="node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
BASE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}"

info "Downloading Node Exporter v${NE_VERSION}..."
curl -fsSLO "${BASE_URL}/${TARBALL}"

HAVE_SUMS=0
if curl -fsSLO "${BASE_URL}/sha256sums.txt"; then
  HAVE_SUMS=1
fi

info "Verifying SHA256..."
if [[ $HAVE_SUMS -eq 1 ]] && grep -qE "  ${TARBALL}\$" sha256sums.txt; then
  grep -E "  ${TARBALL}\$" sha256sums.txt | sha256sum -c -
elif [[ -n "${SHA256_EXPECTED:-}" ]]; then
  actual="$(sha256sum "${TARBALL}" | awk '{print $1}')"
  [[ "$SHA256_EXPECTED" == "$actual" ]] || die "SHA256 mismatch: expected ${SHA256_EXPECTED}, got ${actual}"
  info "SHA256 OK (from SHA256_EXPECTED env)"
elif [[ "$NE_VERSION" == "1.9.1" ]]; then
  expected="becb950ee80daa8ae7331d77966d94a611af79ad0d3307380907e0ec08f5b4e8"
  actual="$(sha256sum "${TARBALL}" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || die "SHA256 mismatch: expected ${expected}, got ${actual}"
  info "SHA256 OK (fallback for 1.9.1 linux-amd64)"
else
  die "No checksums file found and no SHA256_EXPECTED provided — aborting."
fi

info "Extracting..."
tar xf "$TARBALL"
cd "node_exporter-${NE_VERSION}.linux-amd64"
# ---------------------------------------------------------------

# ---------------------- Install binaries -----------------------
info "Installing binary to $BIN_DIR"
install -o "$RUN_UID" -g "$RUN_GID" -m 0755 node_exporter "$BIN_DIR/node_exporter"
# ---------------------------------------------------------------

# Restore SELinux contexts
if command -v restorecon &>/dev/null; then
  info "Restoring SELinux contexts (if applicable)..."
  restorecon -RF "$ETC_DIR" "$APP_DIR" "$LOG_DIR" || true
fi

# ---------------------- systemd --user unit --------------------
USER_SYSTEMD_DIR="$RUN_HOME/.config/systemd/user"
UNIT_PATH="$USER_SYSTEMD_DIR/node_exporter.service"
info "Creating user systemd unit: $UNIT_PATH"
mkdir -p "$USER_SYSTEMD_DIR"
chown -R "$RUN_UID:$RUN_GID" "$RUN_HOME/.config" "$USER_SYSTEMD_DIR"

cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Prometheus Node Exporter (user)
Documentation=https://prometheus.io/docs/guides/node-exporter/
After=network.target

[Service]
Type=simple
UMask=007
WorkingDirectory=/app/exporters/node_exporter

ExecStart=%h/bin/node_exporter --web.listen-address=:${PORT}

SyslogIdentifier=node_exporter
Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s
LimitNOFILE=65536

[Install]
WantedBy=default.target
UNIT

chown "$RUN_UID:$RUN_GID" "$UNIT_PATH"
chmod 0644 "$UNIT_PATH"
# ---------------------------------------------------------------

# DBus env
RUN_ENV=( "XDG_RUNTIME_DIR=/run/user/${RUN_UID}" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${RUN_UID}/bus" )

# Reload & linger
info "Reloading user systemd daemon..."
sudo -u "$RUN_USER" env "${RUN_ENV[@]}" systemctl --user daemon-reload

if loginctl show-user "$RUN_USER" 2>/dev/null | grep -q 'Linger=yes'; then
  info "Linger=yes for $RUN_USER"
else
  if [[ ${EUID:-$UID} -eq 0 ]]; then
    info "Enabling lingering for $RUN_USER"
    loginctl enable-linger "$RUN_USER" || warn "Could not enable lingering"
  fi
fi

# Enable + start
info "Enabling and starting Node Exporter (user unit)..."
sudo -u "$RUN_USER" env "${RUN_ENV[@]}" systemctl --user enable --now node_exporter.service || true

# Firewall
if command -v firewall-cmd &>/dev/null; then
  info "Configuring firewall for Node Exporter (port ${PORT})..."
  sudo firewall-cmd --add-port=${PORT}/tcp --permanent || warn "Failed to add port ${PORT}"
  sudo firewall-cmd --reload || warn "Failed to reload firewall"
  sudo firewall-cmd --list-ports || true
else
  warn "firewalld not installed, skipped port configuration"
fi

# --------------------------- Summary ---------------------------
NE_VER_STR="$("$BIN_DIR/node_exporter" --version 2>&1 | head -n1 || echo "node_exporter $NE_VERSION")"
info "========== INSTALLATION COMPLETE =========="
echo "Binary:     $NE_VER_STR"
echo "Unit:       $UNIT_PATH"
echo "Config dir: $ETC_DIR"
echo "Data dir:   $APP_DIR"
echo "Logs dir:   $LOG_DIR"
echo "Web UI:     http://$(hostname -f 2>/dev/null || hostname):${PORT}/metrics"
echo
echo "Manage:     systemctl --user status node_exporter"
echo "Logs:       journalctl _SYSTEMD_USER_UNIT=node_exporter.service -f"
