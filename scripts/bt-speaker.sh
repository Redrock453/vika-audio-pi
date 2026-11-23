#!/bin/sh
# Vika Audio Pi as a Bluetooth speaker.
#
# A phone or PC running AIMP (or any player) sends A2DP audio to the Pi; the
# vika-bt-speaker.service runs bluealsa-aplay, which forwards that stream to
# the 3.5 mm jack. The Pi keeps working as an MPD player at the same time:
# the bcm2835 headphone PCM accepts several simultaneous opens, so no dmix
# configuration is needed.
#
# The mode is opt-in and survives reboots only while enabled:
#
#   sudo ./scripts/bt-speaker.sh on       # advertise + route A2DP to analog
#   sudo ./scripts/bt-speaker.sh off      # stop and stop advertising
#   ./scripts/bt-speaker.sh status        # no root needed
#
# Requires the bluez + bluez-alsa-utils packages (installed by install.sh
# with --bluetooth).
set -eu

UNIT=vika-bt-speaker.service
MPD_HOST=${MPD_HOST:-/run/vika-audio/mpd.sock}
BLUETOOTHCTL=${BLUETOOTHCTL:-bluetoothctl}

log() {
    printf 'bt-speaker: %s\n' "$*"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "this action needs root: sudo $0 $*"
        exit 1
    fi
}

advertise_on() {
    # bluetoothd may still be starting when the unit is pulled in at boot.
    n=0
    while [ "$n" -lt 15 ]; do
        if "$BLUETOOTHCTL" show 2>/dev/null | grep -q 'Powered: yes'; then
            break
        fi
        n=$((n + 1))
        sleep 1
    done
    timeout 10 "$BLUETOOTHCTL" power on >/dev/null 2>&1 || true
    timeout 10 "$BLUETOOTHCTL" discoverable on >/dev/null 2>&1 \
        || log "could not enable discoverable mode"
    timeout 10 "$BLUETOOTHCTL" pairable on >/dev/null 2>&1 \
        || log "could not enable pairable mode"
}

advertise_off() {
    timeout 10 "$BLUETOOTHCTL" discoverable off >/dev/null 2>&1 || true
    timeout 10 "$BLUETOOTHCTL" pairable off >/dev/null 2>&1 || true
}

case "${1:-}" in
    advertise)
        # Internal: ExecStartPre of vika-bt-speaker.service.
        advertise_on
        ;;
    on)
        require_root "$@"
        # Avoid two players on one jack: pause local MPD playback. The queue
        # and position are kept, so `mpc play` resumes where it stopped.
        MPD_HOST=$MPD_HOST mpc pause >/dev/null 2>&1 || true
        systemctl enable --now "$UNIT"
        log "speaker mode on; connect a phone/PC to '$(hostname)' and play"
        ;;
    off)
        require_root "$@"
        systemctl disable --now "$UNIT"
        advertise_off
        log "speaker mode off"
        ;;
    status)
        state=$(systemctl is-active "$UNIT" 2>/dev/null || true)
        printf 'unit: %s (%s)\n' "$UNIT" "${state:-unknown}"
        if command -v "$BLUETOOTHCTL" >/dev/null 2>&1; then
            "$BLUETOOTHCTL" show 2>/dev/null \
                | grep -E '^\s*(Name|Discoverable|Pairable):' || true
        fi
        if command -v bluealsa-aplay >/dev/null 2>&1; then
            printf 'incoming A2DP streams:\n'
            bluealsa-aplay --list-pcms 2>/dev/null | grep -B1 -A1 'capture' \
                || printf '  none (no phone/PC connected yet)\n'
        fi
        ;;
    *)
        printf 'usage: %s {on|off|status}\n' "$0" >&2
        exit 2
        ;;
esac
