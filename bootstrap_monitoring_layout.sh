#!/bin/bash
# Bootstrap monitoring layout for *my* login user (even when run with sudo)
# - Creates /etc/<svc>, /app/<svc>, /logs/<svc>
# - Owner = my real login user (not root), Group = monitorconfig
# - Sets safe perms (2770) so group members can read/write; others denied
# - Enables lingering for your user so systemd --user services start at boot
#   LINGERING: lets user services auto-start after reboot even if you haven't logged in yet.

set -euo pipefail

# Detect the real human user when running via sudo; fall back safely.
ME="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
GROUP_CFG="monitorconfig"
SERVICES=(prometheus grafana pushgateway exporters ml)

msg(){ echo -e "\e[1;32m==> $*\e[0m"; }
need_root(){ [[ $EUID -eq 0 ]] || { echo "Run with sudo/root"; exit 1; }; }

need_root

# 1) Ensure the shared group exists; add my user to it
getent group "$GROUP_CFG" >/dev/null || groupadd "$GROUP_CFG"
usermod -aG "$GROUP_CFG" "$ME" || true

# 2) Create per-service dirs under /etc, /app, /logs, owned by *my* user
for svc in "${SERVICES[@]}"; do
  mkdir -p "/etc/$svc" "/app/$svc" "/logs/$svc"
  chown -R "$ME:$GROUP_CFG" "/etc/$svc" "/app/$svc" "/logs/$svc"
  chmod 2770 "/etc/$svc" "/app/$svc" "/logs/$svc"   # setgid: keep group on new files/dirs
done

msg "Prepared /etc, /app, /logs for: ${SERVICES[*]}"
msg "Owner: $ME, Group: $GROUP_CFG (others denied). Logging stays on journald by default."

# 3) Enable lingering for *my* user (not root) so user services start at boot
if command -v loginctl >/dev/null; then
  if loginctl enable-linger "$ME"; then
    msg "Enabled lingering for '$ME' (user services will auto-start after reboot)."
  else
    echo "[WARN] Couldn't enable lingering automatically. Run: sudo loginctl enable-linger $ME"
  fi
else
  echo "[WARN] loginctl not found; skip lingering."
fi

# Tip for current shell: new group membership applies on next login/session
echo "NOTE: re-login (or run: newgrp $GROUP_CFG) so your shell picks up the group."
