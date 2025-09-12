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
