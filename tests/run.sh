#!/usr/bin/env bash
#
# Runs all tests. Set TEST_BASH to run the plugin scripts with another bash,
# for example: TEST_BASH=/bin/bash tests/run.sh

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0

for test in "$TESTS_DIR"/test-*.sh; do
  printf '=== %s\n' "$(basename "$test")"
  bash "$test" || status=1
  printf '\n'
done

if [ "$status" -eq 0 ]; then
  printf 'All tests passed.\n'
else
  printf 'Some tests failed.\n'
fi
exit "$status"
