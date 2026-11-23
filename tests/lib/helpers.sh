#!/usr/bin/env bash
# Minimal assertion helpers for tests that must run on a laptop (T450) without
# root, MPD, audio hardware or network access.
set -u

TESTS_FAILED=0
TESTS_PASSED=0

t_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '  PASS  %s\n' "$*"
}

t_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL  %s\n' "$*"
}

t_skip() { printf '  SKIP  %s\n' "$*"; }

t_eq() {
    local desc=$1 want=$2 got=$3
    if [[ $want == "$got" ]]; then
        t_pass "$desc"
    else
        t_fail "$desc"
        printf '        want: %q\n        got:  %q\n' "$want" "$got"
    fi
}

t_contains() {
    local desc=$1 needle=$2 haystack=$3
    if [[ $haystack == *"$needle"* ]]; then
        t_pass "$desc"
    else
        t_fail "$desc (missing: $needle)"
        printf '        output: %s\n' "$haystack"
    fi
}

t_rc() {
    local desc=$1 want=$2 got=$3
    if [[ $want == "$got" ]]; then
        t_pass "$desc"
    else
        t_fail "$desc (rc want $want, got $got)"
    fi
}

t_file_eq() {
    local desc=$1 want_file=$2 got_file=$3
    if diff -u -- "$want_file" "$got_file" >/dev/null 2>&1; then
        t_pass "$desc"
    else
        t_fail "$desc"
        diff -u -- "$want_file" "$got_file" | sed 's/^/        /' || true
    fi
}

t_end() {
    printf '\n  %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
    ((TESTS_FAILED == 0))
}

t_new_tmp() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/vika-audio-test.XXXXXX") || exit 1
    T_TMP=$d
    # shellcheck disable=SC2064
    trap 'rm -rf -- "$T_TMP"' EXIT
    printf '%s\n' "$d"
}

# Creates an empty file with a .mp3-style payload; content is irrelevant.
t_touch() {
    mkdir -p -- "$(dirname -- "$1")"
    printf 'fixture\n' > "$1"
}
