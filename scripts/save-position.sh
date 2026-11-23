#!/usr/bin/env bash
# Vika Audio Pi — remember the current track and position.
#
# boot-play.sh rebuilds the queue at boot and restores it from
# /var/lib/vika-audio/state/<source>.resume. That file used to be written
# only when the source changed, so a reboot lost the position. This script
# is run by a 30-second timer and as ExecStop before MPD stops, keeping the
# resume file fresh even after a power loss.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/media-lib.sh
. "$SCRIPT_DIR/lib/media-lib.sh"

VIKA_LOG_TAG=vika-audio-position
quiet=0
[[ ${1:-} == --quiet ]] && quiet=1

vika_load_env
vika_init_paths

if ! vika_mpd_wait 3; then
    exit 0
fi

src=$(vika_current_source || true)
if [[ -z $src ]]; then
    exit 0
fi

if ((quiet)); then
    vika_save_resume "$src" >/dev/null 2>&1 || true
else
    vika_save_resume "$src" || true
fi
exit 0
