# Amun Printer

**amun-printer** is a plugin for [amun](https://github.com/GonzaloAlvarez/amun) that prepares the `printer.lan` Raspberry Pi — the USB print/scan server for the Brother MFC-L2750DW — at the **host** level. Everything a user touches (CUPS, the scanservjs and swis web UIs, exporters, log shipping) runs in Docker from the [cn-printer](https://github.com/GonzaloAlvarez/cn-printer) stack; this role only owns what cannot live in a container.

Why a host role at all: the printer is reached over IPP-over-USB. `ipp-usb` must own the USB interface (udev-started, kernel `usblp` blacklisted) and expose IPP + eSCL on `:60000`, so one daemon serves both printing and scanning. The 2026 incidents behind the other tasks: CUPS on raw `usb://` fought ipp-usb for the device (queue stuck, scanner dead), and the box rebooted silently for months under power dips without a persistent journal to prove it.

---

## Usage

```bash
bash <(curl -fsSL https://go.gn.al/amun)   # amun core: sudo, trust, ufw, sshd
amun docker                                # engine + resiliency boot units
amun printer                               # this plugin (reboots once for the memory cgroup)
```

Or from a control host:

```bash
cd ~/dev/amun && ./deploy <host> -P printer -u gonzalo -i ~/.ssh/gonzalo_main_private_key.pem
```

Idempotent on re-run. The only reboot path is the memory-cgroup `cmdline.txt` edit (first run on a Pi); it is scheduled with `shutdown -r +1`.

## What it does

1. Installs `ipp-usb avahi-daemon avahi-utils sane-utils sane-airscan cups-ipp-utils curl` with recommends off, and **removes** `cups`, `cups-daemon`, `cups-browsed`, `samba`, `nfs-kernel-server`, `netatalk`, `dnsmasq`, `hostapd` — the host must not run a second cupsd (cn-printer owns `:631`) and the old plane.lan NAS/AP daemons stay gone.
2. Blacklists `usblp` (legacy raw printer driver; it claims the interface ipp-usb needs).
3. Writes `/etc/ipp-usb/ipp-usb.conf`: `interface = all` (the compose stack reaches it on the bridge gateway, loopback is per-netns), `dns-sd = disable` (static URLs everywhere; the LAN only discovers the CUPS share), ports from `60000`. Re-triggers USB add events so an attached printer starts ipp-usb immediately. The unit is udev-driven and has no `[Install]` — it is never `enable`d.
4. Enables the host `avahi-daemon` (cn-printer's cupsd publishes AirPrint through its D-Bus socket).
5. Persistent, capped journald (`/etc/systemd/journald.conf.d/99-amun-printer.conf`, `SystemMaxUse=200M`) and `/var/log/journal`.
6. Pi only: BCM2835 hardware watchdog (`dtparam=watchdog=on`, `RuntimeWatchdogSec=14s` via a `system.conf.d` drop-in) so a hang reboots instead of waiting weeks for a power cycle.
7. Pi only: memory cgroup (`cgroup_memory=1 cgroup_enable=memory` appended to `/boot/firmware/cmdline.txt`, backup in `/root/cmdline.txt.bak`), so compose `mem_limit` works (Stirling-PDF).
8. `/usr/local/sbin/rpi-throttled.sh` + a per-minute `/etc/cron.d/rpi-throttled` (Pi only) exporting `vcgencmd get_throttled` as node_exporter textfile metrics (`rpi_undervoltage_now`, `rpi_undervoltage_occurred`, `rpi_throttled_*`, `rpi_soc_temp_celsius`, `rpi_core_volts`) into `/var/lib/node_exporter/textfile_collector/rpi.prom`. kaiser alerts on them.
9. `/srv/scans/{swis,inbox,processed}` owned by the invoking user, mode `2775` — the shared tree for scanservjs, swis, and later Samba and Stirling-PDF.
10. ufw (when present): `9100,9329/tcp` from kaiser `10.1.1.140` (node-exporter-lan, cups-exporter), `60000/tcp` from `172.16.0.0/12` (compose bridges → ipp-usb), `80,443/tcp` from anywhere (cn-printer's host-network `traefik-lan` serving `https://scan.print.lan`; step-ca validates HTTP-01 from pki). Nothing else — the stack's other LAN ports are Docker-published and bypass ufw.

## Variables

| Var | Default | What |
|---|---|---|
| `printer_user` | `ansible_facts['user_id']` | Owner of `/srv/scans`. Never hardcoded: kora VMs log in as `admin`/`kora`. |
| `printer_scans_dir` / `printer_scans_subdirs` / `printer_scans_mode` | `/srv/scans` / `[swis, inbox, processed]` / `2775` | Shared scan tree. |
| `printer_ippusb_interface` / `printer_ippusb_dnssd` / `printer_ippusb_port` | `all` / `disable` / `60000` | ipp-usb listener. |
| `printer_docker_cidr` | `172.16.0.0/12` | Allowed source for `:60000` (bridge subnets move across reboots). |
| `printer_blacklist_usblp` | `true` | `/etc/modprobe.d/blacklist-usblp.conf`. |
| `printer_monitor_from` / `printer_exporter_ports` | `[10.1.1.140]` / `[9100, 9329]` | kaiser → exporter holes. |
| `printer_web_ports` | `[80, 443]` | holes for the stack's host-network Traefik (`scan.print.lan`). |
| `printer_textfile_dir` / `printer_throttle_textfile` | `/var/lib/node_exporter/textfile_collector` / `true` | Throttle metrics. |
| `printer_journal_persistent` / `printer_journal_max_use` | `true` / `200M` | journald. |
| `printer_watchdog` / `printer_watchdog_sec` | `true` / `14s` | Hardware watchdog (Pi only; bcm2835 max 15 s). |
| `printer_memory_cgroup` / `printer_cmdline_params` | `true` / `[cgroup_memory=1, cgroup_enable=memory]` | cmdline.txt edit + one reboot (Pi only). |
| `printer_packages` / `printer_legacy_packages_absent` | see defaults | Installed / purged package sets. |

## Notes & gotchas

- **No `usb://` anywhere.** ipp-usb takes the USB interface; a classic CUPS `usb://` queue would hang on "Waiting for printer to become available" and the scanner would vanish. cn-printer's queue is `ipp://<bridge-gw>:60000/ipp/print` with a raster-only PPD.
- **`:60000` is deliberately not reachable from the LAN** — ufw only admits the compose bridge range. The printer's own web UI is at `http://127.0.0.1:60000/` on the host (ssh tunnel if needed).
- **Scanning while printing** both go through ipp-usb; do not run `lpinfo -v`/`sane-find-scanner` style raw USB probes on the host.
- **Pi OS trixie journald is volatile by default** — this role is what makes `journalctl --list-boots` useful after a crash.
- **Under-voltage history** of plane.lan (12+1+3 events across boots, two abrupt deaths after CPU bursts, one 3.5-week outage) is why the watchdog, the persistent journal and `rpi.prom` exist. The hardware fix is a 5.1 V/3 A supply and a powered hub for the SSD; `rpi_undervoltage_occurred` on kaiser tells you whether it worked.
- Molecule cannot see the Pi-only branches (no `/boot/firmware`, no `vcgencmd`); they are verified on rpid11.lan and on the target with `./verify`.

## Supported Platforms

| Platform | Method |
|---|---|
| Raspberry Pi OS Lite 64-bit, trixie (target) | `apt`, Pi-only branches active |
| Debian 12 / 13 (VMs, containers) | `apt`, Pi-only branches skipped |

## Testing — verification is the deliverable

See `homelab/CLAUDE.md` "Provisioning verification" (four layers; `rpid11.lan` is the only real testbed).

### Layer 1 — `./molecule` (Docker, ~3 min)

```bash
./molecule test                            # Debian 12 systemd container, idempotence included
./molecule converge && ./molecule verify   # iterate
```

Success = `PLAY RECAP failed=0`, idempotence `changed=0`, `verify.yml` green (packages, no host cups, usblp blacklist, ipp-usb.conf, persistent journal, `/srv/scans` modes, throttle script, Pi-only artifacts absent, ufw holes).

### Layer 2 — `./test` (kora VM, ~15 min)

```bash
KORA_BIN=~/dev/kora/kora AMUN_CORE=~/dev/amun ./test debian          # bookworm arm64 (local tart)
KORA_BIN=~/dev/kora/kora AMUN_CORE=~/dev/amun ./test debian --cloud --yes   # trixie amd64 on the kvm devbox (billable)
```

The wrapper stages amun core + amun-docker + this plugin and converges `amun`, `amun docker`, `amun printer`; then `amun/test --post` runs `tests/vm-e2e.sh` inside the VM, which asserts the host outcome and clones **cn-printer** (GitHub `main`, `CN_PRINTER_REF` to pin) to run its `./test --in-vm`: a virtual IPP printer (`ippeveprinter`) and the SANE `test` scanner stand in for the Brother. Evidence to quote in commits: the `EVIDENCE:` lines (`print → … PWG raster`, `scan (PNG) …`, `scan (PDF …) …`) and `[e2e] PASS`. `DEBUG=1` leaves a shell in the VM; `kora tun 8080 8080` opens scanservjs on the Mac.

### Layer 3 — `rpid11.lan`

```bash
ssh rpid11.lan amun docker && ssh rpid11.lan amun printer
./verify --host rpid11.lan        # ipp-usb/IPP/eSCL checks SKIP (no Brother), Pi-only checks PASS
```

### Layer 4 — `./verify`

```bash
./verify --host printer.lan       # after cutover: all PASS, no SKIP
```

Pure shell PASS/FAIL/SKIP list: packages (+ host CUPS and legacy daemons ABSENT), usblp, ipp-usb config and liveness (IPP Get-Printer-Attributes + eSCL capabilities when the Brother is attached), journald, watchdog, memory cgroup, `rpi.prom` freshness, `/srv/scans`, ufw holes, legacy units.

## License

GNU GENERAL PUBLIC LICENSE
Version 3, 29 June 2007

Copyright (c) 2026 Gonzalo Alvarez
