#!/usr/bin/env bash
# Integration tests for scripts/play-source.sh using a fake mpc and fake media
# tree. No MPD, no root, no audio device, no network.
set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
# shellcheck source=lib/helpers.sh
. "$TEST_DIR/lib/helpers.sh"

printf '\n[test-play-source]\n'

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
export VIKA_BOOT_AUTOPLAY=1

mkdir -p "$VIKA_MUSIC_DIR/music" "$VIKA_MUSIC_DIR/audiobooks" \
    "$VIKA_MUSIC_DIR/usb" "$VIKA_PLAYLIST_DIR" "$VIKA_STATE_DIR" "$VIKA_TEST_MPC_DIR"
: > "$VIKA_TEST_MPC_LOG"

t_touch "$tmp/media/music/01-a.mp3"
t_touch "$tmp/media/music/02-b.ogg"
t_touch "$tmp/media/audiobooks/Book/Chapter 1.m4b"
t_touch "$tmp/media/usb/track-1.flac"
t_touch "$tmp/media/usb/track-2.mp3"
t_touch "$tmp/media/usb/notes.txt"

play_source="$REPO_ROOT/scripts/play-source.sh"

# --- first local run -------------------------------------------------------
: > "$VIKA_TEST_MPC_LOG"
"$play_source" local >/dev/null 2>&1
t_rc "play-source local exits 0" 0 $?

expected="$tmp/expected-local.m3u"
cat > "$expected" <<'EOF'
audiobooks/Book/Chapter 1.m4b
music/01-a.mp3
music/02-b.ogg
EOF
t_file_eq "local playlist content" "$expected" "$VIKA_PLAYLIST_DIR/local.m3u"
t_file_eq "MPD queue receives the same order" "$expected" "$VIKA_TEST_MPC_DIR/queue"
t_eq "last-source recorded" "local" "$(cat "$VIKA_STATE_DIR/last-source")"
calls=$(cat "$VIKA_TEST_MPC_LOG")
t_contains "queue was cleared" "clear" "$calls"
t_contains "local playlist was loaded" "load local" "$calls"
t_contains "playback started at the top" "play 0" "$calls"

# --- switch to "inserted" USB ---------------------------------------------
printf '1\n' > "$VIKA_TEST_MPC_DIR/cur"        # music/01-a.mp3 (0-based)
printf '42.5\n' > "$VIKA_TEST_MPC_DIR/elapsed"
printf 'playing\n' > "$VIKA_TEST_MPC_DIR/state"

: > "$VIKA_TEST_MPC_LOG"
"$play_source" usb >/dev/null 2>&1
t_rc "play-source usb exits 0" 0 $?
t_eq "local resume uri saved before switching" "music/01-a.mp3" "$(sed -n 1p "$VIKA_STATE_DIR/local.resume")"
t_eq "local resume position saved before switching" "42.5" "$(sed -n 2p "$VIKA_STATE_DIR/local.resume")"

expected_usb="$tmp/expected-usb.m3u"
cat > "$expected_usb" <<'EOF'
usb/track-1.flac
usb/track-2.mp3
EOF
t_file_eq "USB playlist ignores non-audio files" "$expected_usb" "$VIKA_PLAYLIST_DIR/usb.m3u"
t_file_eq "USB queue content" "$expected_usb" "$VIKA_TEST_MPC_DIR/queue"
t_eq "last-source switched to usb" "usb" "$(cat "$VIKA_STATE_DIR/last-source")"

# --- unplug: local playlist and position must come back -------------------
: > "$VIKA_TEST_MPC_LOG"
"$play_source" local >/dev/null 2>&1
t_rc "play-source local after unplug exits 0" 0 $?
calls=$(cat "$VIKA_TEST_MPC_LOG")
t_contains "restores local song index 1" "play 1" "$calls"
t_contains "restores local position 42.5s" "seek 42.5" "$calls"
t_eq "usb position remembered too" "usb/track-1.flac" "$(sed -n 1p "$VIKA_STATE_DIR/usb.resume")"
t_eq "last-source back to local" "local" "$(cat "$VIKA_STATE_DIR/last-source")"
t_file_eq "local queue restored in order" "$expected" "$VIKA_TEST_MPC_DIR/queue"

# --- empty medium must not destroy the current queue ----------------------
rm -f "$tmp/media/usb/track-1.flac" "$tmp/media/usb/track-2.mp3"
: > "$VIKA_TEST_MPC_LOG"
rc=0
"$play_source" usb >/dev/null 2>&1 || rc=$?
t_rc "empty USB source returns its own code" 4 "$rc"
t_file_eq "queue untouched for empty source" "$expected" "$VIKA_TEST_MPC_DIR/queue"
calls=$(cat "$VIKA_TEST_MPC_LOG")
if [[ $calls == *clear* ]]; then
    t_fail "empty source must not clear the queue"
else
    t_pass "empty source must not clear the queue"
fi

# --- paused mode -----------------------------------------------------------
: > "$VIKA_TEST_MPC_LOG"
"$play_source" local --no-play >/dev/null 2>&1
t_rc "play-source local --no-play exits 0" 0 $?
t_eq "queue stays paused" "paused" "$(cat "$VIKA_TEST_MPC_DIR/state")"

t_end
