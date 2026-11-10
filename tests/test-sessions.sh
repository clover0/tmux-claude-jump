#!/usr/bin/env bash
#
# Tests for scripts/sessions.sh using the dummy history in tests/fixtures.

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

export TZ=UTC
TMP=$(make_tmp)
trap 'rm -rf "$TMP"' EXIT

CONFIG="$TMP/claude"
mkdir -p "$CONFIG"
cp "$FIXTURES_DIR/history.jsonl" "$CONFIG/history.jsonl"

SID_A=aaaaaaaa-0000-4000-8000-000000000001
SID_B=bbbbbbbb-0000-4000-8000-000000000002
SID_C=cccccccc-0000-4000-8000-000000000003
SID_D=dddddddd-0000-4000-8000-000000000004
SID_F=ffffffff-0000-4000-8000-000000000006

sessions() {
  CLAUDE_CONFIG_DIR=$CONFIG "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" "$@"
}

# The same field layout and options the picker uses, without the UI.
search() {
  printf '%s\n' "$1" | fzf --filter "$2" --exact --tiebreak index --delimiter "$(printf '\t')" --with-nth 3..
}

field() {
  printf '%s\n' "$1" | cut -f "$2"
}

LIST=$(sessions list)
STATUS=$?

test_case "reads sessions from valid JSONL"
assert_eq "exit status" 0 "$STATUS"
assert_eq "number of sessions" 6 "$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')"
assert_eq "every line has three tab-separated fields" "" \
  "$(printf '%s\n' "$LIST" | awk -F '\t' 'NF != 3')"

test_case "aggregates entries of the same session"
ROW_A=$(printf '%s\n' "$LIST" | awk -F '\t' -v s="$SID_A" '$1 == s && $2 == "/work/my-app"')
assert_eq "one row for project + session" 1 "$(printf '%s\n' "$ROW_A" | wc -l | tr -d ' ')"
assert_contains "all prompts are searchable" "認証機能のリファクタリング | /login | JWTの有効期限も見直して" "$ROW_A"
assert_contains "first non-command prompt is the title" "my-app                認証機能のリファクタリング" "$ROW_A"
assert_contains "shows the latest timestamp" "11/10 14:30" "$ROW_A"
assert_eq "same session ID in another project is kept apart" "/work/other" \
  "$(printf '%s\n' "$LIST" | awk -F '\t' -v s="$SID_A" '$1 == s && $2 != "/work/my-app" {print $2}')"
assert_eq "trailing slash in project is normalized" "/work/my-app" \
  "$(printf '%s\n' "$LIST" | awk -F '\t' -v s="$SID_C" '$1 == s {print $2}')"
ROW_F=$(printf '%s\n' "$LIST" | awk -F '\t' -v s="$SID_F" '$1 == s')
assert_contains "command-only session falls back to the command" "website               /clear" "$ROW_F"

test_case "orders sessions by last update, newest first"
assert_eq "session order" "$SID_A $SID_B $SID_C $SID_D $SID_A $SID_F" \
  "$(printf '%s\n' "$LIST" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"

test_case "searches across projects"
assert_eq "by prompt" "$SID_B" "$(field "$(search "$LIST" "エラーハンドリング")" 1)"
assert_eq "by a later prompt of a session" "$SID_A" "$(field "$(search "$LIST" "JWT")" 1)"
assert_eq "by project name" "$SID_A $SID_C" \
  "$(search "$LIST" "my-app" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "by absolute path" "$SID_D" "$(field "$(search "$LIST" "/work/My Project/space")" 1)"
assert_eq "by session ID" "$SID_F" "$(field "$(search "$LIST" "ffffffff-0000")" 1)"

test_case "skips malformed and unusable lines"
for bad in /work/legacy /work/evil /work/bad-ts work/relative "../../etc/passwd"; do
  assert_not_contains "skips $bad" "$bad" "$LIST"
done
BROKEN="$TMP/broken"
mkdir -p "$BROKEN"
{
  printf '\x00\x01garbage\n'
  printf '{"display":"ok","timestamp":1,"project":"/p","sessionId":"s1"}\n'
  printf '{"display":"truncated","timestamp":2,"project":"/p",\n'
} >"$BROKEN/history.jsonl"
assert_eq "valid line between broken ones is read" "s1" \
  "$(CLAUDE_CONFIG_DIR=$BROKEN "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list | cut -f1)"

test_case "handles Japanese, whitespace and special characters in prompts"
ROW_D=$(printf '%s\n' "$LIST" | awk -F '\t' -v s="$SID_D" '$1 == s')
assert_contains "newline, tab and control characters become spaces" "line1 line2 TAB ctl" "$ROW_D"
# shellcheck disable=SC2016  # literal shell syntax is the point
assert_contains "shell syntax is kept as plain text" '$(touch /tmp/cj-pwned) `id`; rm -rf ~' "$ROW_D"
assert_contains "Japanese text is kept" "日本語　全角" "$ROW_D"
assert_eq "no control characters in output" "" "$(printf '%s\n' "$LIST" | tr -d '\t\n' | LC_ALL=C tr -d '\040-\176\200-\377')"
if [ -e /tmp/cj-pwned ]; then
  fail "prompt text must never be executed"
else
  pass "prompt text is never executed"
fi
LONG="$TMP/long"
LONG_PROMPT=""
for _ in 1 2 3 4 5 6 7 8 9 10; do LONG_PROMPT="${LONG_PROMPT}長い長い長い長い長い"; done
mkdir -p "$LONG"
printf '{"display":"%s","timestamp":1,"project":"/p","sessionId":"long-1"}\n' "$LONG_PROMPT" >"$LONG/history.jsonl"
LONG_ROW=$(CLAUDE_CONFIG_DIR=$LONG "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list)
assert_contains "long titles are truncated to the column width" "長…  " "$LONG_ROW"
assert_contains "the full prompt stays searchable" "$LONG_PROMPT" "$LONG_ROW"

test_case "handles project paths with spaces"
assert_eq "project path" "/work/My Project/space dir" "$(field "$ROW_D" 2)"
assert_contains "project name is the last path component" "space dir" "$(field "$ROW_D" 3 | cut -c1-40)"

test_case "reports an empty or missing history"
EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
: >"$EMPTY/history.jsonl"
OUT=$(CLAUDE_CONFIG_DIR=$EMPTY "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list 2>&1)
assert_eq "empty history fails" 1 "$?"
assert_contains "empty history message" "No Claude Code sessions found" "$OUT"
printf '{not json\n[]\n' >"$EMPTY/history.jsonl"
OUT=$(CLAUDE_CONFIG_DIR=$EMPTY "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list 2>&1)
assert_contains "history without valid entries" "No Claude Code sessions found" "$OUT"
OUT=$(CLAUDE_CONFIG_DIR=$TMP/nowhere "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list 2>&1)
assert_eq "missing history fails" 1 "$?"
assert_contains "missing history message" "history not found: $TMP/nowhere/history.jsonl" "$OUT"

test_case "honors CLAUDE_CONFIG_DIR"
OTHER="$TMP/other-config"
mkdir -p "$OTHER"
printf '{"display":"from other config","timestamp":5,"project":"/x","sessionId":"other-1"}\n' >"$OTHER/history.jsonl"
assert_eq "reads the configured directory" "other-1" \
  "$(CLAUDE_CONFIG_DIR=$OTHER "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list | cut -f1)"
mkdir -p "$TMP/home/.claude"
cp "$OTHER/history.jsonl" "$TMP/home/.claude/history.jsonl"
assert_eq "falls back to ~/.claude" "other-1" \
  "$(env -u CLAUDE_CONFIG_DIR HOME="$TMP/home" "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list | cut -f1)"

test_case "preview shows the prompts of one session"
PREVIEW=$(sessions preview "$SID_A" /work/my-app)
assert_contains "project" "Project:  /work/my-app" "$PREVIEW"
assert_contains "session" "Session:  $SID_A" "$PREVIEW"
assert_contains "prompt count" "Prompts:  3" "$PREVIEW"
assert_contains "prompts in order" "11/10 12:00  認証機能のリファクタリング" "$PREVIEW"
assert_not_contains "other project with the same ID is excluded" "same id, other project" "$PREVIEW"
assert_contains "warns about a missing directory" "no longer exists" "$PREVIEW"

test_case "detects deleted conversation data"
sessions transcript "$SID_A"
assert_eq "unknown layout without projects/" 2 "$?"
mkdir -p "$CONFIG/projects/-work-my-app"
: >"$CONFIG/projects/-work-my-app/$SID_A.jsonl"
sessions transcript "$SID_A"
assert_eq "existing conversation" 0 "$?"
sessions transcript "$SID_B"
assert_eq "deleted conversation" 1 "$?"
sessions transcript "../-work-my-app/$SID_A"
assert_eq "rejects unsafe session IDs" 1 "$?"

test_case "never modifies the history file"
assert_eq "history unchanged" "$(cksum <"$FIXTURES_DIR/history.jsonl")" "$(cksum <"$CONFIG/history.jsonl")"

finish
