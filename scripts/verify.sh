#!/usr/bin/env bash
# Vika Audio Pi — read-only verification.
#
# Run as the service user; needs no root and changes nothing:
#   sudo -u vika /usr/local/sbin/vika-audio-verify
#   sudo -u vika /usr/local/sbin/vika-audio-verify --audio-test
#
# Exit code 0 only when no FAIL was reported. SKIP means a check could not be
# executed in this environment (for example optional tooling is absent).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -r $SCRIPT_DIR/lib/media-lib.sh ]]; then
    LIB_DIR=$SCRIPT_DIR/lib
else
    LIB_DIR=/usr/local/lib/vika-audio/lib
fi
# shellcheck source=lib/media-lib.sh
. "$LIB_DIR/media-lib.sh"

VIKA_LOG_TAG=vika-audio-verify

AUDIO_TEST=0
while (($#)); do
    case $1 in
        --audio-test) AUDIO_TEST=1 ;;
        -h | --help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

vika_load_env
vika_init_paths

PASS=0
FAIL=0
SKIP=0
WARN=0

ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }
note() { WARN=$((WARN + 1)); printf 'WARN  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }

section() { printf '\n== %s ==\n' "$*"; }

CONFIG=${VIKA_MPD_CONF:-/etc/vika-audio/mpd.conf}
UNIT=vika-audio.service

section "host"
arch=$(uname -m)
if [[ $arch == armv7l || $arch == armv6l ]]; then
    ok "32-bit ARM ($arch)"
else
    note "not a 32-bit ARM host ($arch); results do not describe the Pi"
fi
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "OS: ${PRETTY_NAME:-unknown}"
    if [[ ${VERSION_CODENAME:-} == trixie ]]; then
        ok "OS codename is trixie"
    else
        note "OS codename is '${VERSION_CODENAME:-unknown}', expected trixie"
    fi
else
    skip "no /etc/os-release"
fi
mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
if ((mem_kb >= 380000)); then
    ok "RAM ${mem_kb} kB fits the 512 MiB target"
else
    note "RAM ${mem_kb} kB is lower than expected for a 3 A+"
fi

section "user and groups"
info "running as: $(id -un) (uid $(id -u))"
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx audio; then
    ok "user is in the audio group"
else
    bad "user is not in the audio group (needs: usermod -aG audio $VIKA_USER)"
fi
if [[ $(id -un) == "$VIKA_USER" ]]; then
    ok "running as the configured service user ($VIKA_USER)"
else
    note "running as $(id -un), configured service user is $VIKA_USER"
fi
if sudo -n true 2>/dev/null; then
    info "passwordless sudo is available for this user (not required at runtime)"
else
    info "no passwordless sudo (expected: root steps need an interactive password)"
fi

section "packages"
for bin in mpd mpc aplay; do
    if command -v "$bin" >/dev/null 2>&1; then
        ok "$bin present: $(command -v "$bin")"
    else
        bad "$bin missing (install mpd mpc alsa-utils)"
    fi
done
if command -v mpd >/dev/null 2>&1; then
    info "mpd version: $(mpd --version 2>/dev/null | head -n1)"
fi
if command -v mpc >/dev/null 2>&1; then
    info "mpc version: $(mpc --version 2>/dev/null | head -n1)"
fi

section "MPD configuration"
if [[ -r $CONFIG ]]; then
    ok "config readable: $CONFIG"
else
    bad "config missing or unreadable: $CONFIG"
fi
if [[ -r $CONFIG ]]; then
    if grep -Eq '^[[:space:]]*device[[:space:]]+"plughw:0,0"' "$CONFIG"; then
        ok "primary ALSA output is plughw:0,0"
    else
        bad "config does not select plughw:0,0"
    fi
    if grep -Eq '^[[:space:]]*bind_to_address[[:space:]]+"/' "$CONFIG"; then
        ok "MPD listens on a UNIX socket only"
    else
        bad "config does not bind to a UNIX socket path"
    fi
    if grep -Eq '^[[:space:]]*(port|bind_to_address)[[:space:]]+("?0\.0\.0\.0"?|"any")' "$CONFIG"; then
        bad "config may expose a TCP listener"
    else
        ok "no wildcard TCP listener configured"
    fi
    if grep -Eq '^[[:space:]]*music_directory[[:space:]]+"/home/vika/media"' "$CONFIG"; then
        ok "music_directory is /home/vika/media"
    else
        note "music_directory is not /home/vika/media"
    fi
fi

section "systemd"
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
        ok "$UNIT is enabled"
    else
        bad "$UNIT is not enabled"
    fi
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        ok "$UNIT is active"
    else
        bad "$UNIT is not active"
    fi
    if systemctl is-enabled --quiet vika-audio-usb.timer 2>/dev/null || systemctl is-active --quiet vika-audio-usb.timer 2>/dev/null; then
        ok "USB reconcile timer is enabled/active"
    else
        note "USB reconcile timer is not enabled (udev rule may still work)"
    fi
else
    skip "systemctl not available"
fi

section "MPD socket and playback"
if [[ -S $VIKA_MPD_HOST ]]; then
    ok "socket exists: $VIKA_MPD_HOST"
else
    bad "socket missing: $VIKA_MPD_HOST (service not started?)"
fi
if vika_mpc_quiet status; then
    ok "mpc can talk to MPD over the UNIX socket"
    cur=$(vika_current_uri || true)
    if [[ -n $cur ]]; then
        ok "current track: $cur"
    else
        note "queue is empty (no audio indexed or no boot autoplay yet)"
    fi
else
    bad "mpc cannot talk to MPD (check journalctl -u $UNIT -b)"
fi

section "ALSA analog output"
if [[ -e /dev/snd/pcmC0D0p ]]; then
    ok "/dev/snd/pcmC0D0p exists (card 0 playback)"
else
    bad "/dev/snd/pcmC0D0p missing"
fi
if command -v aplay >/dev/null 2>&1; then
    if aplay -l 2>/dev/null | grep -q '^card 0:'; then
        ok "aplay sees card 0: $(aplay -l 2>/dev/null | awk '/^card 0:/ {print; exit}')"
    else
        bad "aplay does not list card 0"
    fi
    if aplay -L 2>/dev/null | grep -q '^plughw:CARD=Headphones'; then
        ok "plughw:CARD=Headphones is available (device plughw:0,0)"
    else
        note "plughw:CARD=Headphones not listed; confirm with: aplay -L | head"
    fi
else
    skip "aplay not installed"
fi

section "library"
prefix=$(vika_mount_prefix || true)
if [[ -n $prefix ]]; then
    ok "USB mount point is inside the library (prefix '$prefix/')"
else
    bad "mount point $VIKA_MOUNT_POINT is outside $VIKA_MUSIC_DIR"
fi
for d in "${VIKA_MUSIC_DIR}" "${VIKA_MUSIC_DIR}/music" "${VIKA_MUSIC_DIR}/audiobooks"; do
    if [[ -d $d ]]; then
        ok "directory exists: $d"
    else
        note "directory missing: $d"
    fi
done
for src in local usb; do
    pl=$(vika_playlist_file "$src")
    if [[ -r $pl ]]; then
        n=$(wc -l < "$pl")
        if ((n > 0)); then
            ok "playlist $src: $n track(s)"
        else
            note "playlist $src is empty"
        fi
    else
        note "playlist $src has not been built yet"
    fi
done

section "USB medium (if mounted)"
if vika_is_mounted; then
    mnt_src=$(vika_mount_source)
    mnt_opts=$(vika_mount_options || true)
    ok "$VIKA_MOUNT_POINT is mounted from $mnt_src"
    if [[ ",$mnt_opts," == *,ro,* ]]; then
        ok "mounted read-only"
    else
        bad "mounted WITHOUT ro ($mnt_opts) — unmount immediately"
    fi
    if [[ ",$mnt_opts," == *,nosuid,* && ",$mnt_opts," == *,nodev,* && ",$mnt_opts," == *,noexec,* ]]; then
        ok "mounted nosuid,nodev,noexec"
    else
        note "missing one of nosuid/nodev/noexec ($mnt_opts)"
    fi
    if [[ -r $VIKA_STATE_DIR/usb.active ]]; then
        ok "USB marker present (state: $(tr '\n' ' ' < "$VIKA_STATE_DIR/usb.active"))"
    else
        note "USB mounted but no marker; usb-media.sh has not adopted it"
    fi
else
    info "no USB medium mounted"
fi

section "network exposure"
if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | grep -Eq '[:.]6600[[:space:]]'; then
        bad "something listens on TCP 6600 (stock MPD?); no external port is allowed"
    else
        ok "no TCP listener on port 6600"
    fi
else
    skip "ss not available (iproute2)"
fi
info "player does not use Wi-Fi at runtime: no network unit is required by $UNIT"

section "boot autoplay"
if [[ -r $VIKA_STATE_DIR/last-source ]]; then
    info "last source: $(<"$VIKA_STATE_DIR/last-source")"
else
    info "no last-source recorded yet"
fi
if [[ $VIKA_BOOT_AUTOPLAY == 0 ]]; then
    info "VIKA_BOOT_AUTOPLAY=0 (boot restores paused)"
else
    info "VIKA_BOOT_AUTOPLAY=$VIKA_BOOT_AUTOPLAY (boot starts playback)"
fi

if ((AUDIO_TEST)); then
    section "audible test (3 s sine on plughw:0,0)"
    if ! command -v speaker-test >/dev/null 2>&1; then
        skip "speaker-test not installed (alsa-utils)"
    else
        info "playing a 3-second 440 Hz tone; this is intentionally audible"
        if timeout 10 speaker-test -D plughw:0,0 -c 2 -t sine -f 440 -l 1 >/dev/null 2>&1; then
            ok "speaker-test completed without ALSA error"
        else
            bad "speaker-test failed (check mixer/mute and card index)"
        fi
    fi
fi

printf '\n== summary ==\n'
printf 'PASS %d  FAIL %d  WARN %d  SKIP %d\n' "$PASS" "$FAIL" "$WARN" "$SKIP"
if ((FAIL > 0)); then
    printf 'Result: NOT READY (%d failing check(s))\n' "$FAIL"
    exit 1
fi
printf 'Result: all executed checks passed\n'
exit 0
