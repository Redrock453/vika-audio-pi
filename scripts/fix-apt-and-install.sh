#!/usr/bin/env bash
# Fix Raspberry Pi's Raspbian mirror redirect issue and continue installing Vika MPD.
# Operates only on the Pi's Raspbian APT source, with a timestamped backup.
set -Eeuo pipefail

if (( EUID != 0 )); then
    echo "Run with sudo: sudo bash /home/vika/vika-audio-pi/scripts/fix-apt-and-install.sh" >&2
    exit 2
fi

source_file=/etc/apt/sources.list.d/raspbian.sources
old_uri=http://raspbian.raspberrypi.com/raspbian/
new_uri=https://archive.raspbian.org/raspbian/
backup_dir=/var/backups/vika-audio/apt-sources

[[ -f "$source_file" ]] || { echo "Missing $source_file" >&2; exit 3; }
if grep -Fq "$old_uri" "$source_file"; then
    mkdir -p "$backup_dir"
    snapshot="$backup_dir/raspbian.sources.$(date +%Y%m%d-%H%M%S)"
    cp -a "$source_file" "$snapshot"
    sed -i "s|$old_uri|$new_uri|g" "$source_file"
    echo "APT mirror updated: $new_uri"
    echo "Original backed up: $snapshot"
elif grep -Fq "$new_uri" "$source_file"; then
    echo "APT mirror is already set to $new_uri"
else
    echo "Unexpected Raspbian repository URI. Not changing it; check $source_file" >&2
    exit 4
fi

echo "Refreshing APT package metadata from the direct HTTPS archive..."
apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 update

echo "Installing and enabling Vika Audio MPD..."
cd /home/vika/vika-audio-pi
exec bash scripts/install.sh --apply
