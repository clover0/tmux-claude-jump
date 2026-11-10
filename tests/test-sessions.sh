#!/usr/bin/env bash
#
# Tests for scripts/sessions.sh using the dummy conversation data in
# tests/fixtures/projects.

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

export TZ=UTC
TMP=$(make_tmp)
trap 'rm -rf "$TMP"' EXIT

CONFIG="$TMP/claude"
mkdir -p "$CONFIG"
cp -R "$FIXTURES_DIR/projects" "$CONFIG/projects"

SID_A=aaaaaaaa-0000-4000-8000-000000000001
SID_B=bbbbbbbb-0000-4000-8000-000000000002
SID_C=cccccccc-0000-4000-8000-000000000003
SID_D=dddddddd-0000-4000-8000-000000000004
SID_E=eeeeeeee-0000-4000-8000-000000000005
SID_F=ffffffff-0000-4000-8000-000000000006

# The list is ordered by file modification time (last activity).
set_mtime() {
  touch -t "$2" "$CONFIG/projects/$1"
}
set_mtime "-work-my-app/$SID_A.jsonl" 202411101435
set_mtime "-work-backend/$SID_B.jsonl" 202411101126.40
set_mtime "-work-my-app/$SID_C.jsonl" 202411091100
set_mtime "-work-My-Project-space-dir/$SID_D.jsonl" 202411071720
set_mtime "-work-moved/$SID_E.jsonl" 202411050900
set_mtime "-work-other/$SID_A.jsonl" 202411012226
set_mtime "-work-website/$SID_F.jsonl" 202410270333
set_mtime "-work-empty/99999999-0000-4000-8000-000000000009.jsonl" 202411111111
set_mtime "-work-evil/bad;id.jsonl" 202411111111

checksums() {
  (cd "$CONFIG/projects" && find . -type f -exec cksum {} + | sort)
}
BEFORE_SUMS=$(checksums)

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

row_of() {
  printf '%s\n' "$LIST" | awk -F '\t' -v s="$1" -v p="${2:-}" '$1 == s && (p == "" || $2 == p)'
}

ids() {
  cut -f1 | tr '\n' ' ' | sed 's/ $//'
}

LIST=$(sessions list)
STATUS=$?

test_case "reads sessions from conversation files"
assert_eq "exit status" 0 "$STATUS"
assert_eq "number of sessions" 7 "$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')"
assert_eq "every line has three tab-separated fields" "" \
  "$(printf '%s\n' "$LIST" | awk -F '\t' 'NF != 3')"

test_case "collects the prompts a person typed"
ROW_A=$(row_of "$SID_A" /work/my-app)
assert_eq "one row for the conversation" 1 "$(printf '%s\n' "$ROW_A" | wc -l | tr -d ' ')"
assert_contains "prompts, including slash commands, are searchable" \
  "Refactor the authentication module | /login | Also review the JWT expiry" "$ROW_A"
for excluded in "assistant reply text" "tool output text" "Caveat: injected meta text" \
  "Login successful" "sidechain prompt text" "task notification text" "subagent file prompt"; do
  assert_not_contains "excludes: $excluded" "$excluded" "$LIST"
done

test_case "uses the same title as Claude Code"
assert_contains "custom title wins" "my-app                Authentication refactoring" "$ROW_A"
assert_contains "AI title when there is no custom title" \
  "backend               API error handling" "$(row_of "$SID_B")"
assert_contains "first prompt when there is no title" \
  "my-app                Add test code" "$(row_of "$SID_C")"
assert_contains "a slash command if that is all there is" \
  "website               /clear" "$(row_of "$SID_F")"
assert_contains "shows the last activity time" "11/10 14:35" "$ROW_A"

test_case "derives the project directory claude --resume needs"
assert_eq "directory that matches the storage folder, not the first cwd" "/work/my-app" \
  "$(field "$(row_of "$SID_C")" 2)"
assert_eq "relocated conversation uses the new directory" "/work/moved" \
  "$(field "$(row_of "$SID_E")" 2)"
assert_eq "same session ID in another folder is kept apart" "/work/other" \
  "$(printf '%s\n' "$LIST" | awk -F '\t' -v s="$SID_A" '$1 == s && $2 != "/work/my-app" {print $2}')"

test_case "orders sessions by last activity, newest first"
assert_eq "session order" "$SID_A $SID_B $SID_C $SID_D $SID_E $SID_A $SID_F" \
  "$(printf '%s\n' "$LIST" | ids)"

test_case "searches across projects"
assert_eq "by prompt" "$SID_B" "$(search "$LIST" "error handling" | ids)"
assert_eq "by a later prompt of a session" "$SID_A" "$(search "$LIST" "JWT" | ids)"
assert_eq "by title" "$SID_A" "$(search "$LIST" "Authentication refactoring" | ids)"
assert_eq "by project name" "$SID_A $SID_C" "$(search "$LIST" "my-app" | ids)"
assert_eq "by absolute path" "$SID_D" "$(search "$LIST" "/work/My Project/space" | ids)"
assert_eq "by session ID" "$SID_F" "$(search "$LIST" "ffffffff-0000" | ids)"

test_case "skips malformed and unusable data"
assert_contains "lines after broken JSON are read" "Also review the JWT expiry" "$ROW_A"
assert_not_contains "skips files with unsafe names" "evil prompt" "$LIST"
assert_not_contains "skips sessions without prompts" "/work/empty" "$LIST"
assert_not_contains "ignores files that are not transcripts" "not a transcript" "$LIST"

test_case "handles wide, whitespace and special characters in prompts"
ROW_D=$(row_of "$SID_D")
assert_contains "newline, tab and control characters become spaces" "line1 line2 TAB ctl" "$ROW_D"
# shellcheck disable=SC2016  # literal shell syntax is the point
assert_contains "shell syntax is kept as plain text" '$(touch /tmp/cj-pwned) `id`; rm -rf ~' "$ROW_D"
assert_contains "wide characters are kept" "wide ${WIDE_CHAR}${FULLWIDTH_SPACE}${WIDE_CHAR} chars" "$ROW_D"
assert_eq "no control characters in output" "" \
  "$(printf '%s\n' "$LIST" | tr -d '\t\n' | LC_ALL=C tr -d '\040-\176\200-\377')"
if [ -e /tmp/cj-pwned ]; then
  fail "prompt text must never be executed"
else
  pass "prompt text is never executed"
fi
LONG="$TMP/long"
LONG_PROMPT=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  LONG_PROMPT="${LONG_PROMPT}${WIDE_CHAR}${WIDE_CHAR}${WIDE_CHAR}${WIDE_CHAR}${WIDE_CHAR}${WIDE_CHAR}${WIDE_CHAR}${WIDE_CHAR}${WIDE_CHAR}${WIDE_CHAR}"
done
mkdir -p "$LONG/projects/-p"
printf '{"type":"user","cwd":"/p","timestamp":"2024-11-01T00:00:00.000Z","message":{"content":"%s"}}\n' \
  "$LONG_PROMPT" >"$LONG/projects/-p/long-1.jsonl"
LONG_ROW=$(CLAUDE_CONFIG_DIR=$LONG "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list)
assert_contains "long titles are truncated to the column width" "${WIDE_CHAR}…  " "$LONG_ROW"
assert_contains "the full prompt stays searchable" "$LONG_PROMPT" "$LONG_ROW"

test_case "handles project paths with spaces"
assert_eq "project path" "/work/My Project/space dir" "$(field "$ROW_D" 2)"
assert_contains "project name is the last path component" "space dir" "$(field "$ROW_D" 3 | cut -c1-40)"

test_case "reports missing or empty data"
EMPTY="$TMP/empty"
mkdir -p "$EMPTY/projects"
OUT=$(CLAUDE_CONFIG_DIR=$EMPTY "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list 2>&1)
assert_eq "no conversations fails" 1 "$?"
assert_contains "no conversations message" "No Claude Code sessions found" "$OUT"
mkdir -p "$EMPTY/projects/-x"
printf '{not json\n[]\n' >"$EMPTY/projects/-x/s1.jsonl"
OUT=$(CLAUDE_CONFIG_DIR=$EMPTY "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list 2>&1)
assert_contains "conversations without prompts" "No Claude Code sessions found" "$OUT"
OUT=$(CLAUDE_CONFIG_DIR=$TMP/nowhere "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list 2>&1)
assert_eq "missing data directory fails" 1 "$?"
assert_contains "missing data directory message" "session data not found: $TMP/nowhere/projects" "$OUT"

test_case "honors CLAUDE_CONFIG_DIR"
OTHER="$TMP/other-config"
mkdir -p "$OTHER/projects/-x"
printf '{"type":"user","cwd":"/x","timestamp":"2024-11-01T00:00:00.000Z","message":{"content":"from other config"}}\n' \
  >"$OTHER/projects/-x/other-1.jsonl"
assert_eq "reads the configured directory" "other-1" \
  "$(CLAUDE_CONFIG_DIR=$OTHER "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list | ids)"
mkdir -p "$TMP/home"
cp -R "$OTHER" "$TMP/home/.claude"
assert_eq "falls back to ~/.claude" "other-1" \
  "$(env -u CLAUDE_CONFIG_DIR HOME="$TMP/home" "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" list | ids)"

test_case "preview shows the prompts of one session"
PREVIEW=$(sessions preview "$SID_A" /work/my-app)
assert_contains "title" "Title:    Authentication refactoring" "$PREVIEW"
assert_contains "project" "Project:  /work/my-app" "$PREVIEW"
assert_contains "session" "Session:  $SID_A" "$PREVIEW"
assert_contains "prompt count" "Prompts:  3" "$PREVIEW"
assert_contains "prompts in order" "11/10 12:00  Refactor the authentication module" "$PREVIEW"
assert_not_contains "other folder with the same ID is excluded" "same id, other project" "$PREVIEW"
assert_contains "warns about a missing directory" "no longer exists" "$PREVIEW"
assert_contains "unknown session" "No conversation data found" "$(sessions preview 00000000-dead 2>&1)"

test_case "detects deleted conversation data"
sessions transcript "$SID_A"
assert_eq "existing conversation" 0 "$?"
sessions transcript 00000000-0000-4000-8000-00000000dead
assert_eq "deleted conversation" 1 "$?"
sessions transcript "../-work-my-app/$SID_A"
assert_eq "rejects unsafe session IDs" 1 "$?"
CLAUDE_CONFIG_DIR=$TMP/nowhere "$TEST_BASH" "$SCRIPTS_DIR/sessions.sh" transcript "$SID_A"
assert_eq "unknown without a data directory" 2 "$?"

test_case "never modifies conversation files"
assert_eq "files unchanged" "$BEFORE_SUMS" "$(checksums)"

finish
