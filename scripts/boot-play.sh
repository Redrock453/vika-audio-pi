#!/usr/bin/env bash
# Vika Audio Pi — boot autoplay.
#
# Started by vika-audio.service (ExecStartPost) as user vika, after the MPD
# socket appears. Chooses exactly one source:
#   1. USB flash already mounted and indexed -> resume it;
#   2. USB flash present but the mount is still in flight -> wait briefly;
#   3. otherwise -> local library, restored to the last saved position.
#
# Never fails the service: no media means "quiet and idle", not a restart loop.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/media-lib.sh
. "$SCRIPT_DIR/lib/media-lib.sh"

VIKA_LOG_TAG=vika-audio-boot

vika_load_env
vika_init_paths

mode=play
if [[ $VIKA_BOOT_AUTOPLAY == 0 ]]; then
    mode=paused
fi

if ! vika_mpd_wait "$VIKA_MPD_WAIT_SECONDS"; then
    vika_warn "MPD did not become ready within ${VIKA_MPD_WAIT_SECONDS}s; not autoplaying"
    exit 0
fi

mounted=0
vika_is_mounted && mounted=1

if ((mounted == 0)); then
    # udev/systemd may still be mounting the flash; wait a little so boot does
    # not start the local book and immediately switch away from it.
    deadline=$((SECONDS + VIKA_USB_BOOT_WAIT_SECONDS))
    while ((SECONDS < deadline)); do
        if vika_is_mounted; then
            mounted=1
            break
        fi
        vika_usb_present || break
        sleep 1
    done
fi

if ((mounted == 1)); then
    current=$(vika_current_source || true)
    if [[ $current == usb ]]; then
        vika_log "USB media already active; resuming"
        if [[ $mode == play ]]; then
            vika_mpc_quiet play || true
        else
            vika_mpc_quiet pause || true
        fi
        exit 0
    fi
    vika_log "USB media is mounted at boot; selecting it"
    usb_args=(usb)
    [[ $mode == paused ]] && usb_args+=(--no-play)
    rc=0
    "$SCRIPT_DIR/play-source.sh" "${usb_args[@]}" || rc=$?
    if ((rc == 0)); then
        exit 0
    elif ((rc == 4)); then
        vika_warn "USB media holds no playable audio; falling back to local"
    else
        vika_warn "USB source failed (rc=$rc); falling back to local"
    fi
fi

rc=0
if [[ $mode == paused ]]; then
    "$SCRIPT_DIR/play-source.sh" local --no-play || rc=$?
else
    "$SCRIPT_DIR/play-source.sh" local || rc=$?
fi

if ((rc == 4)); then
    vika_warn "no local audio in $VIKA_MUSIC_DIR; player idle"
    exit 0
elif ((rc != 0)); then
    vika_warn "local source failed (rc=$rc); player idle"
    exit 0
fi

exit 0
