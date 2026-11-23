#!/usr/bin/env bash
# BlueALSA A2DP diagnostic/setup for Vika Audio Pi (HD-610 headphones).
#
# Usage (on the Pi, as vika or root):
#   ./scripts/bt-a2dp-setup.sh              # diagnose only
#   sudo ./scripts/bt-a2dp-setup.sh --apply # force profiles via systemd drop-in
#
# What "a2dp-sink profile connect failed: Protocol not available" means:
# at connection time nobody registered A2DP endpoints with BlueZ. In Debian
# Trixie the shipped bluealsa.service already starts
#     /usr/bin/bluealsa -S -p a2dp-source -p a2dp-sink
# (verified in the Debian packaging of bluez-alsa 4.3.1-3), so the usual fix
# is NOT a drop-in — it is: make bluealsa active, restart it after any
# bluetoothd restart, then remove and re-pair the headset. See
# docs/BLUETOOTH.md for the full decision tree. The --apply drop-in below
# only forces the same arguments explicitly; use it if your unit's ExecStart
# genuinely lacks the -p arguments.

set -Eeuo pipefail

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
    APPLY=1
    if ((EUID != 0)); then
        echo "ERROR: --apply requires root (sudo)" >&2
        exit 1
    fi
fi

log() { printf '[bt] %s\n' "$*"; }
warn() { printf '[bt] WARN: %s\n' "$*" >&2; }

log "=== BlueALSA / A2DP diagnostic ==="

# rfkill first: a soft-blocked adapter makes every later check meaningless.
if command -v rfkill >/dev/null 2>&1; then
    log "--- rfkill ---"
    rfkill list bluetooth 2>/dev/null || rfkill list 2>/dev/null || true
fi

# Packages
for p in bluez bluez-alsa-utils libasound2-plugin-bluez; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
        log "package ok: $p"
    else
        warn "missing package: $p"
    fi
done

# Services
log "--- services ---"
systemctl is-active bluetooth.service 2>/dev/null || true
systemctl is-active bluealsa.service 2>/dev/null || true
systemctl status bluealsa.service --no-pager -n 5 2>/dev/null || true

# Current ExecStart: does it really carry the A2DP profiles?
log "--- bluealsa ExecStart (must contain -p a2dp-source -p a2dp-sink) ---"
exec_line=$(systemctl cat bluealsa.service 2>/dev/null | grep -E '^ExecStart=' || true)
if [[ $exec_line == *a2dp-source* && $exec_line == *a2dp-sink* ]]; then
    log "profiles are enabled in the unit: $exec_line"
else
    warn "ExecStart without A2DP profiles: ${exec_line:-<not found>}"
    warn "run with sudo --apply, or edit /etc/default/bluez-alsa (OPTIONS=...)"
fi

# Journal hints for the last boot
log "--- journal (bluealsa) ---"
journalctl -b -u bluealsa.service --no-pager 2>/dev/null | tail -10 || true
log "--- journal (bluetooth, A2DP/SEP lines) ---"
journalctl -b -u bluetooth.service --no-pager 2>/dev/null | grep -i -E 'a2dp|sep|endpoint' | tail -10 || true

# Connected devices
log "--- bluetoothctl devices ---"
bluetoothctl devices 2>/dev/null || true
bluetoothctl info 2>/dev/null | head -40 || true

# BlueALSA PCMs
if command -v bluealsa-aplay >/dev/null 2>&1; then
    log "--- bluealsa-aplay --list-pcms ---"
    bluealsa-aplay --list-pcms 2>/dev/null || true
    log "--- bluealsa-aplay --list-devices ---"
    bluealsa-aplay --list-devices 2>/dev/null || true
fi

if ((APPLY == 0)); then
    cat <<'EOF'

Most likely fix order (see docs/BLUETOOTH.md):
  1. make sure bluealsa.service and bluetooth.service are active;
  2. if bluetoothd was restarted, restart bluealsa too (re-registers SEPs);
  3. bluetoothctl remove <MAC of HD-610>, then pair/trust/connect again;
  4. check UUIDs 0000110b (AudioSink) in `bluetoothctl info <MAC>`;
  5. bluealsa-aplay --list-pcms and an aplay -D bluealsa:... test BEFORE MPD.

Only if the ExecStart above really lacks the -p arguments:
  sudo ./scripts/bt-a2dp-setup.sh --apply
EOF
    exit 0
fi

log "Applying bluealsa.service drop-in (a2dp-source + a2dp-sink)"

DROPIN_DIR=/etc/systemd/system/bluealsa.service.d
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_DIR/vika-a2dp.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/bluealsa -S --profile=a2dp-source --profile=a2dp-sink
EOF

systemctl daemon-reload
systemctl restart bluealsa.service

log "Restarted. Current status:"
systemctl status bluealsa.service --no-pager -n 8 || true

log "Now re-pair the headphones (remove first!) and check with:"
log "  bluealsa-aplay --list-pcms"
log "  aplay -D bluealsa:DEV=<MAC>,PROFILE=a2dp /usr/share/sounds/alsa/Front_Center.wav"
