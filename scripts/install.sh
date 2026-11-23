#!/usr/bin/env bash
# Vika Audio Pi — staged installer.
#
# DEFAULT IS A DRY RUN. Nothing is changed unless --apply is given, and
# --apply must run as root (interactive sudo password is expected — the vika
# user deliberately has no passwordless sudo).
#
# Examples:
#   ./scripts/install.sh                      # show the full plan, change nothing
#   ./scripts/install.sh --check              # validate this host/repo for install
#   sudo ./scripts/install.sh --apply         # apt + files + systemd units
#   sudo ./scripts/install.sh --apply --no-apt        # packages installed manually
#   sudo ./scripts/install.sh --apply --with-bluetooth
#
# Properties:
#   * apt is used only for an explicit install of missing packages; never
#     upgrade/autoremove/clean;
#   * every replaced file is backed up first under /var/backups/vika-audio;
#   * re-running with the same content is a no-op (idempotent);
#   * /etc/vika-audio/vika-audio.env is created only if missing, so local
#     tuning is never overwritten;
#   * no secrets are read, written or printed.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

APPLY=0
CHECK_ONLY=0
WITH_BLUETOOTH=0
WITH_USB_AUTOMOUNT=1
DO_APT=1
DO_APT_UPDATE=0
FORCE=0

usage() {
    sed -n '2,25p' "$0"
    exit "${1:-0}"
}

while (($#)); do
    case $1 in
        --apply) APPLY=1 ;;
        --dry-run) APPLY=0 ;;
        --check) CHECK_ONLY=1 ;;
        --with-bluetooth) WITH_BLUETOOTH=1 ;;
        --no-usb-automount) WITH_USB_AUTOMOUNT=0 ;;
        --no-apt) DO_APT=0 ;;
        --apt-update) DO_APT_UPDATE=1 ;;
        --force) FORCE=1 ;;
        -h | --help) usage 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

if ((APPLY)) && ((EUID != 0)); then
    die "--apply must run as root: sudo $0 --apply"
fi
if ((APPLY == 0)); then
    log "DRY RUN — no changes will be made. Re-run with --apply (as root) to install."
fi

# ---------------------------------------------------------------------------
# Source tree sanity
# ---------------------------------------------------------------------------
REQUIRED_FILES=(
    config/mpd.conf
    config/vika-audio.env
    scripts/lib/media-lib.sh
    scripts/play-source.sh
    scripts/boot-play.sh
    scripts/usb-media.sh
    scripts/verify.sh
    scripts/gpio-controls.py
    scripts/avrcp-mpd.py
    scripts/avrcp-keys.py
    scripts/bt-speaker.sh
    systemd/vika-avrcp.service
    systemd/vika-avrcp-keys.service
    systemd/vika-bt-speaker.service
    systemd/vika-audio-gpio.service
    docs/GPIO.md
    systemd/vika-audio.service
    systemd/vika-audio-usb.service
    systemd/vika-audio-usb.timer
    systemd/99-vika-audio-usb.rules
    docs/MPD_DEPLOY.md
)
for f in "${REQUIRED_FILES[@]}"; do
    [[ -f $REPO_ROOT/$f ]] || die "missing repository file: $f"
done

# ---------------------------------------------------------------------------
# Target checks
# ---------------------------------------------------------------------------
check_target() {
    local ok=1 id_like="" codename="" arch
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id_like=${ID:-}
        codename=${VERSION_CODENAME:-}
    fi
    case ${id_like}:${codename} in
        raspbian:trixie | debian:trixie) log "target OS: ${PRETTY_NAME:-unknown}" ;;
        *)
            warn "expected Raspberry Pi OS/Debian Trixie, found '${id_like:-?}/${codename:-?}'"
            ok=0
            ;;
    esac
    arch=$(uname -m)
    if [[ $arch != armv7l && $arch != armv6l ]]; then
        warn "expected 32-bit ARM (armv7l), found $arch"
        ok=0
    fi
    if ! id -u vika >/dev/null 2>&1; then
        warn "user 'vika' does not exist"
        ok=0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemd not found"
        ok=0
    fi
    if ((ok == 0)); then
        if ((FORCE)); then
            warn "continuing because --force was given"
        else
            die "target check failed; use --force only if you really know why"
        fi
    else
        log "target check passed"
    fi
}

check_target
if ((CHECK_ONLY)); then
    log "checks finished (no changes)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
PKGS=(mpd mpc alsa-utils python3-gpiozero python3-lgpio)
if ((WITH_BLUETOOTH)); then
    PKGS+=(bluez bluez-alsa-utils libasound2-plugin-bluez python3-dbus python3-gi)
fi

MISSING=()
for p in "${PKGS[@]}"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
        log "already installed: $p"
    else
        MISSING+=("$p")
    fi
done

if ((${#MISSING[@]})); then
    log "missing packages: ${MISSING[*]}"
    log "manual install command (run it yourself if you prefer):"
    printf '  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s\n' "${MISSING[*]}"
    if ((APPLY && DO_APT)); then
        if ((DO_APT_UPDATE)); then
            log "apt-get update"
            DEBIAN_FRONTEND=noninteractive apt-get update || die "apt-get update failed (network is only needed once, for setup)"
        fi
        log "installing with apt-get (no upgrade/autoremove)"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MISSING[@]}" \
            || die "apt-get install failed"
    elif ((APPLY)); then
        warn "--no-apt given; install the packages above before enabling the service"
    fi
else
    log "all required packages are installed"
fi

# ---------------------------------------------------------------------------
# Files, backups, ownership
# ---------------------------------------------------------------------------
ETC_DIR=/etc/vika-audio
LIB_DIR=/usr/local/lib/vika-audio
UNIT_DIR=/etc/systemd/system
UDEV_DIR=/etc/udev/rules.d
DOC_DIR=/usr/local/share/doc/vika-audio
BACKUP_ROOT=/var/backups/vika-audio
BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"

run() {
    if ((APPLY)); then
        "$@"
    else
        printf 'DRY-RUN:'
        printf ' %q' "$@"
        printf '\n'
    fi
}

deploy_file() {
    local src=$1 dst=$2 mode=$3
    [[ -f $src ]] || die "missing source file: $src"
    if [[ -f $dst ]] && cmp -s -- "$src" "$dst"; then
        log "unchanged: $dst"
        return 0
    fi
    if [[ -e $dst ]]; then
        if ((APPLY)); then
            install -d -m 0755 -- "$BACKUP_DIR"
            local b="$BACKUP_DIR/$(printf '%s' "${dst#/}" | tr '/' '_')"
            cp -a -- "$dst" "$b" || die "backup of $dst failed"
            printf '%s -> %s\n' "$dst" "$b" >> "$BACKUP_DIR/MANIFEST"
            log "backed up: $dst -> $b"
        else
            printf 'DRY-RUN: backup %q -> %q\n' "$dst" "$BACKUP_DIR/..."
        fi
    fi
    run install -D -m "$mode" -o root -g root -- "$src" "$dst.vika-tmp"
    run mv -f -- "$dst.vika-tmp" "$dst"
    if ((APPLY)); then
        log "installed: $dst"
    else
        log "would install: $dst"
    fi
}

create_if_missing() {
    local src=$1 dst=$2 mode=$3
    if [[ -e $dst ]]; then
        log "keeping existing: $dst"
        return 0
    fi
    deploy_file "$src" "$dst" "$mode"
}

log "creating directories"
run install -d -m 0755 -- "$ETC_DIR" "$LIB_DIR/lib" "$DOC_DIR" "$BACKUP_ROOT"
run install -d -o vika -g vika -m 0750 -- \
    /home/vika/media \
    /home/vika/media/music \
    /home/vika/media/audiobooks \
    /home/vika/media/usb

if ! id -nG vika 2>/dev/null | tr ' ' '\n' | grep -qx audio; then
    log "adding vika to the audio group"
    run usermod -aG audio vika
else
    log "vika is already in the audio group"
fi

# The GPIO unit (vika-audio-gpio.service) runs as vika and opens
# /dev/gpiochip0 through lgpio; without this group the service exits.
if ! id -nG vika 2>/dev/null | tr ' ' '\n' | grep -qx gpio; then
    log "adding vika to the gpio group"
    run usermod -aG gpio vika
else
    log "vika is already in the gpio group"
fi

create_if_missing "$REPO_ROOT/config/vika-audio.env" "$ETC_DIR/vika-audio.env" 0644
# The env file is sourced by usb-media.sh (root). Whatever created it earlier,
# ownership must stay root:root, world-readable, not user-writable.
run chown root:root -- "$ETC_DIR/vika-audio.env"
run chmod 0644 -- "$ETC_DIR/vika-audio.env"
deploy_file "$REPO_ROOT/config/mpd.conf" "$ETC_DIR/mpd.conf" 0644
deploy_file "$REPO_ROOT/scripts/lib/media-lib.sh" "$LIB_DIR/lib/media-lib.sh" 0644
deploy_file "$REPO_ROOT/scripts/play-source.sh" "$LIB_DIR/play-source.sh" 0755
deploy_file "$REPO_ROOT/scripts/boot-play.sh" "$LIB_DIR/boot-play.sh" 0755
deploy_file "$REPO_ROOT/scripts/usb-media.sh" "$LIB_DIR/usb-media.sh" 0755
deploy_file "$REPO_ROOT/scripts/verify.sh" "/usr/local/sbin/vika-audio-verify" 0755
deploy_file "$REPO_ROOT/scripts/gpio-controls.py" "$LIB_DIR/gpio-controls.py" 0755
deploy_file "$REPO_ROOT/docs/MPD_DEPLOY.md" "$DOC_DIR/MPD_DEPLOY.md" 0644
deploy_file "$REPO_ROOT/docs/GPIO.md" "$DOC_DIR/GPIO.md" 0644
deploy_file "$REPO_ROOT/docs/BLUETOOTH.md" "$DOC_DIR/BLUETOOTH.md" 0644

deploy_file "$REPO_ROOT/systemd/vika-audio.service" "$UNIT_DIR/vika-audio.service" 0644
deploy_file "$REPO_ROOT/systemd/vika-audio-gpio.service" "$UNIT_DIR/vika-audio-gpio.service" 0644
if ((WITH_BLUETOOTH)); then
    deploy_file "$REPO_ROOT/scripts/avrcp-mpd.py" "$LIB_DIR/avrcp-mpd.py" 0755
    deploy_file "$REPO_ROOT/scripts/avrcp-keys.py" "$LIB_DIR/avrcp-keys.py" 0755
    deploy_file "$REPO_ROOT/scripts/bt-speaker.sh" "$LIB_DIR/bt-speaker.sh" 0755
    deploy_file "$REPO_ROOT/systemd/vika-avrcp.service" "$UNIT_DIR/vika-avrcp.service" 0644
    deploy_file "$REPO_ROOT/systemd/vika-avrcp-keys.service" "$UNIT_DIR/vika-avrcp-keys.service" 0644
    deploy_file "$REPO_ROOT/systemd/vika-bt-speaker.service" "$UNIT_DIR/vika-bt-speaker.service" 0644
else
    log "AVRCP bridge not installed (--no-bluetooth)"
fi
if ((WITH_USB_AUTOMOUNT)); then
    deploy_file "$REPO_ROOT/systemd/vika-audio-usb.service" "$UNIT_DIR/vika-audio-usb.service" 0644
    deploy_file "$REPO_ROOT/systemd/vika-audio-usb.timer" "$UNIT_DIR/vika-audio-usb.timer" 0644
    deploy_file "$REPO_ROOT/systemd/99-vika-audio-usb.rules" "$UDEV_DIR/99-vika-audio-usb.rules" 0644
else
    log "USB automount units not installed (--no-usb-automount)"
fi

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------
# Debian's stock MPD owns /var/lib/mpd and TCP port 6600. It must not run next
# to this player. Disable rather than mask, so it can be restored by hand.
for unit in mpd.service mpd.socket; do
    if systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q .; then
        if systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null; then
            log "disabling stock $unit (reversible: systemctl enable --now $unit)"
            run systemctl disable --now "$unit"
        fi
    fi
done

run systemctl daemon-reload
run systemctl enable --now vika-audio.service
run systemctl enable --now vika-audio-gpio.service
if ((WITH_BLUETOOTH)); then
    # BlueZ allows a single registered media player; stop the desktop proxy
    # if a user session brought it up, otherwise our bridge is ignored.
    run systemctl --global disable mpris-proxy.service >/dev/null 2>&1 || true
    # Both read the same AVRCP commands: BlueZ consults a registered MPRIS
    # player before falling back to uinput, so only one may be active.
    run systemctl disable --now vika-avrcp.service >/dev/null 2>&1 || true
    run systemctl enable --now vika-avrcp-keys.service
fi
if ((WITH_USB_AUTOMOUNT)); then
    run systemctl enable --now vika-audio-usb.timer
    run systemctl start vika-audio-usb.service
    if command -v udevadm >/dev/null 2>&1; then
        run udevadm control --reload-rules
    fi
fi

log "done"
printf '\nNext steps:\n'
printf '  1. Check state as the service user:\n'
printf '       sudo -u vika /usr/local/sbin/vika-audio-verify\n'
printf '  2. Optional audible test on the analog jack:\n'
printf '       sudo -u vika /usr/local/sbin/vika-audio-verify --audio-test\n'
printf '  3. Logs:\n'
printf '       journalctl -u vika-audio -b --no-pager\n'
printf '       journalctl -u vika-audio-usb -b --no-pager\n'
if [[ -d $BACKUP_DIR ]]; then
    printf '  4. Backups of replaced files: %s\n' "$BACKUP_DIR"
fi
printf '\nRollback:\n'
printf '  sudo systemctl disable --now vika-audio-usb.timer vika-audio.service\n'
printf '  sudo systemctl disable --now vika-audio-usb.service 2>/dev/null || true\n'
printf '  restore files from %s (see MANIFEST), then: sudo systemctl daemon-reload\n' "$BACKUP_ROOT"
printf '  stock player: sudo systemctl enable --now mpd.service\n'
