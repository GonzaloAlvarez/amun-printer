#!/bin/bash
# amun-printer/tests/vm-e2e.sh — runs INSIDE the kora VM (amun/test --post)
# after amun core, amun docker and amun printer have converged.
#   1. asserts the host-side outcome of the printer role
#   2. clones cn-printer and runs its ./test (virtual IPP printer + SANE test
#      scanner inside the stack) — the EVIDENCE lines prove raster-only
#      printing and scan-to-download end to end
# CN_PRINTER_REF pins the cn-printer branch/tag (default main).
set -euo pipefail
log()  { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*" >&2; exit 1; }

log "host checks (amun printer outcome)"
systemctl is-active --quiet avahi-daemon            || fail "avahi-daemon not active"
dpkg -s ipp-usb >/dev/null 2>&1                     || fail "ipp-usb not installed"
! dpkg -s cups >/dev/null 2>&1                      || fail "host cups is installed (cupsd must only run in cn-printer)"
grep -qx 'blacklist usblp' /etc/modprobe.d/blacklist-usblp.conf || fail "usblp blacklist missing"
grep -Eq '^\s*interface\s*=\s*all' /etc/ipp-usb/ipp-usb.conf    || fail "ipp-usb interface != all"
grep -qx 'Storage=persistent' /etc/systemd/journald.conf.d/99-amun-printer.conf || fail "journald not persistent"
test -d /srv/scans/inbox                            || fail "/srv/scans tree missing"
test -x /usr/local/sbin/rpi-throttled.sh            || fail "rpi-throttled.sh missing"
if command -v ufw >/dev/null 2>&1; then
  sudo -n ufw status | grep -Eq '^60000/tcp\s+ALLOW IN\s+172\.16\.0\.0/12' || fail "ufw hole for ipp-usb missing"
  sudo -n ufw status | grep -Eq '^9100/tcp\s+ALLOW IN\s+10\.1\.1\.140'     || fail "ufw hole for node-exporter missing"
fi
docker info >/dev/null 2>&1 || fail "docker not usable by $(id -un) (amun docker did not run?)"
log "host checks OK"

command -v git >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq git; }
REF="${CN_PRINTER_REF:-main}"
if [ ! -d "$HOME/cn-printer/.git" ]; then
  log "cloning cn-printer@$REF"
  git clone --depth 1 --branch "$REF" https://github.com/GonzaloAlvarez/cn-printer.git "$HOME/cn-printer"
fi
cd "$HOME/cn-printer"
log "running cn-printer/test --in-vm"
./test --in-vm
log "PASS"
