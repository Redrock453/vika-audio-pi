#!/usr/bin/env bash
# Vika Audio Pi — ordinary USB flash handling.
#
#   usb-media.sh reconcile [--dry-run]       # idempotent: mount/unmount as needed
#   usb-media.sh attach [--device DEV] [--dry-run]
#   usb-media.sh detach [--dry-run]
#   usb-media.sh status
#
# Runs as root (udev/systemd or timer). The only privileged actions are mount
# and umount. Playback switching is delegated to play-source.sh, which runs as
# the unprivileged service user (vika) through runuser.
#
# Safety invariants:
#   * the medium is mounted READ-ONLY (-o ro) and verified to be ro afterwards;
#   * the filesystem carrying / is never selected (also covers USB boot);
#   * ambiguity is refused, not guessed;
#   * no files are written, moved, renamed or deleted on the medium;
#   * no fsck, no formatting, no fstab edits, no autofs.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/media-lib.sh
. "$SCRIPT_DIR/lib/media-lib.sh"

VIKA_LOG_TAG=vika-audio-usb

vika_load_env
vika_init_paths

DRY_RUN=${VIKA_DRY_RUN:-0}
ACTION=""
DEVICE=""
MARKER="$VIKA_STATE_DIR/usb.active"

vika_run() {
    if ((DRY_RUN)); then
        printf 'DRY-RUN:'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

die() {
    vika_err "$*"
    exit 1
}

usage() {
    sed -n '2,15p' "$0"
    exit "${1:-0}"
}

while (($#)); do
    case $1 in
        reconcile | attach | detach | status)
            [[ -z $ACTION ]] || die "only one action may be given"
            ACTION=$1
            ;;
        --device)
            shift
            [[ $# -gt 0 ]] || die "--device needs a path"
            DEVICE=$1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h | --help)
            usage 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

[[ -n $ACTION ]] || usage 2

if ((DRY_RUN == 0)) && [[ $ACTION != status && $EUID -ne 0 ]]; then
    die "must run as root (or pass --dry-run); the calling user lacks passwordless sudo by design"
fi

if ! prefix=$(vika_mount_prefix); then
    die "VIKA_MOUNT_POINT=$VIKA_MOUNT_POINT is not inside VIKA_MUSIC_DIR=$VIKA_MUSIC_DIR"
fi

ensure_dirs() {
    vika_run install -d -o "$VIKA_USER" -g "$VIKA_USER" -m 0750 -- "$VIKA_MOUNT_POINT"
    vika_run install -d -o "$VIKA_USER" -g "$VIKA_USER" -m 0750 -- "$VIKA_STATE_DIR"
    vika_run install -d -o "$VIKA_USER" -g "$VIKA_USER" -m 0750 -- "$VIKA_PLAYLIST_DIR"
}

write_marker() {
    local dev=$1 fstype=$2 tmp="$MARKER.tmp.$$"
    if ((DRY_RUN)); then
        printf 'DRY-RUN: write marker %s -> %s (%s)\n' "$dev" "$MARKER" "$fstype"
        return 0
    fi
    (umask 0022; printf '%s\n%s\n' "$dev" "$fstype" > "$tmp") || die "cannot write $tmp"
    mv -f -- "$tmp" "$MARKER"
}

clear_marker() {
    [[ -e $MARKER ]] || return 0
    vika_run rm -f -- "$MARKER"
}

# Switch the MPD queue as user vika. rc=4 means "no playable audio"; that is
# not an error and must not cause a mount/retry loop.
switch_playback() {
    local source=$1 rc=0 env_file=${VIKA_ENV_FILE:-/etc/vika-audio/vika-audio.env}
    if ((DRY_RUN)); then
        printf 'DRY-RUN: runuser -u %s -- env VIKA_ENV_FILE=%s %s/play-source.sh %s\n' \
            "$VIKA_USER" "$env_file" "$SCRIPT_DIR" "$source"
        return 0
    fi
    runuser -u "$VIKA_USER" -- env VIKA_ENV_FILE="$env_file" \
        "$SCRIPT_DIR/play-source.sh" "$source" || rc=$?
    case $rc in
        0) return 0 ;;
        4) vika_warn "source '$source' is empty; playback left as it was"; return 0 ;;
        *) vika_warn "play-source.sh $source failed (rc=$rc)"; return "$rc" ;;
    esac
}

verify_read_only() {
    local opts
    opts=$(vika_mount_options || true)
    if [[ -z $opts ]]; then
        die "cannot read mount options for $VIKA_MOUNT_POINT"
    fi
    if [[ ",$opts," != *,ro,* ]]; then
        vika_run umount "$VIKA_MOUNT_POINT" || true
        die "refusing: $VIKA_MOUNT_POINT is not mounted read-only ($opts)"
    fi
}

verify_readable_by_user() {
    if ((DRY_RUN)); then
        return 0
    fi
    if ! runuser -u "$VIKA_USER" -- test -r "$VIKA_MOUNT_POINT"; then
        vika_run umount "$VIKA_MOUNT_POINT" || true
        die "$VIKA_MOUNT_POINT is not readable by $VIKA_USER (use FAT32/exFAT, or fix file permissions)"
    fi
}

unmount_media() {
    local mp=$VIKA_MOUNT_POINT i
    if ! vika_is_mounted; then
        return 0
    fi
    if ((DRY_RUN)); then
        printf 'DRY-RUN: umount %s\n' "$mp"
        return 0
    fi
    if umount "$mp" 2>/dev/null; then
        return 0
    fi
    for i in 1 2 3 4 5; do
        sleep 0.5
        if umount "$mp" 2>/dev/null; then
            return 0
        fi
    done
    vika_warn "$mp is busy; lazy unmount"
    umount -l "$mp" || vika_err "lazy unmount of $mp failed"
}

do_attach() {
    local requested=${1:-}
    local source="" entry="" dev="" fstype="" opts=""

    ensure_dirs

    if vika_is_mounted; then
        source=$(vika_mount_source)
        if [[ -n $requested && $requested != "$source" ]]; then
            die "$VIKA_MOUNT_POINT is already mounted from $source, not $requested"
        fi
        dev=$source
        fstype=$(vika_blkid_fstype "$dev" || true)
        vika_log "$VIKA_MOUNT_POINT already mounted from $dev; adopting it"
    else
        if ! vika_select_usb "$requested" >/dev/null; then
            die "${VIKA_USB_REASON:-no usable USB media}"
        fi
        entry=$VIKA_USB_SELECTION
        dev=${entry%%|*}
        fstype=${entry#*|}
        [[ -n $fstype && $fstype != "$entry" ]] || fstype=$(vika_blkid_fstype "$dev" || true)
        [[ -n $fstype ]] || fstype=unknown
        opts=$(vika_mount_opts "$fstype")
        vika_log "mounting $dev ($fstype) read-only at $VIKA_MOUNT_POINT"
        vika_run mount -o "$opts" -- "$dev" "$VIKA_MOUNT_POINT" || die "mount of $dev failed"
        if ((DRY_RUN == 0)) && ! vika_is_mounted; then
            die "mount of $dev reported success but $VIKA_MOUNT_POINT is not a mount point"
        fi
    fi

    if ((DRY_RUN == 0)); then
        verify_read_only
        verify_readable_by_user
    fi

    write_marker "$dev" "$fstype"
    if ! switch_playback usb; then
        # Let the timer/udev retry the playback switch; the medium stays
        # mounted read-only either way.
        clear_marker
        vika_warn "USB playlist switch failed; media stays mounted, retry on next reconcile"
    fi
    return 0
}

do_detach() {
    local last=""
    ensure_dirs
    if [[ -r "$VIKA_STATE_DIR/last-source" ]]; then
        last=$(<"$VIKA_STATE_DIR/last-source")
    fi

    # Stop touching the medium before unmounting: switch back to the local
    # library (and remember the USB position on the way out).
    if [[ $last == usb || -e $MARKER ]] || vika_is_mounted; then
        switch_playback local || vika_warn "could not switch to local source"
    fi

    unmount_media
    clear_marker
    if ((DRY_RUN == 0)) && vika_is_mounted; then
        die "$VIKA_MOUNT_POINT is still mounted"
    fi
    vika_log "USB media detached; local playlist restored"
    return 0
}

do_reconcile() {
    local mounted_src=""

    ensure_dirs
    mounted_src=$(vika_mount_source || true)

    if [[ -n $mounted_src ]]; then
        if [[ ! -b $mounted_src ]]; then
            vika_log "mounted source $mounted_src disappeared; detaching"
            do_detach
            return 0
        fi
        if [[ -e $MARKER ]]; then
            return 0
        fi
        vika_log "media $mounted_src is mounted but not tracked; adopting it"
        do_attach "$mounted_src"
        return 0
    fi

    clear_marker
    if ! vika_select_usb >/dev/null; then
        if [[ -n ${VIKA_USB_REASON:-} && ${VIKA_USB_VERBOSE:-0} == 1 ]]; then
            vika_log "$VIKA_USB_REASON"
        fi
        return 0
    fi
    do_attach "${VIKA_USB_SELECTION%%|*}"
}

do_status() {
    local src="" opts="" last="" cur="" count
    if vika_is_mounted; then
        src=$(vika_mount_source)
        opts=$(vika_mount_options || true)
        printf 'mounted:   yes\nsource:    %s\noptions:   %s\n' "$src" "$opts"
    else
        printf 'mounted:   no\n'
    fi
    printf 'mountpoint: %s\n' "$VIKA_MOUNT_POINT"
    [[ -e $MARKER ]] && printf 'marker:    %s\n' "$(tr '\n' ' ' < "$MARKER")" || printf 'marker:    absent\n'
    if [[ -r "$VIKA_STATE_DIR/last-source" ]]; then
        last=$(<"$VIKA_STATE_DIR/last-source")
    fi
    printf 'last source: %s\n' "${last:-unknown}"
    if vika_mpc_quiet status; then
        cur=$(vika_current_uri)
        printf 'mpd:       reachable at %s\ncurrent:   %s\n' "$VIKA_MPD_HOST" "${cur:-<empty>}"
    else
        printf 'mpd:       NOT reachable at %s\n' "$VIKA_MPD_HOST"
    fi
    for src in local usb; do
        if [[ -r $(vika_playlist_file "$src") ]]; then
            count=$(wc -l < "$(vika_playlist_file "$src")")
            printf 'playlist %-5s %s track(s)\n' "$src" "$count"
        fi
    done
    if ! vika_usb_present; then
        printf 'usb:       no removable partition detected\n'
    else
        printf 'usb:       removable partition present\n'
    fi
}

case $ACTION in
    attach) do_attach "$DEVICE" ;;
    detach) do_detach ;;
    reconcile) do_reconcile ;;
    status) do_status ;;
esac
