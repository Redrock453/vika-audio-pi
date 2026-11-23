#!/usr/bin/env bash
# BlueALSA A2DP setup/diagnostic for Vika Audio Pi (HD-610 headphones).
#
# Usage (on the Pi, as vika or root):
#   ./scripts/bt-a2dp-setup.sh              # diagnose only
#   sudo ./scripts/bt-a2dp-setup.sh --apply # apply bluealsa profile override + restart
#
# The classic "a2dp-sink profile connect failed: Protocol not available"
# means BlueALSA did not register the A2DP source profile with BlueZ.
# This script forces --profile=a2dp-source (and a2dp-sink) via a systemd drop-in.

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

# Current ExecStart
log "--- bluealsa ExecStart ---"
systemctl cat bluealsa.service 2>/dev/null | grep -E 'ExecStart|profile' || true

# Connected devices
log "--- bluetoothctl devices ---"
bluetoothctl devices 2>/dev/null || true
bluetoothctl info 2>/dev/null | head -40 || true

# BlueALSA PCMs
if command -v bluealsa-aplay >/dev/null 2>&1; then
    log "--- bluealsa-aplay --list-devices ---"
    bluealsa-aplay --list-devices 2>/dev/null || true
fi

if ((APPLY == 0)); then
    cat <<'EOF'

Next (run as root to apply the usual fix):
  sudo ./scripts/bt-a2dp-setup.sh --apply

Manual equivalent:
  sudo systemctl edit bluealsa.service
  # paste:
  [Service]
  ExecStart=
  ExecStart=/usr/bin/bluealsa -S --profile=a2dp-source --profile=a2dp-sink
  sudo systemctl daemon-reload
  sudo systemctl restart bluetooth.service
  sleep 2
  sudo systemctl restart bluealsa.service

Then pair/trust/connect the HD-610 and test:
  bluealsa-aplay --list-devices
  aplay -D bluealsa:DEV=XX:XX:XX:XX:XX:XX,PROFILE=a2dp /usr/share/sounds/alsa/Front_Center.wav
EOF
    exit 0
fi

log "Applying BlueALSA A2DP profile override (a2dp-source + a2dp-sink)"

if ! systemctl cat bluealsa.service >/dev/null 2>&1; then
    log "bluealsa.service not found; creating a minimal unit"
    cat > /etc/systemd/system/bluealsa.service <<'EOF'
[Unit]
Description=BlueALSA daemon
After=bluetooth.service
Requires=bluetooth.service

[Service]
ExecStart=/usr/bin/bluealsa -S --profile=a2dp-source --profile=a2dp-sink
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable bluealsa.service
else
    DROPIN_DIR=/etc/systemd/system/bluealsa.service.d
    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN_DIR/vika-a2dp.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/bluealsa -S --profile=a2dp-source --profile=a2dp-sink
EOF
    systemctl daemon-reload
fi

# Restart BlueZ first so BlueALSA re-registers its A2DP profiles with a running
# bluetoothd. Restarting in the opposite order drops the registration and brings
# back "a2dp-sink profile connect failed: Protocol not available".
systemctl restart bluetooth.service
sleep 2
systemctl restart bluealsa.service

log "Restarted. Current status:"
systemctl status bluealsa.service --no-pager -n 8 || true

log "Done. Now pair the headphones if needed and check with:"
log "  bluealsa-aplay --list-devices"
log "  aplay -D bluealsa:DEV=<MAC>,PROFILE=a2dp /usr/share/sounds/alsa/Front_Center.wav"
