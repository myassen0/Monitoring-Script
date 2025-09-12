# monitor-scripts — Intro & Summary

**Goal:** prepare a clean, auditable baseline for a monitoring server on RHEL 9.x before installing Prometheus / Grafana / Node Exporter / Pushgateway / Alertmanager or custom exporters.

**Operating model (by design):** all services run under the **primary login user** (user-mode systemd). Data, config, and logs are kept separate **per service** to keep operations clear:

- `/etc/<service>` → configuration  
- `/app/<service>` → service data (e.g., Prometheus TSDB, Grafana data)  
- `/logs/<service>` → optional file logs if ever needed (default logging stays on **journald**)  

**Outcomes after these two scripts:**
- A crisp security/readiness snapshot that highlights blockers *before* any installs.
- A standardized directory layout owned by your primary user, plus a shared group `monitorconfig`.
- **Lingering** enabled for your user so **`systemd --user` units auto-start on boot** (no interactive login required).

---

## 1) `security_preflight.sh` — Security & readiness report (no changes)

**Why this exists**  
Before we install anything, we want a quick, non-intrusive snapshot that answers:  
- Is SELinux in a good state?  
- Are the ports we intend to use already taken?  
- Are core services like auditd/chrony/journald in place?  
- Are SSH settings sane for production?
- Do `/app` and `/logs` exist and look writable for the primary user?

**What it checks (read-only):**
- **Host facts:** OS, kernel, arch, systemd version.  
- **Filesystem roots:** presence/perms for `/app` and `/logs`, plus a quick capacity snapshot.
- **SELinux:** current mode + presence of `semanage` (helpful if you label custom paths like `/app` and `/logs`).
- **Firewall & ports:** `firewalld` state (if present) and conflicts on intended ports.  
  Default ports: `9090 (Prometheus)`, `9100 (Node Exporter)`, `9091 (Pushgateway)`, `3000 (Grafana)`, `9093 (Alertmanager)`.
- **Core services:** `auditd`, `chronyd`, `journald`.
- **SSH snapshot:** key items from `sshd -T` (root login, password auth, pubkey).
- **Users/Group (signals only):** whether `monitorconfig` or planned service users exist.
- **Kernel toggles:** quick indicators (ASLR, FIPS).

**Run**
```bash
sudo ./security_preflight.sh                               # report only (always exit 0)
sudo ./security_preflight.sh --strict                      # exit 1 if blockers (e.g., a port is in use)
sudo ./security_preflight.sh --ports "9090,9100,9091,3000,9093"
```

**How to read it**  
The report prints `Item | Status | Notes` with: `[OK]`, `[WARN]`, `[BLOCK]`.

**Script**
```bash
#!/bin/bash
# Security Preflight for RHEL 9.x — NO CHANGES, NO INSTALLS
# Usage: sudo ./security_preflight.sh [--ports "9090,9100,9091,3000,9093"] [--strict]

set -euo pipefail
PORTS="9090,9100,9091,3000,9093"
STRICT=0

for arg in "$@"; do
  case "$arg" in
    --ports*)   PORTS="${arg#*=}";;
    --strict)   STRICT=1;;
    *) echo "Unknown arg: $arg"; exit 2;;
  esac
done

ok(){   printf " [OK]    %-22s | %-8s | %s\n" "$1" "$2" "$3"; }
warn(){ printf " [WARN]  %-22s | %-8s | %s\n" "$1" "$2" "$3"; }
block(){ printf " [BLOCK] %-22s | %-8s | %s\n" "$1" "$2" "$3"; BLOCKERS=$((BLOCKERS+1)); }
title(){
  echo
  echo "=== $1 ==="
  echo " Item                     | Status   | Notes"
  echo "--------------------------+----------+-------------------------------------"
}
have(){ command -v "$1" &>/dev/null; }
val(){ [[ -n "${1:-}" ]] && echo "$1" || echo "-"; }

BLOCKERS=0

# ------------------------------------------------------------
title "Host facts"
OS="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-RHEL}")"
KERNEL="$(uname -r 2>/dev/null || true)"
ARCH="$(uname -m 2>/dev/null || true)"
SYSD_VER="$(systemctl --version 2>/dev/null | head -n1 | xargs || true)"
ok "OS"        "$(val "$OS")"        " "
ok "Kernel"    "$(val "$KERNEL")"    " "
ok "Arch"      "$(val "$ARCH")"      "Expect x86_64"
ok "systemd"   "$(val "$SYSD_VER")"  " "

# ------------------------------------------------------------
title "Filesystem layout (/app, /logs)"
for d in /app /logs; do
  if [[ -d "$d" ]]; then
    if [[ -w "$d" ]]; then
      ok "$d" "present" "writable"
    else
      warn "$d" "present" "not writable for current user"
    fi
  else
    warn "$d" "missing" "create before data/log usage"
  fi
done
# Capacity snapshot (if paths exist)
df -h /app /logs 2>/dev/null | sed 's/^/  /'

# ------------------------------------------------------------
title "SELinux"
if have getenforce; then
  MODE="$(getenforce 2>/dev/null || true)"
  case "$MODE" in
    Enforcing) ok "mode" "$MODE" "Policy is enforced";;
    Permissive) warn "mode" "$MODE" "Allowed now, may block later in prod";;
    Disabled) warn "mode" "$MODE" "No confinement — consider enabling";;
    *) warn "mode" "$MODE" "Unknown mode";;
  esac
else
  warn "tools" "missing" "getenforce not found"
fi
have semanage && ok "semanage" "present" "Ready to label custom paths" \
                 || warn "semanage" "missing" "If using /app or /logs, labeling may be needed"

# ------------------------------------------------------------
title "Firewall & Ports"
if have firewall-cmd; then
  systemctl is-active --quiet firewalld && ok "firewalld" "active" "Runtime firewall is on" \
                                       || warn "firewalld" "inactive" "You can manage ports per service"
  ZONE="$(firewall-cmd --get-default-zone 2>/dev/null || echo '-')"
  ok "default zone" "$ZONE" " "
else
  warn "firewalld" "not-installed" "Port exposure unmanaged by firewalld"
fi

title "Port conflicts (intended)"
IFS=',' read -r -a P_ARR <<< "$PORTS"
for p in "${P_ARR[@]}"; do
  if ss -lnt "( sport = :$p )" 2>/dev/null | grep -q ":$p"; then
    WHO="$(ss -lntp "( sport = :$p )" 2>/dev/null | awk 'NR>1{print $6}' | sed 's/,.*//' | head -n1)"
    block "Port $p" "in-use" "By ${WHO:-unknown}"
  else
    ok "Port $p" "free" " "
  fi
done

# ------------------------------------------------------------
title "Core Services"
systemctl is-enabled auditd &>/dev/null && AEN=enabled || AEN=disabled
systemctl is-active  auditd &>/dev/null && AAC=active  || AAC=inactive
[[ "$AAC" = active ]] && ok "auditd" "$AEN/$AAC" "Kernel auditing running" \
                      || warn "auditd" "$AEN/$AAC" "Not critical for stack, but good to have"

have journalctl && ok "journald" "present" "Default logging target" \
                 || warn "journald" "missing" "Unexpected on RHEL"

systemctl is-active --quiet chronyd && ok "chrony" "active" "Time sync ok" \
                                     || warn "chrony" "inactive" "Time drift can affect alerts"

# ------------------------------------------------------------
title "SSH snapshot"
if have sshd; then
  if sshd -T &>/dev/null; then
    PRL=$(sshd -T | awk '$1=="permitrootlogin"{print $2}')
    PWA=$(sshd -T | awk '$1=="passwordauthentication"{print $2}')
    PUB=$(sshd -T | awk '$1=="pubkeyauthentication"{print $2}')
    ok "PermitRootLogin" "$PRL" "Prefer no"
    ok "PasswordAuth"    "$PWA" "Prefer no (keys only)"
    ok "PubkeyAuth"      "$PUB" "Prefer yes"
  else
    warn "sshd -T" "denied" "Run as root for full view"
  fi
else
  warn "sshd" "missing" "Service not found"
fi

# ------------------------------------------------------------
title "Users & Group (monitoring)"
getent group monitorconfig >/dev/null && ok "group monitorconfig" "exists" " " \
                                   || warn "group monitorconfig" "missing" "Will be created by users-layout script"

for u in exporter prometheus grafana pushgateway node_exporter cexporter alertmanager; do
  if id "$u" &>/dev/null; then
    SH=$(getent passwd "$u" | awk -F: '{print $7}')
    ok "user $u" "exists" "shell=$SH"
  else
    warn "user $u" "missing" "Create only what you plan to use"
  fi
done

# ------------------------------------------------------------
title "FIPS & Kernel toggles"
if [[ -r /proc/sys/crypto/fips_enabled ]]; then
  FIPS=$(cat /proc/sys/crypto/fips_enabled)
  [[ "$FIPS" = 1 ]] && ok "FIPS mode" "enabled" "Strict crypto" || ok "FIPS mode" "disabled" "Standard crypto"
fi
ASLR="$(/sbin/sysctl -n kernel.randomize_va_space 2>/dev/null || echo '?')"
ok "ASLR" "$ASLR" "2=full, 1=partial, 0=off"

# ------------------------------------------------------------
echo
if (( BLOCKERS > 0 )); then
  echo "Summary: $BLOCKERS blocker(s) detected."
  [[ $STRICT -eq 1 ]] && exit 1 || exit 0
else
  echo "Summary: no blockers."
  exit 0
fi
```

---

## 2) `bootstrap_monitoring_layout.sh` — Directory layout, ownership, and user lingering

**Why this exists**  
You’ll lose sudo after initial onboarding, but you still need full control. This script ensures:  
- per-service config/data/log directories are **owned by your primary user**,  
- a shared group `monitorconfig` is available for collaboration,  
- **lingering** is enabled so your **user-mode services** start automatically on boot.

**Run**
```bash
chmod +x bootstrap_monitoring_layout.sh
sudo ./bootstrap_monitoring_layout.sh
```

**Expected verification**
```bash
getent group monitorconfig
id $(id -un)
ls -ld /etc/prometheus /app/prometheus /logs/prometheus
ls -ld /etc/alertmanager /app/alertmanager /logs/alertmanager
loginctl show-user $(id -un) | grep Linger    # Linger=yes
```

**Script**
```bash
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
```

---

## Journald quick filters (generic)

On some setups, `journalctl --user` may show nothing even though logs are present. Use these filters against the system journal:

```bash
# Show recent messages from your user
journalctl _UID=$(id -u) --since -5min -n 200 --no-pager

# Tag-based (if you set SyslogIdentifier=… in the unit)
journalctl -t prometheus -f

# Filter by a specific user unit (systemd --user)
journalctl _SYSTEMD_USER_UNIT=prometheus.service -f
```

