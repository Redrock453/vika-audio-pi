#!/usr/bin/env bash
# Safety tests for scripts/install.sh: dry-run by default, refusal of --apply
# as a non-root user, and the presence of idempotent backup logic. Nothing here
# installs anything or writes outside a temporary directory.
set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
# shellcheck source=lib/helpers.sh
. "$TEST_DIR/lib/helpers.sh"

printf '\n[test-installer]\n'

installer="$REPO_ROOT/scripts/install.sh"

# --- --check on a non-target host -----------------------------------------
out=$("$installer" --check --force 2>&1)
t_rc "--check --force exits 0" 0 $?
t_contains "--check reports completion" "checks finished" "$out"

# --- dry-run must print a plan and change nothing -------------------------
out=$("$installer" --force --no-apt 2>&1)
t_rc "dry-run exits 0" 0 $?
t_contains "dry-run is announced" "DRY RUN" "$out"
if [[ $out == *"would install: /etc/vika-audio/mpd.conf"* || $out == *"unchanged: /etc/vika-audio/mpd.conf"* ]]; then
    t_pass "dry-run handles the MPD config"
else
    t_fail "dry-run handles the MPD config"
fi
if [[ $out == *"would install: /etc/systemd/system/vika-audio.service"* || $out == *"unchanged: /etc/systemd/system/vika-audio.service"* ]]; then
    t_pass "dry-run handles the service unit"
else
    t_fail "dry-run handles the service unit"
fi
t_contains "would reload systemd" "systemctl enable --now vika-audio.service" "$out"
if [[ $out == *"DRY-RUN: apt-get"* ]]; then
    t_fail "dry-run must not install packages"
else
    t_pass "dry-run must not install packages"
fi

# --- --apply as non-root must fail before doing anything ------------------
if ((EUID != 0)); then
    out=$("$installer" --apply 2>&1)
    t_rc "--apply as non-root exits 1" 1 $?
    t_contains "explains the sudo requirement" "must run as root" "$out"
else
    t_skip "--apply refusal (test runs as root)"
fi

# --- idempotent backup logic is present ----------------------------------
script=$(cat "$installer")
t_contains "backups include a manifest" "MANIFEST" "$script"
t_contains "unchanged files are skipped" 'unchanged: $dst' "$script"
t_contains "environment file is never overwritten" 'keeping existing: $dst' "$script"

t_end
