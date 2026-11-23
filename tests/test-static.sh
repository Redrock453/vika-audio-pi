#!/usr/bin/env bash
# Static checks: shell syntax, configuration invariants and unit/udev sanity.
# Runs on any Linux laptop; optional tools are used only when present.
set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
# shellcheck source=lib/helpers.sh
. "$TEST_DIR/lib/helpers.sh"

printf '\n[test-static]\n'

# --- shell syntax ----------------------------------------------------------
mapfile -t shell_files < <(
    {
        find "$REPO_ROOT/scripts" -type f -name '*.sh'
        find "$REPO_ROOT/tests" -type f -name '*.sh'
        find "$REPO_ROOT/tests/lib/bin" -type f
    } | LC_ALL=C sort
)

for f in "${shell_files[@]}"; do
    err=$(mktemp "${TMPDIR:-/tmp}/vika-audio-syntax.XXXXXX") || exit 1
    if bash -n -- "$f" 2>"$err"; then
        t_pass "bash -n ${f#"$REPO_ROOT"/}"
    else
        t_fail "bash -n ${f#"$REPO_ROOT"/}"
        sed 's/^/        /' "$err" || true
    fi
    rm -f -- "$err"
done

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning -s bash \
        "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh \
        >/tmp/vika-audio-shellcheck.out 2>&1; then
        t_pass "shellcheck (warning level)"
    else
        if [[ ${VIKA_TEST_STRICT_SHELLCHECK:-0} == 1 ]]; then
            t_fail "shellcheck (warning level)"
            sed 's/^/        /' /tmp/vika-audio-shellcheck.out
        else
            t_skip "shellcheck reported findings (set VIKA_TEST_STRICT_SHELLCHECK=1 to fail)"
            sed 's/^/        /' /tmp/vika-audio-shellcheck.out
        fi
    fi
    rm -f /tmp/vika-audio-shellcheck.out
else
    t_skip "shellcheck not installed"
fi

# --- executable bits ------------------------------------------------------
for f in scripts/install.sh scripts/verify.sh scripts/usb-media.sh \
    scripts/play-source.sh scripts/boot-play.sh tests/run-tests.sh; do
    if [[ -x $REPO_ROOT/$f ]]; then
        t_pass "executable: $f"
    else
        t_fail "executable: $f"
    fi
done

# --- MPD configuration -----------------------------------------------------
mpd_conf="$REPO_ROOT/config/mpd.conf"
t_contains "mpd: analog device plughw:0,0" 'device      "plughw:0,0"' "$(cat "$mpd_conf")"
t_contains "mpd: UNIX socket binding" 'bind_to_address     "/run/vika-audio/mpd.sock"' "$(cat "$mpd_conf")"
t_contains "mpd: library root" 'music_directory     "/home/vika/media"' "$(cat "$mpd_conf")"
t_contains "mpd: restore starts paused" 'restore_paused      "yes"' "$(cat "$mpd_conf")"
if grep -Eq '^[[:space:]]*(port|bind_to_address)[[:space:]]+("?0\.0\.0\.0"?)' "$mpd_conf"; then
    t_fail "mpd: no wildcard TCP listener"
else
    t_pass "mpd: no wildcard TCP listener"
fi
if grep -Eq '^[[:space:]]*audio_output[[:space:]]*\{' "$mpd_conf"; then
    t_pass "mpd: has an audio_output block"
else
    t_fail "mpd: has an audio_output block"
fi
# The Bluetooth block must stay commented out until A2DP is accepted.
if awk '/^[^#]*bluealsa/ {found=1} END {exit(found ? 0 : 1)}' "$mpd_conf"; then
    t_fail "mpd: Bluetooth output must stay disabled/commented"
else
    t_pass "mpd: Bluetooth output is commented out"
fi

# --- runtime env -----------------------------------------------------------
env_file="$REPO_ROOT/config/vika-audio.env"
t_contains "env: USB mount point inside library" 'VIKA_MOUNT_POINT="/home/vika/media/usb"' "$(cat "$env_file")"
t_contains "env: boot autoplay default" 'VIKA_BOOT_AUTOPLAY="1"' "$(cat "$env_file")"
if grep -E '^[^#]*(PASSWORD|SECRET|TOKEN|API_KEY)=' "$env_file" >/dev/null; then
    t_fail "env: no credential assignments"
else
    t_pass "env: no credential assignments"
fi

# --- systemd units ---------------------------------------------------------
unit="$REPO_ROOT/systemd/vika-audio.service"
t_contains "unit: service user" "User=vika" "$(cat "$unit")"
t_contains "unit: audio group" "SupplementaryGroups=audio" "$(cat "$unit")"
t_contains "unit: MPD start line" "ExecStart=/usr/bin/mpd --no-daemon --stdout /etc/vika-audio/mpd.conf" "$(cat "$unit")"
t_contains "unit: boot autoplay hook" "ExecStartPost=/usr/local/lib/vika-audio/boot-play.sh" "$(cat "$unit")"
t_contains "unit: unix socket env" "MPD_HOST=/run/vika-audio/mpd.sock" "$(cat "$unit")"
t_contains "unit: read-only home" "ProtectHome=read-only" "$(cat "$unit")"
t_contains "unit: strict system protection" "ProtectSystem=strict" "$(cat "$unit")"
t_contains "unit: enabled at boot" "WantedBy=multi-user.target" "$(cat "$unit")"

usb_unit="$REPO_ROOT/systemd/vika-audio-usb.service"
t_contains "usb unit: oneshot" "Type=oneshot" "$(cat "$usb_unit")"
t_contains "usb unit: reconcile entry point" "usb-media.sh reconcile" "$(cat "$usb_unit")"
t_contains "usb unit: env file" "VIKA_ENV_FILE=/etc/vika-audio/vika-audio.env" "$(cat "$usb_unit")"

timer="$REPO_ROOT/systemd/vika-audio-usb.timer"
t_contains "timer: starts after boot" "OnBootSec=25s" "$(cat "$timer")"
t_contains "timer: points at reconcile service" "Unit=vika-audio-usb.service" "$(cat "$timer")"

rules="$REPO_ROOT/systemd/99-vika-audio-usb.rules"
t_contains "udev: only USB block devices" 'ENV{ID_BUS}=="usb"' "$(cat "$rules")"
t_contains "udev: starts the reconcile service" "vika-audio-usb.service" "$(cat "$rules")"

# --- installer safety ------------------------------------------------------
installer="$REPO_ROOT/scripts/install.sh"
t_contains "installer: dry run by default" "DRY RUN" "$(cat "$installer")"
t_contains "installer: explicit --apply" "--apply) APPLY=1" "$(cat "$installer")"
t_contains "installer: backups directory" "BACKUP_ROOT=/var/backups/vika-audio" "$(cat "$installer")"
t_contains "installer: disables stock MPD" 'disable --now "$unit"' "$(cat "$installer")"
if grep -Eq 'apt-get[[:space:]]+(upgrade|dist-upgrade|autoremove|clean)' "$installer"; then
    t_fail "installer: no destructive apt operations"
else
    t_pass "installer: no destructive apt operations"
fi
if grep -Eq '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh' "$installer"; then
    t_fail "installer: no piping remote scripts to a shell"
else
    t_pass "installer: no piping remote scripts to a shell"
fi

# --- documentation ---------------------------------------------------------
doc="$REPO_ROOT/docs/MPD_DEPLOY.md"
for needle in "passwordless sudo" "sudo" "read-only" "plughw:0,0" "resume" "MPD_DEPLOY"; do
    if grep -Fq -- "$needle" "$doc"; then
        t_pass "docs mention: $needle"
    else
        t_fail "docs mention: $needle"
    fi
done
if grep -Fq "MPD_DEPLOY.md" "$REPO_ROOT/README.md"; then
    t_pass "README links MPD_DEPLOY.md"
else
    t_fail "README links MPD_DEPLOY.md"
fi

# --- optional systemd verification ----------------------------------------
if [[ -x /usr/lib/systemd/systemd ]] && command -v systemd-analyze >/dev/null 2>&1 && [[ -x /usr/bin/mpd ]]; then
    if systemd-analyze verify "$unit" "$usb_unit" "$timer" 2>/tmp/vika-audio-verify.out; then
        t_pass "systemd-analyze verify"
    else
        t_fail "systemd-analyze verify"
        sed 's/^/        /' /tmp/vika-audio-verify.out
    fi
    rm -f /tmp/vika-audio-verify.out
else
    t_skip "systemd-analyze verify (needs systemd and installed /usr/bin/mpd)"
fi

if command -v udevadm >/dev/null 2>&1 && udevadm verify --help >/dev/null 2>&1; then
    if udevadm verify "$rules" >/tmp/vika-audio-udev.out 2>&1; then
        t_pass "udevadm verify"
    else
        t_fail "udevadm verify"
        sed 's/^/        /' /tmp/vika-audio-udev.out
    fi
    rm -f /tmp/vika-audio-udev.out
else
    t_skip "udevadm verify (not available)"
fi

t_end
