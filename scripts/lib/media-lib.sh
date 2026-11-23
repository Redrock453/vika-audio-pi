#!/usr/bin/env bash
# Vika Audio Pi — shared shell helpers.
#
# Sourced by scripts/play-source.sh, scripts/boot-play.sh and
# scripts/usb-media.sh. Tests source it directly. It has no top-level side
# effects and performs no privileged action.
#
# Everything is overridable through environment variables (see
# config/vika-audio.env); tests point the paths at a temporary directory.

vika_log()  { printf '%s: %s\n' "${VIKA_LOG_TAG:-vika-audio}" "$*" >&2; }
vika_warn() { printf '%s: WARNING: %s\n' "${VIKA_LOG_TAG:-vika-audio}" "$*" >&2; }
vika_err()  { printf '%s: ERROR: %s\n' "${VIKA_LOG_TAG:-vika-audio}" "$*" >&2; }

# Load /etc/vika-audio/vika-audio.env when present. Set VIKA_ENV_FILE to
# /dev/null to disable (tests do this).
vika_load_env() {
    local f="${VIKA_ENV_FILE:-/etc/vika-audio/vika-audio.env}"
    if [[ -r $f ]]; then
        # shellcheck disable=SC1090
        set -a
        . "$f"
        set +a
    fi
}

vika_trim_slash() {
    local p=$1
    while [[ $p == */ && $p != / ]]; do
        p=${p%/}
    done
    printf '%s' "$p"
}

# Defaults are applied only when a variable is unset or empty, so values from
# the env file win.
vika_init_paths() {
    : "${VIKA_USER:=vika}"
    : "${VIKA_MUSIC_DIR:=/home/vika/media}"
    : "${VIKA_LOCAL_SUBDIRS:=music audiobooks}"
    : "${VIKA_MOUNT_POINT:=${VIKA_MUSIC_DIR%/}/usb}"
    : "${VIKA_PLAYLIST_DIR:=/var/lib/vika-audio/playlists}"
    : "${VIKA_STATE_DIR:=/var/lib/vika-audio/state}"
    : "${VIKA_MPD_HOST:=/run/vika-audio/mpd.sock}"
    : "${VIKA_MPC_BIN:=/usr/bin/mpc}"
    : "${VIKA_AUDIO_EXT:=mp3 flac ogg oga opus m4a m4b aac wav wave aif aiff wma wv ape}"
    : "${VIKA_BOOT_AUTOPLAY:=1}"
    : "${VIKA_MPD_WAIT_SECONDS:=60}"
    : "${VIKA_USB_BOOT_WAIT_SECONDS:=15}"
    : "${VIKA_USB_DEVICE:=}"
    : "${VIKA_MPC_TIMEOUT:=15}"

    VIKA_MUSIC_DIR=$(vika_trim_slash "$VIKA_MUSIC_DIR")
    VIKA_MOUNT_POINT=$(vika_trim_slash "$VIKA_MOUNT_POINT")
    VIKA_PLAYLIST_DIR=$(vika_trim_slash "$VIKA_PLAYLIST_DIR")
    VIKA_STATE_DIR=$(vika_trim_slash "$VIKA_STATE_DIR")
    VIKA_AUDIO_EXT=${VIKA_AUDIO_EXT,,}
}

# Relative path ("usb", "music", ...) of the mount point below the music
# directory. Fails when the mount point is outside the library, because MPD
# would then not be able to index it.
vika_mount_prefix() {
    local mp=${VIKA_MOUNT_POINT%/} md=${VIKA_MUSIC_DIR%/}
    if [[ $mp == "$md"/* ]]; then
        printf '%s' "${mp#"$md"/}"
        return 0
    fi
    return 1
}

# Extract KEY="value" from one lsblk -P line without being fooled by a key
# that is a suffix of another one (TYPE vs FSTYPE).
vika_lsblk_field() {
    local line=$1 key=$2
    sed -n -e "s/^$key=\"\([^\"]*\)\".*/\1/p" \
        -e "s/.*[[:space:]]$key=\"\([^\"]*\)\".*/\1/p" <<< "$line" | head -n1
}

vika_is_audio_file() {
    local path=$1 name ext
    name=${path##*/}
    [[ $name == ?*.* ]] || return 1
    [[ $name != .* && $name != ._* ]] || return 1
    ext=${name##*.}
    ext=${ext,,}
    case " $VIKA_AUDIO_EXT " in
        *" $ext "*) return 0 ;;
    esac
    return 1
}

# Reject names that would corrupt a line-based m3u playlist or escape the
# library: newlines, carriage returns, backslashes, absolute paths and hidden
# path components.
vika_rel_is_safe() {
    local rel=$1
    [[ -n $rel ]] || return 1
    [[ $rel == /* ]] && return 1
    [[ $rel == *$'\n'* || $rel == *$'\r'* || $rel == *\\* ]] && return 1
    [[ $rel == .* || $rel == */.* ]] && return 1
    return 0
}

# vika_build_playlist <local|usb> <output.m3u>
#
# Deterministic order: byte-wise (LC_ALL=C) sort of the library-relative path,
# so the result does not depend on locale, directory order or mount order.
# Symlinks are not followed, the scan stays on one filesystem (-xdev), and only
# known audio extensions are kept. Nothing is ever deleted or renamed.
#
# Sets VIKA_PLAYLIST_TRACKS and VIKA_PLAYLIST_SKIPPED.
vika_build_playlist() {
    local source=$1 out=$2
    local root rel f raw tmp count=0 skipped=0
    local -a roots=() dirs=()

    case $source in
        local)
            read -ra dirs <<< "$VIKA_LOCAL_SUBDIRS"
            for root in "${dirs[@]}"; do
                [[ -n $root ]] || continue
                roots+=("$VIKA_MUSIC_DIR/$root")
            done
            ;;
        usb)
            if ! vika_mount_prefix >/dev/null; then
                vika_err "mount point $VIKA_MOUNT_POINT is outside $VIKA_MUSIC_DIR"
                return 2
            fi
            roots=("$VIKA_MOUNT_POINT")
            ;;
        *)
            vika_err "unknown playlist source: $source"
            return 2
            ;;
    esac

    mkdir -p -- "$(dirname -- "$out")" || return 1
    raw="$out.raw.$$"
    tmp="$out.tmp.$$"
    : > "$raw" || return 1

    for root in "${roots[@]}"; do
        [[ -d $root ]] || continue
        find "$root" -xdev -type f -print0 2>/dev/null >> "$raw" || true
    done

    : > "$tmp" || { rm -f -- "$raw"; return 1; }
    while IFS= read -r -d '' f; do
        rel=${f#"$VIKA_MUSIC_DIR"/}
        if [[ $rel == "$f" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        if ! vika_rel_is_safe "$rel" || ! vika_is_audio_file "$f"; then
            skipped=$((skipped + 1))
            continue
        fi
        printf '%s\n' "$rel" >> "$tmp" || { rm -f -- "$raw" "$tmp"; return 1; }
        count=$((count + 1))
    done < <(LC_ALL=C sort -z -- "$raw")

    rm -f -- "$raw"
    chmod 0640 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$out" || return 1

    VIKA_PLAYLIST_TRACKS=$count
    VIKA_PLAYLIST_SKIPPED=$skipped
    vika_log "playlist '$source': $count track(s), $skipped ignored -> $out"
    return 0
}

vika_playlist_file() {
    printf '%s/%s.m3u' "$VIKA_PLAYLIST_DIR" "$1"
}

vika_atomic_write() {
    local dst=$1
    shift
    local tmp="${dst}.tmp.$$" line
    mkdir -p -- "$(dirname -- "$dst")" || return 1
    ( umask 0077; : > "$tmp" ) || return 1
    for line in "$@"; do
        printf '%s\n' "$line" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    done
    mv -f -- "$tmp" "$dst"
}

# --- MPD / mpc wrappers ----------------------------------------------------
# A UNIX socket only; no host/port is ever used. MPD_HOST is exported per call
# so the scripts also work when started by root via runuser.
vika_mpc() {
    MPD_HOST="$VIKA_MPD_HOST" timeout "${VIKA_MPC_TIMEOUT:-15}" "$VIKA_MPC_BIN" "$@"
}

vika_mpc_quiet() {
    vika_mpc "$@" >/dev/null 2>&1
}

vika_mpd_wait() {
    local seconds=${1:-$VIKA_MPD_WAIT_SECONDS}
    local deadline=$((SECONDS + seconds))
    while ((SECONDS < deadline)); do
        vika_mpc_quiet status && return 0
        sleep 1
    done
    return 1
}

vika_current_uri() {
    vika_mpc -f '%file%' current 2>/dev/null | head -n1 || true
}

# "local", "usb" or nothing (empty queue / unknown URI).
vika_current_source() {
    local uri prefix d
    local -a dirs=()
    uri=$(vika_current_uri)
    [[ -n $uri ]] || return 1
    if prefix=$(vika_mount_prefix); then
        [[ $uri == "$prefix"/* ]] && { printf 'usb'; return 0; }
    fi
    read -ra dirs <<< "$VIKA_LOCAL_SUBDIRS"
    for d in "${dirs[@]}"; do
        [[ $uri == "$d"/* ]] && { printf 'local'; return 0; }
    done
    return 1
}

# Remember where the current source was paused so it can be restored later
# (this is what makes "local playlist resumes after unplug" deterministic).
vika_save_resume() {
    local src=$1 line uri elapsed
    line=$(vika_mpc -f '%file%|%elapsed%' current 2>/dev/null | head -n1) || return 1
    [[ $line == *'|'* ]] || return 1
    uri=${line%%|*}
    elapsed=${line#*|}
    [[ -n $uri && $uri != *'|'* ]] || return 1
    [[ $elapsed =~ ^[0-9]+(\.[0-9]+)?$ ]] || elapsed=0
    vika_atomic_write "$VIKA_STATE_DIR/$src.resume" "$uri" "$elapsed" || return 1
    vika_log "saved $src resume: $uri @ ${elapsed}s"
}

# vika_restore_source <local|usb> <play|paused>
# Selects the saved URI inside the freshly built playlist, seeks to the saved
# position while paused (no audible jump), then starts playback if requested.
vika_restore_source() {
    local src=$1 mode=$2
    local playlist resume uri="" elapsed=0 line idx=1 secs
    playlist=$(vika_playlist_file "$src")
    resume="$VIKA_STATE_DIR/$src.resume"

    if [[ -r $resume ]]; then
        {
            IFS= read -r uri || true
            IFS= read -r elapsed || true
        } < "$resume"
    fi

    if [[ -n $uri ]]; then
        line=$(grep -F -x -n -e "$uri" -- "$playlist" 2>/dev/null | head -n1 || true)
        if [[ -n $line ]]; then
            idx=${line%%:*}
            [[ $idx =~ ^[0-9]+$ ]] || idx=1
            idx=$((idx > 0 ? idx : 1))  # mpc play accepts 1-based indices, never 0
        else
            vika_warn "saved $src track '$uri' is not in the playlist; starting at the top"
            idx=1
        fi
    fi

    vika_mpc_quiet play "$idx" || return 1
    secs=${elapsed%%.*}
    [[ $secs =~ ^[0-9]+$ ]] || secs=0
    if ((secs > 5)); then
        vika_mpc_quiet pause || true
        vika_mpc_quiet seek "$elapsed" || vika_warn "seek to ${elapsed}s failed"
    fi
    if [[ $mode == play ]]; then
        vika_mpc_quiet play || true
    else
        vika_mpc_quiet pause || true
    fi
    return 0
}

# Refresh the MPD database for a subtree ("" = whole library). Waits for the
# update where mpc supports it; bounded to roughly four minutes so boot cannot
# hang forever. If the first wait times out, the update keeps running in MPD
# and we do not start a second scan.
vika_update_db() {
    local sub=${1:-}
    local rc=0
    local -a wait_after=(update --wait)
    local -a wait_before=(--wait update)
    local -a plain=(update)
    if [[ -n $sub ]]; then
        wait_after+=("$sub")
        wait_before+=("$sub")
        plain+=("$sub")
    fi

    MPD_HOST="$VIKA_MPD_HOST" timeout 240 "$VIKA_MPC_BIN" "${wait_after[@]}" >/dev/null 2>&1 || rc=$?
    if ((rc == 0)); then
        return 0
    fi
    if ((rc == 124)); then
        vika_warn "database update is still running after 240s; continuing"
        return 0
    fi

    rc=0
    MPD_HOST="$VIKA_MPD_HOST" timeout 240 "$VIKA_MPC_BIN" "${wait_before[@]}" >/dev/null 2>&1 || rc=$?
    if ((rc == 0)); then
        return 0
    fi
    if ((rc == 124)); then
        vika_warn "database update is still running after 240s; continuing"
        return 0
    fi

    vika_warn "mpc update --wait not available; updating without waiting"
    rc=0
    vika_mpc_quiet "${plain[@]}" || rc=$?
    ((rc == 0)) || vika_warn "mpc update failed"
    sleep 2
    return 0
}

vika_set_last_source() {
    vika_atomic_write "$VIKA_STATE_DIR/last-source" "$1" || true
}

# --- USB discovery ---------------------------------------------------------
# Transport of the parent disk for a partition, because lsblk reports TRAN
# only for disks ("sda1" has TRAN=""). Used to catch USB SSDs/enclosures that
# do not set the removable flag.
vika_part_transport() {
    local path=$1 parent tran
    parent=$(lsblk -n -o PKNAME "$path" 2>/dev/null | head -n1 || true)
    [[ -n $parent ]] || return 1
    tran=$(lsblk -dn -o TRAN "/dev/$parent" 2>/dev/null | head -n1 || true)
    [[ -n $tran ]] || return 1
    printf '%s' "$tran"
}

# Prints "<device>|<fstype>" for each removable/USB partition with a
# filesystem this project is willing to mount read-only.
vika_usb_candidates() {
    command -v lsblk >/dev/null 2>&1 || return 0
    local line path rm tran type fstype
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        path=$(vika_lsblk_field "$line" PATH)
        rm=$(vika_lsblk_field "$line" RM)
        tran=$(vika_lsblk_field "$line" TRAN)
        type=$(vika_lsblk_field "$line" TYPE)
        fstype=$(vika_lsblk_field "$line" FSTYPE)
        [[ $type == part ]] || continue
        if [[ $rm != 1 && $tran != usb ]]; then
            tran=$(vika_part_transport "$path" || true)
        fi
        [[ $rm == 1 || $tran == usb ]] || continue
        case $fstype in
            vfat | exfat | ext2 | ext3 | ext4 | ntfs | ntfs3 | iso9660) ;;
            *) continue ;;
        esac
        printf '%s|%s\n' "$path" "$fstype"
    done < <(lsblk -P -p -o PATH,RM,TRAN,TYPE,FSTYPE 2>/dev/null)
}

# Refuse the disk that carries the running root filesystem, including a Pi
# that boots from USB. This is the main guard against touching the system SD.
vika_is_root_device() {
    local dev=$1 root parent rparent
    command -v findmnt >/dev/null 2>&1 || return 1
    root=$(findmnt -n -o SOURCE --target / 2>/dev/null | head -n1 || true)
    [[ -n $root ]] || return 1
    [[ $root == "$dev" ]] && return 0
    command -v lsblk >/dev/null 2>&1 || return 1
    parent=$(lsblk -n -o PKNAME "$dev" 2>/dev/null | head -n1 || true)
    rparent=$(lsblk -n -o PKNAME "$root" 2>/dev/null | head -n1 || true)
    [[ -n $parent && $parent == "$rparent" ]] && return 0
    return 1
}

vika_blkid_fstype() {
    command -v blkid >/dev/null 2>&1 || return 1
    blkid -s TYPE -o value "$1" 2>/dev/null | head -n1
}

vika_blkid_label() {
    command -v blkid >/dev/null 2>&1 || return 1
    blkid -s LABEL -o value "$1" 2>/dev/null | head -n1
}

# vika_select_usb [pinned-device]
# Prints "<device>|<fstype>", sets VIKA_USB_SELECTION to the same value and
# returns 0. On failure returns 1 and sets VIKA_USB_REASON. Callers in the same
# shell should use VIKA_USB_SELECTION, because command substitution would run
# this function in a subshell and lose the reason.
vika_select_usb() {
    local pinned=${1:-${VIKA_USB_DEVICE:-}}
    local -a cands=()
    local entry dev fstype label picked=""

    VIKA_USB_SELECTION=""
    VIKA_USB_REASON=""

    if [[ -n $pinned ]]; then
        # The root-device guard also applies to a pinned device: a hand-edited
        # VIKA_USB_DEVICE must never end up mounting the system SD read-only.
        if vika_is_root_device "$pinned"; then
            VIKA_USB_REASON="configured device $pinned carries the root filesystem; refusing"
            return 1
        fi
        if [[ ! -b $pinned ]]; then
            VIKA_USB_REASON="configured device $pinned is not a block device"
            return 1
        fi
        fstype=$(vika_blkid_fstype "$pinned" || true)
        VIKA_USB_SELECTION="$pinned|${fstype:-unknown}"
        printf '%s\n' "$VIKA_USB_SELECTION"
        return 0
    fi

    while IFS= read -r entry; do
        [[ -n $entry ]] || continue
        dev=${entry%%|*}
        vika_is_root_device "$dev" && continue
        cands+=("$entry")
    done < <(vika_usb_candidates)

    if ((${#cands[@]} == 0)); then
        VIKA_USB_REASON="no removable USB partition with a supported filesystem"
        return 1
    fi
    if ((${#cands[@]} == 1)); then
        VIKA_USB_SELECTION=${cands[0]}
        printf '%s\n' "$VIKA_USB_SELECTION"
        return 0
    fi

    for entry in "${cands[@]}"; do
        dev=${entry%%|*}
        label=$(vika_blkid_label "$dev" || true)
        if [[ $label == VIKA_AUDIO ]]; then
            picked=$entry
            break
        fi
    done
    if [[ -n $picked ]]; then
        VIKA_USB_SELECTION=$picked
        printf '%s\n' "$VIKA_USB_SELECTION"
        return 0
    fi

    VIKA_USB_REASON="multiple removable USB partitions (${#cands[@]}); pin VIKA_USB_DEVICE or label one VIKA_AUDIO"
    return 1
}

vika_usb_present() {
    local entry dev
    while IFS= read -r entry; do
        [[ -n $entry ]] || continue
        dev=${entry%%|*}
        vika_is_root_device "$dev" && continue
        return 0
    done < <(vika_usb_candidates)
    return 1
}

# Read-only mount options per filesystem. vfat/exfat/ntfs get a umask so user
# vika can actually read the files; ext* relies on the files' own permissions.
vika_mount_opts() {
    case $1 in
        vfat | msdos) printf '%s' 'ro,nosuid,nodev,noexec,noatime,umask=0022,shortname=mixed' ;;
        exfat) printf '%s' 'ro,nosuid,nodev,noexec,noatime,umask=0022' ;;
        ntfs | ntfs3) printf '%s' 'ro,nosuid,nodev,noexec,noatime,umask=0022' ;;
        *) printf '%s' 'ro,nosuid,nodev,noexec,noatime' ;;
    esac
}

vika_mount_source() {
    command -v findmnt >/dev/null 2>&1 || return 1
    findmnt -rn -o SOURCE --mountpoint "$VIKA_MOUNT_POINT" 2>/dev/null | head -n1
}

vika_is_mounted() {
    [[ -n $(vika_mount_source) ]]
}

vika_mount_options() {
    command -v findmnt >/dev/null 2>&1 || return 1
    findmnt -rn -o OPTIONS --mountpoint "$VIKA_MOUNT_POINT" 2>/dev/null | head -n1
}
