#!/usr/bin/env bash
# Vika Audio Pi — build a playlist and make it the active MPD queue.
#
#   play-source.sh local [--no-play]
#   play-source.sh usb   [--no-play]
#
# Run as the MPD user (vika). Never needs root: the USB filesystem is mounted
# read-only by usb-media.sh beforehand.
#
# Behaviour:
#   * remembers the position of whatever was playing (local or USB);
#   * rebuilds the playlist in deterministic byte order;
#   * ignores non-audio / unsafe names;
#   * empty source -> exit 4 without disturbing the current queue;
#   * restores the saved position paused-then-seeked, then plays.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/media-lib.sh
. "$SCRIPT_DIR/lib/media-lib.sh"

VIKA_LOG_TAG=vika-audio-play

vika_load_env
vika_init_paths

source_name=""
mode=play

while (($#)); do
    case $1 in
        local | usb)
            if [[ -n $source_name ]]; then
                vika_err "only one source may be given"
                exit 2
            fi
            source_name=$1
            ;;
        --no-play)
            mode=paused
            ;;
        -h | --help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            vika_err "unknown argument: $1"
            exit 2
            ;;
    esac
    shift
done

if [[ -z $source_name ]]; then
    vika_err "usage: play-source.sh <local|usb> [--no-play]"
    exit 2
fi

if ! mkdir -p -- "$VIKA_PLAYLIST_DIR" "$VIKA_STATE_DIR" 2>/dev/null; then
    vika_err "cannot create $VIKA_PLAYLIST_DIR or $VIKA_STATE_DIR (run as $VIKA_USER)"
    exit 1
fi

# Serialise source switches between boot-play, the udev service and manual
# runs; a second caller waits briefly instead of clearing the queue underneath
# the first one.
lock_file="$VIKA_STATE_DIR/play.lock"
exec 9>>"$lock_file" || true
if ! flock -w 30 9; then
    vika_warn "could not take $lock_file within 30s; continuing"
fi

# The USB service can start before MPD finished booting (coldplug); wait for
# the socket instead of failing the switch and leaving the marker behind.
if ! vika_mpd_wait "$VIKA_MPD_WAIT_SECONDS"; then
    vika_err "MPD is not reachable at $VIKA_MPD_HOST; not switching source"
    exit 1
fi

playlist=$(vika_playlist_file "$source_name")
vika_build_playlist "$source_name" "$playlist" || exit 1

tracks=${VIKA_PLAYLIST_TRACKS:-0}
if ((tracks == 0)); then
    vika_warn "no audio files for source '$source_name'; keeping the current queue"
    exit 4
fi

# Save the position of the queue that is about to be replaced.
current_source=$(vika_current_source || true)
if [[ -n $current_source ]]; then
    vika_save_resume "$current_source" || vika_warn "could not save $current_source position"
fi

# Make new files visible to MPD before loading the playlist.
if [[ $source_name == usb ]]; then
    vika_update_db "$(vika_mount_prefix)"
else
    vika_update_db ""
fi

if ! vika_mpc_quiet clear; then
    vika_err "mpc clear failed (is MPD running at $VIKA_MPD_HOST?)"
    exit 1
fi
if ! vika_mpc_quiet load "$source_name"; then
    vika_err "mpc load '$source_name' failed"
    exit 1
fi

if ! vika_restore_source "$source_name" "$mode"; then
    vika_err "could not start playback from '$source_name'"
    exit 1
fi

vika_set_last_source "$source_name"
vika_log "active source: $source_name ($tracks tracks, mode=$mode)"
exit 0
