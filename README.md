# BWLimiter

Production-oriented Linux bandwidth limiter built on `tc` + `ifb`.

BWLimiter gives you a practical control center for port-based shaping, service-safe automation, and schedule-based speed policies.

Persian guide: `README.fa.md`

---

## 1) Overview

Use BWLimiter when you need to:

- limit traffic by port
- control upload and download separately
- manage rules from an interactive numeric menu
- auto-restore policy after reboot
- apply different speed profiles based on time/day

The script is designed for real server operations, including VPN stacks like x-ui/3x-ui/xray.

---

## 2) Feature Matrix

| Domain | What You Get |
|---|---|
| Traffic shaping | HTB classes with `tc`, ingress redirect to `ifb` for download control |
| Rule model | Add/edit/enable/disable/delete/list/apply rules without destructive reset |
| Protocol control | `tcp`, `udp`, or `both` |
| Multi-port support | One rule can target multiple ports |
| Inbound discovery | VPN-aware discovery + 3x-ui DB/config parsing fallback chain |
| Scheduling | Unlimited time windows per rule, day filters, overlap priority |
| Safety | Conflict guard + protected-port policy + safe apply with snapshot rollback |
| Monitoring | Live `tc` monitor, status view, debug report generator |
| Automation | `systemd` service + 1-minute scheduler timer |

---

## 3) Detection Priority (Inbound Ports)

Detection path is intentionally ordered:

1. 3x-ui database (`x-ui.db`) when available
2. xray config files (`config.json`) when available
3. VPN-related listening processes (`xray`, `x-ui`, `sing-box`, `v2ray`)
4. General listening sockets (`ss`)

This helps keep detected ports relevant to VPN workloads first.

---

## 4) Requirements

Required:

- Linux
- root privileges (`sudo`)
- `iproute2` (`tc`, `ip`, `ss`)
- `kmod` (`modprobe`)
- `systemd` (for service/timer automation)

Recommended:

- `sqlite3`
- `jq`

---

## 5) Install

### 5.1 Quick Install (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/B3hnamR/BWLimiter/main/bootstrap.sh | sudo bash
```

What bootstrap does:

1. installs missing dependencies
2. installs/updates `/usr/local/bin/limit-tc-port`
3. installs systemd unit files
4. enables main service and scheduler timer
5. launches interactive menu

### 5.2 Manual Install

```bash
git clone https://github.com/B3hnamR/BWLimiter.git
cd BWLimiter
chmod +x limit-tc-port.sh install.sh
sudo ./install.sh
```

---

## 6) Interactive Menu Map

Start:

```bash
sudo limit-tc-port
```

Main menu:

- `[1]` Rules Studio
- `[2]` Inbound Discovery
- `[3]` Service Ops
- `[4]` Live Monitor
- `[5]` Maintenance Toolkit
- `[6]` Quick Wizard
- `[7]` Apply Active
- `[8]` Time Schedules
- `[0]` Quit

Important submenus:

- `Service Ops`: service install/start/stop + scheduler timer control
- `Maintenance Toolkit`: interface selection, IFB config, debug report, safe apply, conflict checks, snapshot rollback
- `Time Schedules`: create/edit/enable/disable/delete schedule windows

---

## 7) Scheduling Engine

Each schedule window has:

- target `rule_id`
- `days`: `all`, `weekday`, `weekend`, or `mon,tue,...`
- `start_hhmm` / `end_hhmm`
- scheduled `down_kbit`, `up_kbit`, `burst_kb`
- `priority` (higher wins if windows overlap)

Behavior:

- if a schedule is active now, it overrides base rule speed
- if no schedule is active, base rule speed is used
- overnight windows are supported (`23:00` to `06:00`)
- you can define 3, 5, or many windows per rule

---

## 8) CLI Reference

```bash
sudo limit-tc-port --apply
sudo limit-tc-port --safe-apply
sudo limit-tc-port --tick
sudo limit-tc-port --clear
sudo limit-tc-port --status
sudo limit-tc-port --list
sudo limit-tc-port --list-schedules
sudo limit-tc-port --conflict-check
sudo limit-tc-port --list-snapshots
sudo limit-tc-port --rollback-latest
sudo limit-tc-port --rollback-snapshot <snapshot_id>
sudo limit-tc-port --install-service
sudo limit-tc-port --debug-report
sudo limit-tc-port --help
```

Command intent:

- `--apply`: force apply current effective policy
- `--safe-apply`: create snapshot, run guarded apply, auto-rollback if apply fails
- `--tick`: apply only when effective schedule state changes
- `--conflict-check`: validate overlapping rules and protected-port safety before apply
- `--rollback-*`: restore previous policy from snapshots
- `--debug-report`: generate diagnostics in `/tmp`

---

## 9) systemd Operations

Main service:

```bash
sudo systemctl enable --now limit-tc-port.service
sudo systemctl status limit-tc-port.service
```

Scheduler timer:

```bash
sudo systemctl enable --now limit-tc-port-scheduler.timer
sudo systemctl status limit-tc-port-scheduler.timer
```

Execution model:

- service applies policy lifecycle (`--apply`, `--clear`)
- timer runs `--tick` every minute

---

## 10) File Layout

- Config: `/etc/limit-tc-port/config`
- Rules DB: `/etc/limit-tc-port/rules.db`
- Schedules DB: `/etc/limit-tc-port/schedules.db`
- Runtime hash/state: `/run/limit-tc-port/`
- Log: `/var/log/limit-tc-port.log`

---

## 11) First Practical Setup (Example)

1. Open `Rules Studio` and create a rule for your inbound port (for example `8080`).
2. Set base limits (example: down `24576`, up `24576` for about 3 MB/s).
3. Apply active rules.
4. Open `Time Schedules` and add windows such as:
   - weekday 08:00-18:00, lower speed
   - all days 18:00-23:00, medium speed
   - all days 23:00-08:00, higher speed
5. Enable scheduler timer from `Service Ops`.

---

## 12) Troubleshooting

Generate report:

```bash
sudo limit-tc-port --debug-report
```

Inspect report:

```bash
cat /tmp/limit-tc-port-debug-*.log
```

What to verify first:

1. selected interface is correct
2. IFB device is present after apply
3. service and scheduler timer are enabled
4. rules and schedules are enabled
5. detected source matches your environment (`3xui-db`, `xray-config`, etc.)

---

## 13) Known Scope Limits

- Filter path is currently IPv4-focused (`protocol ip` with `u32`).
- Policy is port-based, not strict per-user shaping.

---

## 14) Acknowledgment and Attribution

The idea and general concept behind this project were inspired by the Telegram channel **KillNationChannel**. However, the actual implementation, structure, and source code in this repository were independently written and developed by me.

It should also be noted that **KillNationChannel** already provides a script with similar functionality, and users are welcome to use their version directly if they prefer.

---

Developed by: Behnam (`@b3hnamrjd`)
