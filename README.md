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

# install_prometheus_user.sh — what I did and why

**Goal:** run Prometheus as **my login user** (not system-wide), keep data under `/app/prometheus`, and avoid world‑writable paths.

**What the script does (and why):**
- **Downloads the official build + verifies SHA256** — so the binary is authentic.
- **Installs `prometheus` & `promtool` into `$HOME/bin`** — I can upgrade later without sudo.
- **Uses the layout I prepared earlier**:  
  `/etc/prometheus` (config), `/app/prometheus` (TSDB), `/etc/prometheus/rules.d` (rules).  
  This keeps config/data separate and team-friendly via the `monitorconfig` group.
- **Copies console assets if present** — wires flags only when `consoles/console_libraries` exist; otherwise Prometheus runs fine without them.
- **Creates a user-mode systemd unit** at `~/.config/systemd/user/prometheus.service` — the service is owned/managed by me, not root.
- **Safe defaults**: `UMask=007` (group‑writable; others denied), `retention.time=15d`, `port=9090`.  
  Logs go to **journald** (no file logs); config is validated with `promtool` before start.
- **What it doesn’t do:** no system‑wide install, no firewall changes, no SELinux policy edits (just `restorecon` if available), no world‑writable perms.

## How I run it
> I already ran `security_preflight.sh` and `bootstrap_monitoring_layout.sh`.

```bash
chmod +x install_prometheus_user.sh
sudo ./install_prometheus_user.sh
```

## How I verify it’s healthy
```bash
systemctl --user status prometheus --no-pager -l
journalctl _SYSTEMD_USER_UNIT=prometheus.service -f
curl -sf localhost:9090/-/ready   && echo READY
curl -sf localhost:9090/-/healthy && echo HEALTHY
```

## Quick knobs I can tweak
- Change version/port/retention at install time:
```bash
PROM_VERSION=3.5.0 PORT=9090 RETENTION=30d sudo ./install_prometheus_user.sh
```
- Prefer size-based retention to cap disk usage (edit the unit later and add):
```
--storage.tsdb.retention.size=150GB
```

## If something fails
Grab status and recent logs so I can diagnose quickly:
```bash
systemctl --user status prometheus -l --no-pager
journalctl _SYSTEMD_USER_UNIT=prometheus.service -b -n 200 --no-pager
```

