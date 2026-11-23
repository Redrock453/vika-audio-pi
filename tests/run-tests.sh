#!/usr/bin/env bash
# Run the Vika Audio Pi test suite on any Linux host (for example the T450).
# No root, no MPD, no audio hardware and no network are required.
#
#   ./tests/run-tests.sh
#   VIKA_TEST_STRICT_SHELLCHECK=1 ./tests/run-tests.sh
set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

printf 'Vika Audio Pi test suite\n'
printf 'host: %s (%s), shell: %s\n' "$(uname -n)" "$(uname -m)" "${BASH_VERSION%%(*}"

failed=0
passed=0
declare -a results=()

mapfile -t tests < <(find "$TEST_DIR" -maxdepth 1 -type f -name 'test-*.sh' | LC_ALL=C sort)
if ((${#tests[@]} == 0)); then
    printf 'no tests found in %s\n' "$TEST_DIR" >&2
    exit 1
fi

for t in "${tests[@]}"; do
    name=$(basename -- "$t")
    if bash "$t"; then
        results+=("PASS  $name")
        passed=$((passed + 1))
    else
        results+=("FAIL  $name")
        failed=$((failed + 1))
    fi
done

printf '\n==================== summary ====================\n'
for r in "${results[@]}"; do
    printf '%s\n' "$r"
done
printf 'suites: %d passed, %d failed\n' "$passed" "$failed"

if ((failed > 0)); then
    exit 1
fi
printf 'All tests passed. This does not replace acceptance on the real Pi.\n'
exit 0
