#!/bin/bash
# Pushgateway (user-mode) installer for RHEL 9.x
# - Installs official pushgateway for the primary login user (not system-wide)
# - Binaries go under $HOME/bin
# - Layout: /etc/pushgateway, /app/pushgateway, /logs/pushgateway
# - Creates systemd --user unit and starts it (logs via journald)
#
# Usage:
#   chmod +x install_pushgateway_user.sh
#   sudo ./install_pushgateway_user.sh
#
# Tunables via env:
#   PGW_VERSION=1.11.1 PORT=9091 ./install_pushgateway_user.sh
#   SHA256_EXPECTED=<sha>  # optional: force expected checksum

set -euo pipefail
IFS=$'\n\t'

# ----------------------------- Tunables ---------------------------------------
PGW_VERSION="${PGW_VERSION:-1.11.1}"
PORT="${PORT:-9091}"
# ------------------------------------------------------------------------------

# Detect the real login user even under sudo
RUN_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
RUN_UID="$(id -u "$RUN_USER")"
RUN_GID="$(id -g "$RUN_USER")"
RUN_HOME="$(getent passwd "$RUN_USER" | awk -F: '{print $6}')"
BIN_DIR="$RUN_HOME/bin"

# Layout (prepared by your bootstrap script)
ETC_DIR="/etc/pushgateway"
APP_DIR="/app/pushgateway"
LOG_DIR="/logs/pushgateway"
DATA_FILE="$APP_DIR/pushgateway.data"

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

# Minimal deps
need_cmd curl curl
need_cmd tar tar
need_cmd sha256sum coreutils
need_cmd systemctl systemd

# Ensure layout exists & writable (from bootstrap)
[[ -d "$ETC_DIR" && -w "$ETC_DIR" ]] || die "$ETC_DIR missing or not writable. Run bootstrap first."
[[ -d "$APP_DIR" && -w "$APP_DIR" ]] || die "$APP_DIR missing or not writable. Run bootstrap first."
mkdir -p "$LOG_DIR"
chown -R "$RUN_UID:$RUN_GID" "$LOG_DIR" "$APP_DIR" "$ETC_DIR"
chmod 2770 "$LOG_DIR" "$APP_DIR" "$ETC_DIR"

# Prepare $HOME/bin
info "Preparing binaries directory for $RUN_USER: $BIN_DIR"
mkdir -p "$BIN_DIR"
chown -R "$RUN_UID:$RUN_GID" "$BIN_DIR"
chmod 0755 "$BIN_DIR"

# Download tarball + checksums
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"

TARBALL="pushgateway-${PGW_VERSION}.linux-amd64.tar.gz"
BASE_URL="https://github.com/prometheus/pushgateway/releases/download/v${PGW_VERSION}"

info "Downloading Pushgateway v${PGW_VERSION}..."
curl -fsSLO "${BASE_URL}/${TARBALL}"

# Try to fetch sha256sums.txt (preferred)
HAVE_SUMS=0
if curl -fsSLO "${BASE_URL}/sha256sums.txt"; then
  HAVE_SUMS=1
fi

# Verify SHA256
info "Verifying SHA256..."
if [[ $HAVE_SUMS -eq 1 ]] && grep -qE "  ${TARBALL}\$" sha256sums.txt; then
  grep -E "  ${TARBALL}\$" sha256sums.txt | sha256sum -c -
elif [[ -n "${SHA256_EXPECTED:-}" ]]; then
  actual="$(sha256sum "${TARBALL}" | awk '{print $1}')"
  [[ "$SHA256_EXPECTED" == "$actual" ]] || die "SHA256 mismatch: expected ${SHA256_EXPECTED}, got ${actual}"
  info "SHA256 OK (from SHA256_EXPECTED env)"
elif [[ "$PGW_VERSION" == "1.11.1" ]]; then
  # Fallback to the checksum you provided for linux-amd64 1.11.1
  expected="6ce6ffab84d0d71195036326640295c02165462abd12b8092b0fa93188f5ee37"
  actual="$(sha256sum "${TARBALL}" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || die "SHA256 mismatch: expected ${expected}, got ${actual}"
  info "SHA256 OK (fallback for 1.11.1 linux-amd64)"
else
  die "No checksums file found and no SHA256_EXPECTED provided — aborting for safety."
fi

# Extract & install
info "Extracting..."
tar xf "$TARBALL"
cd "pushgateway-${PGW_VERSION}.linux-amd64"

info "Installing binary to $BIN_DIR"
install -o "$RUN_UID" -g "$RUN_GID" -m 0755 pushgateway "$BIN_DIR/pushgateway"

# Prepare data file for persistence
info "Preparing data file: $DATA_FILE"
touch "$DATA_FILE"
chown "$RUN_UID:$RUN_GID" "$DATA_FILE"
chmod 0660 "$DATA_FILE"

# Restore SELinux contexts if available (no new rules added here)
if command -v restorecon &>/dev/null; then
  info "Restoring SELinux contexts (if applicable)..."
  restorecon -RF "$ETC_DIR" "$APP_DIR" "$LOG_DIR" || true
fi

# Create systemd --user unit
USER_SYSTEMD_DIR="$RUN_HOME/.config/systemd/user"
UNIT_PATH="$USER_SYSTEMD_DIR/pushgateway.service"
info "Creating user systemd unit: $UNIT_PATH"
mkdir -p "$USER_SYSTEMD_DIR"
chown -R "$RUN_UID:$RUN_GID" "$RUN_HOME/.config" "$USER_SYSTEMD_DIR"

cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Prometheus Pushgateway (user)
Documentation=https://github.com/prometheus/pushgateway
After=network.target

[Service]
Type=simple
UMask=007
WorkingDirectory=/app/pushgateway

# Main process
ExecStart=%h/bin/pushgateway \\
  --web.listen-address=:${PORT} \\
  --persistence.file=/app/pushgateway/pushgateway.data \\
  --log.level=warn

# Journald tag
SyslogIdentifier=pushgateway

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

# Reload user systemd & ensure lingering
info "Reloading user systemd daemon..."
sudo -u "$RUN_USER" env "${RUN_ENV[@]}" systemctl --user daemon-reload

if loginctl show-user "$RUN_USER" 2>/dev/null | grep -q 'Linger=yes'; then
  info "Linger=yes for $RUN_USER (auto-start on boot enabled)"
else
  if [[ ${EUID:-$UID} -eq 0 ]]; then
    info "Enabling lingering for $RUN_USER"
    loginctl enable-linger "$RUN_USER" || warn "Could not enable lingering automatically"
  else
    warn "Lingering not enabled. Ask an admin to: sudo loginctl enable-linger $RUN_USER"
  fi
fi

# Enable + start
info "Enabling and starting Pushgateway (user unit)..."
sudo -u "$RUN_USER" env "${RUN_ENV[@]}" systemctl --user enable --now pushgateway.service || true

# Open firewall port 9091 (optional; best effort)
if command -v firewall-cmd &>/dev/null; then
  info "Configuring firewall for Pushgateway (port ${PORT})..."
  sudo firewall-cmd --add-port=${PORT}/tcp --permanent || warn "Failed to add port ${PORT}"
  sudo firewall-cmd --reload || warn "Failed to reload firewall"
  sudo firewall-cmd --list-ports || true
else
  warn "firewalld not installed, skipped port configuration"
fi

# Final summary
PGW_VER_STR="$("$BIN_DIR/pushgateway" --version 2>&1 | head -n 1 || echo "pushgateway $PGW_VERSION")"
info "========== INSTALLATION COMPLETE =========="
echo "Binary:     $PGW_VER_STR"
echo "Unit:       $UNIT_PATH"
echo "Data file:  $DATA_FILE"
echo "Web UI:     http://$(hostname -f 2>/dev/null || hostname):${PORT}"
echo
echo "Manage:     systemctl --user status pushgateway"
echo "Logs:       journalctl _SYSTEMD_USER_UNIT=pushgateway.service -f"
