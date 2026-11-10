# shellcheck shell=bash disable=SC2034  # variables are used by the sourcing tests
#
# Minimal test helpers shared by the test scripts.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"
FIXTURES_DIR="$TESTS_DIR/fixtures"

# Run the plugin scripts with this bash (e.g. TEST_BASH=/bin/bash for 3.2).
TEST_BASH=${TEST_BASH:-$(command -v bash)}

PASSED=0
FAILED=0
SKIPPED=0
CURRENT_TEST=""

# Never talk to the tmux server the tests are started from.
unset TMUX TMUX_PANE

test_case() {
  CURRENT_TEST=$1
  printf '\n# %s\n' "$1"
}

pass() {
  PASSED=$((PASSED + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf '  FAIL  %s (in: %s)\n' "$1" "$CURRENT_TEST"
  if [ $# -gt 1 ]; then
    printf '        %s\n' "${@:2}"
  fi
}

skip() {
  SKIPPED=$((SKIPPED + 1))
  printf '  skip  %s\n' "$1"
}

assert_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected: [$2]" "actual:   [$3]"
  fi
}

assert_ne() {
  if [ "$2" != "$3" ]; then
    pass "$1"
  else
    fail "$1" "did not expect: [$2]"
  fi
}

assert_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to contain: [$2]" "actual: [$3]" ;;
  esac
}

assert_not_contains() {
  case "$3" in
    *"$2"*) fail "$1" "expected not to contain: [$2]" "actual: [$3]" ;;
    *) pass "$1" ;;
  esac
}

# make_tmp: a temporary directory short enough to hold tmux sockets
# (Unix socket paths are limited to about 104 bytes on macOS).
make_tmp() {
  local base=${TMPDIR:-/tmp}
  base=${base%/}
  [ "${#base}" -le 60 ] || base=/tmp
  mktemp -d "$base/cj.XXXXXX"
}

# wait_until COMMAND...: polls COMMAND for up to about 5 seconds.
wait_until() {
  local i=0
  while [ "$i" -lt 50 ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

finish() {
  printf '\n%d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
  [ "$FAILED" -eq 0 ]
}
