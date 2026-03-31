# BWLimiter

Linux port-based bandwidth manager powered by `tc` + `ifb`.

BWLimiter helps you control upload/download speed per port, manage rules from an interactive menu, and keep shaping rules persistent after reboot with `systemd`.

## Documentation

- Persian guide: `README.fa.md`

## Features

- Port-based bandwidth limiting
- Independent Upload and Download control
- Protocol support: `tcp`, `udp`, or `both`
- Multi-port rules in one entry
- Auto-detection of listening inbound ports
- Rule lifecycle management: create, edit, enable/disable, delete
- Speed changes without deleting existing rules
- Persistent restore after reboot via `systemd`
- Live `tc` monitor
- Quick wizard for fast setup

## How It Works

- Upload shaping is applied on the selected network interface using HTB classes and `sport` filters.
- Download shaping is applied by redirecting ingress traffic to an `ifb` device, then applying HTB classes with `dport` filters.
- Rules are stored in `/etc/limit-tc-port/rules.db` and loaded on apply/start.

## Requirements

- Linux host
- Root access (`sudo`)
- `iproute2` (`tc`, `ip`, `ss`)
- `kmod` (`modprobe`)
- `systemd` (optional, for auto-apply at boot)

## Quick Install (curl)

```bash
curl -fsSL https://raw.githubusercontent.com/B3hnamR/BWLimiter/main/bootstrap.sh | sudo bash
```

What this does:

- Detects package manager and installs missing dependencies
- Downloads/updates `limit-tc-port` in `/usr/local/bin/limit-tc-port`
- Installs/enables systemd service when available
- Launches the interactive menu

## Manual Install

```bash
git clone https://github.com/B3hnamR/BWLimiter.git
cd BWLimiter
chmod +x limit-tc-port.sh install.sh
sudo ./install.sh
```

## Usage

Interactive mode:

```bash
sudo limit-tc-port
```

Main menu shortcuts:

- `[1]` Rules Studio
- `[2]` Inbound Discovery
- `[3]` Service Ops
- `[4]` Live Monitor
- `[5]` Maintenance Toolkit
- `[6]` Quick Wizard
- `[7]` Apply Active
- `[0]` Quit

CLI commands:

```bash
sudo limit-tc-port --apply
sudo limit-tc-port --clear
sudo limit-tc-port --status
sudo limit-tc-port --list
sudo limit-tc-port --install-service
sudo limit-tc-port --help
```

## Service Management

```bash
sudo systemctl enable --now limit-tc-port.service
sudo systemctl status limit-tc-port.service
```

The service executes:

- Start: `limit-tc-port --apply`
- Stop: `limit-tc-port --clear`

## Storage Paths

- Config: `/etc/limit-tc-port/config`
- Rules DB: `/etc/limit-tc-port/rules.db`
- Log: `/var/log/limit-tc-port.log`

## Production Notes

- Set the correct NIC in Maintenance (`Change interface`).
- Tune `LINK_CEIL` close to real line capacity.
- Keep rules focused and explicit (avoid too many broad multi-port rules).
- Verify with monitor/status after every major change.

## Current Limitations

- Port filters are currently implemented for IPv4 (`protocol ip` with `u32`).
- If you need strict per-user VPN limits, this project is port-based by design. Users sharing one inbound port also share that port limit.

## Author

Developed by: Behnam (`@b3hnamrjd`)
