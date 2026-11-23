#!/usr/bin/env bash
# Tests for scripts/usb-media.sh: candidate detection, refusals, read-only
# mount command construction, and idempotent reconcile. Everything runs in
# --dry-run / status mode with fake lsblk/findmnt, so no root is needed and no
# real device is touched.
set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
# shellcheck source=lib/helpers.sh
. "$TEST_DIR/lib/helpers.sh"

printf '\n[test-usb-media]\n'

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
export VIKA_TEST_ROOT_SOURCE="/dev/mmcblk0p2"
export VIKA_TEST_PKNAME_MAP="$tmp/pkname.map"

mkdir -p "$VIKA_MUSIC_DIR/usb" "$VIKA_PLAYLIST_DIR" "$VIKA_STATE_DIR" "$VIKA_TEST_MPC_DIR"
: > "$VIKA_TEST_MPC_LOG"
printf '/dev/sdb1 sdb\n/dev/sdc1 sdc\n' > "$VIKA_TEST_PKNAME_MAP"

usb_media="$REPO_ROOT/scripts/usb-media.sh"

# --- one removable partition ----------------------------------------------
cat > "$tmp/lsblk.one" <<'EOF'
PATH="/dev/sdb1" RM="1" TRAN="usb" TYPE="part" FSTYPE="vfat"
PATH="/dev/sdb" RM="1" TRAN="usb" TYPE="disk" FSTYPE=""
PATH="/dev/mmcblk0p1" RM="0" TRAN="mmc" TYPE="part" FSTYPE="vfat"
EOF
export VIKA_TEST_LSBLK_FILE="$tmp/lsblk.one"

rc=0
out=$("$usb_media" attach --dry-run 2>&1) || rc=$?
t_rc "attach dry-run with one USB partition" 0 "$rc"
t_contains "mounts the detected partition" "/dev/sdb1" "$out"
t_contains "mount is read-only" "mount -o ro" "$out"
t_contains "mount blocks suid/device/exec" "noexec" "$out"
t_contains "vfat gets a readable umask" "umask=0022" "$out"
t_contains "playback switch runs as vika" "runuser -u vika" "$out"
t_contains "USB playlist is selected" "play-source.sh usb" "$out"

# --- no device -------------------------------------------------------------
: > "$tmp/lsblk.empty"
export VIKA_TEST_LSBLK_FILE="$tmp/lsblk.empty"
rc=0
out=$("$usb_media" attach --dry-run 2>&1) || rc=$?
t_rc "attach dry-run without media fails cleanly" 1 "$rc"
t_contains "reason is explicit" "no removable USB partition" "$out"

# --- ambiguous media -------------------------------------------------------
cat > "$tmp/lsblk.two" <<'EOF'
PATH="/dev/sdb1" RM="1" TRAN="usb" TYPE="part" FSTYPE="vfat"
PATH="/dev/sdc1" RM="1" TRAN="usb" TYPE="part" FSTYPE="exfat"
EOF
export VIKA_TEST_LSBLK_FILE="$tmp/lsblk.two"
rc=0
out=$("$usb_media" attach --dry-run 2>&1) || rc=$?
t_rc "two candidates are refused" 1 "$rc"
t_contains "ambiguity is explained" "multiple removable USB partitions" "$out"

# --- root disk on USB must never be selected ------------------------------
cat > "$tmp/lsblk.root" <<'EOF'
PATH="/dev/sda1" RM="1" TRAN="usb" TYPE="part" FSTYPE="vfat"
EOF
export VIKA_TEST_LSBLK_FILE="$tmp/lsblk.root"
export VIKA_TEST_ROOT_SOURCE="/dev/sda2"
printf '/dev/sda1 sda\n/dev/sda2 sda\n' > "$VIKA_TEST_PKNAME_MAP"
rc=0
out=$("$usb_media" attach --dry-run 2>&1) || rc=$?
t_rc "the disk carrying / is refused" 1 "$rc"
t_contains "no mount command for the root disk" "no removable USB partition" "$out"

# --- reconcile is a quiet no-op without media -----------------------------
export VIKA_TEST_LSBLK_FILE="$tmp/lsblk.empty"
export VIKA_TEST_ROOT_SOURCE="/dev/mmcblk0p2"
rc=0
out=$("$usb_media" reconcile --dry-run 2>&1) || rc=$?
t_rc "reconcile without media is a no-op" 0 "$rc"

# --- status works unprivileged -------------------------------------------
rc=0
out=$("$usb_media" status 2>&1) || rc=$?
t_rc "status exits 0 without root" 0 "$rc"
t_contains "status reports no mount" "mounted:   no" "$out"
t_contains "status reports MPD reachability" "mpd:" "$out"

# --- detach dry-run is safe when nothing is mounted ----------------------
rc=0
out=$("$usb_media" detach --dry-run 2>&1) || rc=$?
t_rc "detach dry-run without media exits 0" 0 "$rc"

# --- marker cleanup is not a write in dry-run ----------------------------
t_rc "no marker was created in dry-run mode" 1 "$([[ -e $VIKA_STATE_DIR/usb.active ]] && echo 0 || echo 1)"

t_end
