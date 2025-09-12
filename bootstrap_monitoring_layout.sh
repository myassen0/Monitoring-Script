#!/bin/bash
# Bootstrap monitoring layout for *your* login user (even when run with sudo)
# - Creates /etc/<svc>, /app/<svc>, /logs/<svc> for: prometheus, grafana, pushgateway, exporters, ml, alertmanager
# - Owner = your real login user (not root), Group = monitorconfig
# - Sets safe perms (2770) so group members can read/write; others denied
# - Enables lingering for your user so systemd --user services start at boot

set -euo pipefail

ME="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
GROUP_CFG="monitorconfig"
SERVICES=(prometheus grafana pushgateway exporters ml alertmanager)

msg(){ echo -e "\e[1;32m==> $*\e[0m"; }
need_root(){ [[ $EUID -eq 0 ]] || { echo "Run with sudo/root"; exit 1; }; }

need_root

getent group "$GROUP_CFG" >/dev/null || groupadd "$GROUP_CFG"
usermod -aG "$GROUP_CFG" "$ME" || true

for svc in "${SERVICES[@]}"; do
  mkdir -p "/etc/$svc" "/app/$svc" "/logs/$svc"
  chown -R "$ME:$GROUP_CFG" "/etc/$svc" "/app/$svc" "/logs/$svc"
  chmod 2770 "/etc/$svc" "/app/$svc" "/logs/$svc"
done

msg "Prepared /etc, /app, /logs for: ${SERVICES[*]}"
msg "Owner: $ME, Group: $GROUP_CFG (others denied). Logging stays on journald by default."

if command -v loginctl >/dev/null; then
  if loginctl enable-linger "$ME"; then
    msg "Enabled lingering for '$ME' (user services will auto-start after reboot)."
  else
    echo "[WARN] Couldn't enable lingering automatically. Run: sudo loginctl enable-linger $ME"
  fi
else
  echo "[WARN] loginctl not found; skip lingering."
fi

echo "NOTE: re-login (or run: newgrp $GROUP_CFG) so your shell picks up the group."
