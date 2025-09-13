#!/bin/bash
# Alertmanager (user-mode) installer for RHEL 9.x
# - Installs official Alertmanager for the primary login user (not system-wide)
# - Binaries go under $HOME/bin
# - Layout: /etc/alertmanager, /app/alertmanager, /logs/alertmanager
# - Creates a systemd --user unit and starts it (logs via journald)
#
# Usage:
#   chmod +x install_alertmanager_user.sh
#   sudo ./install_alertmanager_user.sh
#
# Tunables via env:
#   AM_VERSION=0.28.1 PORT=9093 ./install_alertmanager_user.sh
#   SHA256_EXPECTED=<sha>        # optional: force expected checksum (overrides built-ins)

set -euo pipefail
IFS=$'\n\t'

# ----------------------------- Tunables ---------------------------------------
AM_VERSION="${AM_VERSION:-0.28.1}"
PORT="${PORT:-9093}"
# ------------------------------------------------------------------------------

# Detect the real login user even under sudo
RUN_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
RUN_UID="$(id -u "$RUN_USER")"
RUN_GID="$(id -g "$RUN_USER")"
RUN_HOME="$(getent passwd "$RUN_USER" | awk -F: '{print $6}')"
BIN_DIR="$RUN_HOME/bin"

# Layout (consistent with your bootstrap)
ETC_DIR="/etc/alertmanager"
APP_DIR="/app/alertmanager"
LOG_DIR="/logs/alertmanager"

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

# ---------------------- Download + verify ----------------------
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"

TARBALL="alertmanager-${AM_VERSION}.linux-amd64.tar.gz"
BASE_URL="https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}"

info "Downloading Alertmanager v${AM_VERSION}..."
curl -fsSLO "${BASE_URL}/${TARBALL}"

# Try to fetch sha256sums.txt (preferred path on GH releases)
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
elif [[ "$AM_VERSION" == "0.28.1" ]]; then
  # Fallback to checksum you provided for linux-amd64 0.28.1
  expected="5ac7ab5e4b8ee5ce4d8fb0988f9cb275efcc3f181b4b408179fafee121693311"
  actual="$(sha256sum "${TARBALL}" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || die "SHA256 mismatch: expected ${expected}, got ${actual}"
  info "SHA256 OK (fallback for 0.28.1 linux-amd64)"
else
  die "No checksums file found and no SHA256_EXPECTED provided — aborting for safety."
fi

info "Extracting..."
tar xf "$TARBALL"
cd "alertmanager-${AM_VERSION}.linux-amd64"
# ---------------------------------------------------------------

# ---------------------- Install binaries -----------------------
info "Installing binaries to $BIN_DIR"
install -o "$RUN_UID" -g "$RUN_GID" -m 0755 alertmanager "$BIN_DIR/alertmanager"
install -o "$RUN_UID" -g "$RUN_GID" -m 0755 amtool       "$BIN_DIR/amtool"
# ---------------------------------------------------------------

# ---------------------- Seed config (minimal) ------------------
# Minimal, safe-by-default config (routes everything to a dummy webhook).
# استبدل لاحقًا بـ SMTP/Slack/Webhook حسب احتياجك.
if [[ ! -f "$ETC_DIR/alertmanager.yml" ]]; then
  info "Writing default $ETC_DIR/alertmanager.yml"
  cat > "$ETC_DIR/alertmanager.yml" <<'YML'
route:
  receiver: "devnull"
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 5m
  repeat_interval: 3h

receivers:
  - name: "devnull"
    webhook_configs:
      - url: "http://127.0.0.1:1/"   # blackhole; replace with your real notifier

inhibit_rules: []
templates: []
YML
  chown "$RUN_UID:$RUN_GID" "$ETC_DIR/alertmanager.yml"
  chmod 0660 "$ETC_DIR/alertmanager.yml"
else
  info "Existing alertmanager.yml found; leaving it untouched."
fi
# ---------------------------------------------------------------

# Restore SELinux contexts if available (no new semanage rules here)
if command -v restorecon &>/dev/null; then
  info "Restoring SELinux contexts (if applicable)..."
  restorecon -RF "$ETC_DIR" "$APP_DIR" "$LOG_DIR" || true
fi

# ---------------------- systemd --user unit --------------------
USER_SYSTEMD_DIR="$RUN_HOME/.config/systemd/user"
UNIT_PATH="$USER_SYSTEMD_DIR/alertmanager.service"
info "Creating user systemd unit: $UNIT_PATH"
mkdir -p "$USER_SYSTEMD_DIR"
chown -R "$RUN_UID:$RUN_GID" "$RUN_HOME/.config" "$USER_SYSTEMD_DIR"

cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Prometheus Alertmanager (user)
Documentation=https://prometheus.io/docs/alerting/latest/alertmanager/
After=network.target

[Service]
Type=simple
UMask=007
WorkingDirectory=/app/alertmanager

# Validate config before start (amtool check-config returns non-zero on errors)
ExecStartPre=%h/bin/amtool check-config /etc/alertmanager/alertmanager.yml

# Main process
ExecStart=%h/bin/alertmanager \\
  --config.file=/etc/alertmanager/alertmanager.yml \\
  --storage.path=/app/alertmanager \\
  --web.listen-address=:${PORT} \\
  --log.level=warn

# Journald tag
SyslogIdentifier=alertmanager

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
# ---------------------------------------------------------------

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
info "Enabling and starting Alertmanager (user unit)..."
sudo -u "$RUN_USER" env "${RUN_ENV[@]}" systemctl --user enable --now alertmanager.service || true

# Open firewall port (best effort)
if command -v firewall-cmd &>/dev/null; then
  info "Configuring firewall for Alertmanager (port ${PORT})..."
  sudo firewall-cmd --add-port=${PORT}/tcp --permanent || warn "Failed to add port ${PORT}"
  sudo firewall-cmd --reload || warn "Failed to reload firewall"
  sudo firewall-cmd --list-ports || true
else
  warn "firewalld not installed, skipped port configuration"
fi

# --------------------------- Summary ---------------------------
AM_VER_STR="$("$BIN_DIR/alertmanager" --version 2>&1 | head -n1 || echo "alertmanager $AM_VERSION")"
info "========== INSTALLATION COMPLETE =========="
echo "Binary:     $AM_VER_STR"
echo "Unit:       $UNIT_PATH"
echo "Config:     $ETC_DIR/alertmanager.yml"
echo "Data dir:   $APP_DIR"
echo "Web UI:     http://$(hostname -f 2>/dev/null || hostname):${PORT}"
echo
echo "Manage:     systemctl --user status alertmanager"
echo "Logs:       journalctl _SYSTEMD_USER_UNIT=alertmanager.service -f"
