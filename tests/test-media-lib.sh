#!/usr/bin/env bash
# Unit tests for scripts/lib/media-lib.sh: playlist building, filtering,
# deterministic order, resume files and mpc interaction.
set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
# shellcheck source=lib/helpers.sh
. "$TEST_DIR/lib/helpers.sh"

printf '\n[test-media-lib]\n'

tmp=$(t_new_tmp)
export VIKA_ENV_FILE=/dev/null
export PATH="$TEST_DIR/lib/bin:$PATH"
export VIKA_MUSIC_DIR="$tmp/media"
export VIKA_MOUNT_POINT="$tmp/media/usb"
export VIKA_PLAYLIST_DIR="$tmp/playlists"
export VIKA_STATE_DIR="$tmp/state"
export VIKA_MPD_HOST="$tmp/mpd.sock"
export VIKA_MPC_BIN="$TEST_DIR/lib/bin/mpc"
export VIKA_TEST_MPC_DIR="$tmp/mpc"
export VIKA_TEST_MPC_LOG="$tmp/mpc.log"

mkdir -p "$VIKA_MUSIC_DIR" "$VIKA_PLAYLIST_DIR" "$VIKA_STATE_DIR" "$VIKA_TEST_MPC_DIR"
: > "$VIKA_TEST_MPC_LOG"

# shellcheck source=../scripts/lib/media-lib.sh
. "$REPO_ROOT/scripts/lib/media-lib.sh"
vika_init_paths

# --- fixture ---------------------------------------------------------------
t_touch "$tmp/media/music/01-a.mp3"
t_touch "$tmp/media/music/02-b.MP3"
t_touch "$tmp/media/music/Sub Dir/03 c.ogg"
t_touch "$tmp/media/music/notes.txt"
t_touch "$tmp/media/music/.hidden.mp3"
t_touch "$tmp/media/music/._junk.mp3"
t_touch "$tmp/media/music/back\\slash.mp3"
ln -s "01-a.mp3" "$tmp/media/music/link.mp3"
t_touch "$tmp/media/audiobooks/Book/Chapter 1.m4b"
t_touch "$tmp/media/audiobooks/Book/cover.jpg"
t_touch "$tmp/media/audiobooks/Book/.cue.mp3"

t_touch "$tmp/media/usb/A.flac"
t_touch "$tmp/media/usb/b.mp3"
t_touch "$tmp/media/usb/nested/C.ogg"
t_touch "$tmp/media/usb/readme.txt"
t_touch "$tmp/media/usb/.dot.mp3"

# --- extension filter ------------------------------------------------------
for f in a.mp3 b.MP3 c.ogg d.oga e.opus f.m4a g.m4b h.flac i.wav j.AIFF k.wma; do
    if vika_is_audio_file "/x/$f"; then t_pass "audio accepted: $f"; else t_fail "audio accepted: $f"; fi
done
for f in a.txt b.jpg c.nfo d; do
    if vika_is_audio_file "/x/$f"; then t_fail "non-audio rejected: $f"; else t_pass "non-audio rejected: $f"; fi
done
if vika_is_audio_file "/x/.hidden.mp3"; then t_fail "hidden file rejected"; else t_pass "hidden file rejected"; fi
if vika_is_audio_file "/x/._junk.mp3"; then t_fail "AppleDouble file rejected"; else t_pass "AppleDouble file rejected"; fi

# --- deterministic local playlist -----------------------------------------
expected="$tmp/expected-local.m3u"
cat > "$expected" <<'EOF'
audiobooks/Book/Chapter 1.m4b
music/01-a.mp3
music/02-b.MP3
music/Sub Dir/03 c.ogg
EOF

vika_build_playlist local "$VIKA_PLAYLIST_DIR/local.m3u"
t_rc "local playlist build succeeded" 0 $?
t_eq "local track count" 4 "${VIKA_PLAYLIST_TRACKS:-x}"
t_file_eq "local playlist is sorted by byte order and filtered" "$expected" "$VIKA_PLAYLIST_DIR/local.m3u"

expected_usb="$tmp/expected-usb.m3u"
cat > "$expected_usb" <<'EOF'
usb/A.flac
usb/b.mp3
usb/nested/C.ogg
EOF
vika_build_playlist usb "$VIKA_PLAYLIST_DIR/usb.m3u"
t_rc "usb playlist build succeeded" 0 $?
t_eq "usb track count" 3 "${VIKA_PLAYLIST_TRACKS:-x}"
t_file_eq "usb playlist uses library-relative paths" "$expected_usb" "$VIKA_PLAYLIST_DIR/usb.m3u"

# --- resume save ----------------------------------------------------------
cp "$VIKA_PLAYLIST_DIR/local.m3u" "$VIKA_TEST_MPC_DIR/queue"
printf '1\n' > "$VIKA_TEST_MPC_DIR/cur"
printf 'playing\n' > "$VIKA_TEST_MPC_DIR/state"
printf '42.5\n' > "$VIKA_TEST_MPC_DIR/elapsed"

t_eq "current uri" "music/01-a.mp3" "$(vika_current_uri)"
t_eq "current source" "local" "$(vika_current_source)"

vika_save_resume local >/dev/null 2>&1
t_rc "save local resume" 0 $?
t_eq "resume uri" "music/01-a.mp3" "$(sed -n 1p "$VIKA_STATE_DIR/local.resume")"
t_eq "resume elapsed" "42.5" "$(sed -n 2p "$VIKA_STATE_DIR/local.resume")"

# --- resume restore (select, pause, seek, play) ---------------------------
: > "$VIKA_TEST_MPC_LOG"
vika_restore_source local play >/dev/null 2>&1
t_rc "restore local source" 0 $?
calls=$(cat "$VIKA_TEST_MPC_LOG")
t_contains "restore selects saved song index 2 (MPC one-based)" "play 2" "$calls"
t_contains "restore pauses before seeking" "pause" "$calls"
t_contains "restore seeks to saved position" "seek 42.5" "$calls"

# --- short position does not seek ----------------------------------------
printf 'music/01-a.mp3\n2.0\n' > "$VIKA_STATE_DIR/local.resume"
: > "$VIKA_TEST_MPC_LOG"
vika_restore_source local play >/dev/null 2>&1
calls=$(cat "$VIKA_TEST_MPC_LOG")
if [[ $calls == *seek* ]]; then
    t_fail "position <5s must not trigger seek"
else
    t_pass "position <5s must not trigger seek"
fi

# --- paused mode ----------------------------------------------------------
: > "$VIKA_TEST_MPC_LOG"
vika_restore_source local paused >/dev/null 2>&1
calls=$(cat "$VIKA_TEST_MPC_LOG")
t_contains "paused mode pauses the queue" "pause" "$calls"

# --- mount prefix guard ---------------------------------------------------
if vika_mount_prefix >/dev/null; then
    t_pass "mount prefix resolved inside the library"
else
    t_fail "mount prefix resolved inside the library"
fi
VIKA_MOUNT_POINT="$tmp/outside"
if vika_mount_prefix >/dev/null; then
    t_fail "mount point outside library is refused"
else
    t_pass "mount point outside library is refused"
fi
VIKA_MOUNT_POINT="$tmp/media/usb"

# --- USB discovery (fake lsblk) ------------------------------------------
cat > "$tmp/lsblk.one" <<'EOF'
PATH="/dev/sdb1" RM="1" TRAN="usb" TYPE="part" FSTYPE="vfat"
PATH="/dev/sdb" RM="1" TRAN="usb" TYPE="disk" FSTYPE=""
PATH="/dev/mmcblk0p1" RM="0" TRAN="mmc" TYPE="part" FSTYPE="vfat"
EOF
export VIKA_TEST_LSBLK_FILE="$tmp/lsblk.one"
export VIKA_TEST_ROOT_SOURCE="/dev/mmcblk0p2"
t_eq "single removable partition selected" "/dev/sdb1|vfat" "$(vika_select_usb)"
if vika_usb_present; then t_pass "USB presence detected"; else t_fail "USB presence detected"; fi

cat > "$tmp/lsblk.two" <<'EOF'
PATH="/dev/sdb1" RM="1" TRAN="usb" TYPE="part" FSTYPE="vfat"
PATH="/dev/sdc1" RM="1" TRAN="usb" TYPE="part" FSTYPE="exfat"
EOF
export VIKA_TEST_LSBLK_FILE="$tmp/lsblk.two"
if vika_select_usb >/dev/null; then
    t_fail "ambiguous media refused"
else
    t_pass "ambiguous media refused"
fi
t_contains "ambiguity reason mentions pinning" "multiple removable USB partitions" "${VIKA_USB_REASON:-}"

cat > "$tmp/lsblk.root" <<'EOF'
PATH="/dev/sda1" RM="1" TRAN="usb" TYPE="part" FSTYPE="vfat"
EOF
export VIKA_TEST_LSBLK_FILE="$tmp/lsblk.root"
export VIKA_TEST_ROOT_SOURCE="/dev/sda2"
export VIKA_TEST_PKNAME_MAP="$tmp/pkname.map"
printf '/dev/sda1 sda\n/dev/sda2 sda\n' > "$VIKA_TEST_PKNAME_MAP"
if vika_select_usb >/dev/null; then
    t_fail "root disk on USB is never selected"
else
    t_pass "root disk on USB is never selected"
fi

# USB storage that does not set the removable flag (USB SSD/enclosure):
# detection must fall back to the parent disk transport.
cat > "$tmp/lsblk.ssd" <<'EOF'
PATH="/dev/sdd1" RM="0" TRAN="" TYPE="part" FSTYPE="ext4"
EOF
export VIKA_TEST_LSBLK_FILE="$tmp/lsblk.ssd"
export VIKA_TEST_ROOT_SOURCE="/dev/mmcblk0p2"
printf '/dev/sdd1 sdd\n' > "$VIKA_TEST_PKNAME_MAP"
export VIKA_TEST_PARENT_TRAN="usb"
t_eq "non-removable USB storage detected via parent transport" "/dev/sdd1|ext4" "$(vika_select_usb)"
unset VIKA_TEST_PARENT_TRAN

t_end
