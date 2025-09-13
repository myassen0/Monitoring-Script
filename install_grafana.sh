#!/bin/bash
# Grafana (user-mode) installer for RHEL 9.x
# - Installs grafana-server + grafana + grafana-cli for the primary login user
# - Binaries go to $HOME/bin (easy self-update later without sudo)
# - Uses /etc/grafana, /app/grafana, /logs/grafana layout (created earlier by bootstrap)
# - Copies full Grafana distribution to /app/grafana/home and runs with --homepath there
# - Creates a systemd --user unit and starts it (logs via journald)
#
# Usage:
#   chmod +x install_grafana.sh
#   sudo ./install_grafana.sh
#
# Verify:
#   systemctl --user status grafana
#   journalctl _SYSTEMD_USER_UNIT=grafana.service -f
#   curl -sf localhost:3000/login >/dev/null && echo "GRAFANA UP"

set -euo pipefail
IFS=$'\n\t'

# ----------------------------- Tunables ---------------------------------------
GRAFANA_VERSION="${GRAFANA_VERSION:-12.1.1}"
PORT="${PORT:-3000}"
# ------------------------------------------------------------------------------

RUN_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
RUN_UID="$(id -u "$RUN_USER")"
RUN_GID="$(id -g "$RUN_USER")"
RUN_HOME="$(getent passwd "$RUN_USER" | awk -F: '{print $6}')"
BIN_DIR="$RUN_HOME/bin"

GRA_ETC="/etc/grafana"
GRA_APP="/app/grafana"
GRA_HOME="$GRA_APP/home"
GRA_PROV="$GRA_ETC/provisioning"
GRA_LOG="/logs/grafana"

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

[[ -d "$GRA_ETC" && -w "$GRA_ETC" ]] || die "$GRA_ETC missing or not writable. Run bootstrap first."
[[ -d "$GRA_APP" && -w "$GRA_APP" ]] || die "$GRA_APP missing or not writable. Run bootstrap first."
mkdir -p "$GRA_PROV" "$GRA_APP/plugins" "$GRA_LOG"

chown -R "$RUN_UID:$RUN_GID" "$GRA_LOG"
chmod 2770 "$GRA_LOG"

info "Preparing binaries directory for $RUN_USER: $BIN_DIR"
mkdir -p "$BIN_DIR"
chown -R "$RUN_UID:$RUN_GID" "$BIN_DIR"
chmod 0755 "$BIN_DIR"

TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"

TARBALL="grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz"
BASE_URL="https://dl.grafana.com/oss/release"

info "Downloading Grafana v${GRAFANA_VERSION}..."
curl -fsSLO "${BASE_URL}/${TARBALL}"
curl -fsSLO "${BASE_URL}/${TARBALL}.sha256"

info "Verifying SHA256..."
if grep -q "${TARBALL}" "${TARBALL}.sha256" 2>/dev/null; then
  sha256sum -c "${TARBALL}.sha256"
else
  expected="$(tr -d ' \n\r' < "${TARBALL}.sha256")"
  actual="$(sha256sum "${TARBALL}" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || die "SHA256 mismatch: expected ${expected}, got ${actual}"
  info "SHA256 OK"
fi

info "Extracting..."
tar xf "$TARBALL"
cd "grafana-${GRAFANA_VERSION}"

info "Installing binaries to $BIN_DIR"
install -o "$RUN_UID" -g "$RUN_GID" -m 0755 bin/grafana-server "$BIN_DIR/grafana-server"
install -o "$RUN_UID" -g "$RUN_GID" -m 0755 bin/grafana        "$BIN_DIR/grafana"
install -o "$RUN_UID" -g "$RUN_GID" -m 0755 bin/grafana-cli    "$BIN_DIR/grafana-cli"

info "Syncing Grafana home (runtime assets) to $GRA_HOME"
rm -rf "$GRA_HOME"
mkdir -p "$GRA_HOME"
shopt -s dotglob extglob
cp -a !(bin) "$GRA_HOME"/
shopt -u dotglob extglob
chown -R "$RUN_UID:$RUN_GID" "$GRA_HOME"
chmod -R 2750 "$GRA_HOME"

if [[ ! -f "$GRA_ETC/grafana.ini" ]]; then
  info "Writing default $GRA_ETC/grafana.ini"
  cat > "$GRA_ETC/grafana.ini" <<'INI'
[server]
http_addr =
http_port = 3000

[paths]

[security]
admin_user = admin
admin_password = admin

[log]
mode = console
level = warn
INI
  chown "$RUN_UID:$RUN_GID" "$GRA_ETC/grafana.ini"
  chmod 0660 "$GRA_ETC/grafana.ini"
else
  info "Existing grafana.ini found; leaving it untouched."
fi

mkdir -p "$GRA_PROV"
chown -R "$RUN_UID:$RUN_GID" "$GRA_ETC"
chmod -R 2770 "$GRA_ETC"

if command -v restorecon &>/dev/null; then
  info "Restoring SELinux contexts (if applicable)..."
  restorecon -RF "$GRA_ETC" "$GRA_APP" "$GRA_LOG" || true
fi

USER_SYSTEMD_DIR="$RUN_HOME/.config/systemd/user"
UNIT_PATH="$USER_SYSTEMD_DIR/grafana.service"
info "Creating user systemd unit: $UNIT_PATH"
mkdir -p "$USER_SYSTEMD_DIR"
chown -R "$RUN_UID:$RUN_GID" "$RUN_HOME/.config" "$USER_SYSTEMD_DIR"

cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Grafana (user)
Documentation=https://grafana.com/docs/
After=network.target

[Service]
Type=simple
UMask=007
WorkingDirectory=/app/grafana

Environment=GF_PATHS_CONFIG=/etc/grafana/grafana.ini
Environment=GF_PATHS_DATA=/app/grafana
Environment=GF_PATHS_LOGS=/logs/grafana
Environment=GF_PATHS_PLUGINS=/app/grafana/plugins
Environment=GF_PATHS_PROVISIONING=/etc/grafana/provisioning
Environment=GF_LOG_MODE=console
Environment=GF_LOG_LEVEL=warn
Environment=GF_SERVER_HTTP_PORT=${PORT}

ExecStart=%h/bin/grafana-server --homepath=/app/grafana/home \
  --config=/etc/grafana/grafana.ini

SyslogIdentifier=grafana
Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s
LimitNOFILE=65536

[Install]
WantedBy=default.target
UNIT

chown "$RUN_UID:$RUN_GID" "$UNIT_PATH"
chmod 0644 "$UNIT_PATH"

RUN_ENV=( "XDG_RUNTIME_DIR=/run/user/${RUN_UID}" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${RUN_UID}/bus" )

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

info "Enabling and starting Grafana (user unit)..."
sudo -u "$RUN_USER" env "${RUN_ENV[@]}" systemctl --user enable --now grafana.service || true

# -------------------------------------------------
# firewalld
if command -v firewall-cmd &>/dev/null; then
  info "Configuring firewall for Grafana (port 3000)..."
  sudo firewall-cmd --add-port=3000/tcp --permanent || warn "Failed to add port 3000"
  sudo firewall-cmd --reload || warn "Failed to reload firewall"
  sudo firewall-cmd --list-ports
else
  warn "firewalld not installed, skipped port configuration"
fi
# -------------------------------------------------

GRA_VER_STR="$("$BIN_DIR/grafana-server" -v 2>&1 || echo "grafana $GRAFANA_VERSION")"
info "========== INSTALLATION COMPLETE =========="
echo "Binary:     $GRA_VER_STR"
echo "Unit:       $UNIT_PATH"
echo "Config:     $GRA_ETC/grafana.ini"
echo "Data dir:   $GRA_APP"
echo "Home path:  $GRA_HOME"
echo "Web UI:     http://$(hostname -f 2>/dev/null || hostname):${PORT}"
echo
echo "Manage:     systemctl --user status grafana"
echo "Logs:       journalctl _SYSTEMD_USER_UNIT=grafana.service -f"
echo "Config:  ${GRAFANA_CONF_FILE}"
echo "Logs:    ${GRAFANA_LOG_FILE}"
echo "Reload:  sudo systemctl reload grafana"
echo "Tail:    tail -f ${GRAFANA_LOG_FILE}"
