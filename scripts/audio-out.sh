#!/usr/bin/env bash
# Vika Audio Pi — switch MPD output between analog 3.5 mm and Bluetooth (BlueALSA).
#
# Usage:
#   ./scripts/audio-out.sh status    # show outputs + playback status (default)
#   ./scripts/audio-out.sh analog    # analog onboard jack
#   ./scripts/audio-out.sh bt        # Bluetooth headset via BlueALSA
#
# Uses the local MPD UNIX socket; no root and no network required.
set -euo pipefail
export MPD_HOST="${MPD_HOST:-/run/vika-audio/mpd.sock}"
ANALOG="Analog 3.5mm (plughw:0,0)"
BT="Bluetooth (BlueALSA)"

case "${1:-status}" in
    analog) mpc enable "$ANALOG"; mpc disable "$BT" ;;
    bt)     mpc enable "$BT";     mpc disable "$ANALOG" ;;
    status | "") mpc outputs; mpc status ;;
    *) printf 'usage: %s analog|bt|status\n' "$0" >&2; exit 2 ;;
esac
