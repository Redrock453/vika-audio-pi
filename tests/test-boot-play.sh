#!/usr/bin/env bash
# Tests for scripts/boot-play.sh: offline boot choice (USB > local), autoplay
# policy, and the "no media = idle, no failure" rule.
set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
# shellcheck source=lib/helpers.sh
. "$TEST_DIR/lib/helpers.sh"

printf '\n[test-boot-play]\n'

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
export VIKA_MPD_WAIT_SECONDS=2
export VIKA_USB_BOOT_WAIT_SECONDS=0
export VIKA_TEST_LSBLK_FILE="$tmp/lsblk.empty"
export VIKA_TEST_ROOT_SOURCE=""

mkdir -p "$VIKA_MUSIC_DIR/music" "$VIKA_MUSIC_DIR/audiobooks" \
    "$VIKA_MUSIC_DIR/usb" "$VIKA_PLAYLIST_DIR" "$VIKA_STATE_DIR" "$VIKA_TEST_MPC_DIR"
: > "$VIKA_TEST_MPC_LOG"
: > "$tmp/lsblk.empty"

t_touch "$tmp/media/music/01-a.mp3"
t_touch "$tmp/media/audiobooks/Book/Chapter 1.m4b"

boot_play="$REPO_ROOT/scripts/boot-play.sh"

# --- local autoplay --------------------------------------------------------
export VIKA_BOOT_AUTOPLAY=1
"$boot_play" >/dev/null 2>&1
t_rc "boot-play exits 0 with local media" 0 $?
t_eq "boot autoplay selected local" "local" "$(cat "$VIKA_STATE_DIR/last-source")"
t_eq "boot autoplay is playing" "playing" "$(cat "$VIKA_TEST_MPC_DIR/state")"

expected="$tmp/expected.m3u"
cat > "$expected" <<'EOF'
audiobooks/Book/Chapter 1.m4b
music/01-a.mp3
EOF
t_file_eq "boot queue order" "$expected" "$VIKA_TEST_MPC_DIR/queue"

# --- paused policy ---------------------------------------------------------
export VIKA_BOOT_AUTOPLAY=0
"$boot_play" >/dev/null 2>&1
t_rc "boot-play exits 0 in paused mode" 0 $?
t_eq "VIKA_BOOT_AUTOPLAY=0 starts paused" "paused" "$(cat "$VIKA_TEST_MPC_DIR/state")"

# --- USB mounted at boot ---------------------------------------------------
export VIKA_BOOT_AUTOPLAY=1
export VIKA_TEST_MOUNT_SOURCE="/dev/sdb1"
export VIKA_TEST_MOUNT_OPTIONS="ro,nosuid,nodev,noexec,noatime"
t_touch "$tmp/media/usb/usb-book.mp3"
# The fake queue still holds the local playlist; boot-play must switch source.
"$boot_play" >/dev/null 2>&1
t_rc "boot-play exits 0 with USB mounted" 0 $?
t_eq "boot prefers mounted USB" "usb" "$(cat "$VIKA_STATE_DIR/last-source")"
t_eq "USB queue was loaded" "usb/usb-book.mp3" "$(sed -n 1p "$VIKA_TEST_MPC_DIR/queue")"

# --- no media at all -------------------------------------------------------
unset VIKA_TEST_MOUNT_SOURCE VIKA_TEST_MOUNT_OPTIONS
rm -f "$tmp/media/music/01-a.mp3" "$tmp/media/audiobooks/Book/Chapter 1.m4b" "$tmp/media/usb/usb-book.mp3"
rm -f "$VIKA_PLAYLIST_DIR/local.m3u" "$VIKA_PLAYLIST_DIR/usb.m3u"
"$boot_play" >/dev/null 2>&1
t_rc "boot-play exits 0 with no media (no restart loop)" 0 $?

t_end
