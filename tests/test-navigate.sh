#!/usr/bin/env bash
#
# Tests for window navigation, the picker flow and the TPM entry point.
# Everything runs on a private tmux server (tmux -L with its own TMUX_TMPDIR),
# with a stub `claude` and a dummy Claude config directory.

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TMP=$(make_tmp)
TMP=$(cd -P "$TMP" && pwd -P)
export TMUX_TMPDIR="$TMP/tmux"
mkdir -p "$TMUX_TMPDIR"
SOCKET_NAME=cjtest

tm() {
  tmux -L "$SOCKET_NAME" "$@"
}

cleanup() {
  tm kill-server 2>/dev/null
  pkill -f "tail -f $TMP/keys-" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# Stub claude: records its working directory and arguments, then exits.
mkdir -p "$TMP/bin" "$TMP/fzf-bin"
export CJ_TEST_CLAUDE_LOG="$TMP/claude.log"
cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
printf '%s|%s\n' "$(pwd -P)" "$*" >>"$CJ_TEST_CLAUDE_LOG"
EOF
# Stub fzf for the picker flow: picks the line containing $CJ_TEST_PICK and
# reports $CJ_TEST_KEY as the key pressed, or exits with $CJ_TEST_FZF_EXIT.
cat >"$TMP/fzf-bin/fzf" <<'EOF'
#!/bin/sh
if [ -n "${CJ_TEST_FZF_EXIT:-}" ]; then
  cat >/dev/null
  exit "$CJ_TEST_FZF_EXIT"
fi
line=$(grep -F -- "$CJ_TEST_PICK" | head -n 1)
printf '%s\n%s\n' "${CJ_TEST_KEY:-}" "$line"
EOF
chmod +x "$TMP/bin/claude" "$TMP/fzf-bin/fzf"
export PATH="$TMP/bin:$PATH"

PROJ="$TMP/projects"
ALPHA="$PROJ/alpha"
SPECIAL="$PROJ/dir with spaces #1 $WIDE_CHAR"
mkdir -p "$ALPHA/sub" "$PROJ/alpha-other" "$PROJ/beta" "$PROJ/base" "$SPECIAL"
ln -s "$ALPHA" "$TMP/alpha-link"

SID_ALPHA=11111111-0000-4000-8000-000000000001
SID_BETA=22222222-0000-4000-8000-000000000002
SID_GONE=33333333-0000-4000-8000-000000000003
SID_SPECIAL=44444444-0000-4000-8000-000000000004

export CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/encoded"
for sid in "$SID_ALPHA" "$SID_BETA" "$SID_SPECIAL"; do
  : >"$CLAUDE_CONFIG_DIR/projects/encoded/$sid.jsonl"
done
{
  printf '{"display":"alpha work","timestamp":4000,"project":"%s","sessionId":"%s"}\n' "$ALPHA" "$SID_ALPHA"
  printf '{"display":"beta work","timestamp":3000,"project":"%s","sessionId":"%s"}\n' "$PROJ/beta" "$SID_BETA"
  printf '{"display":"deleted conversation","timestamp":2000,"project":"%s","sessionId":"%s"}\n' "$PROJ/alpha-other" "$SID_GONE"
  printf '{"display":"special path","timestamp":1000,"project":"%s","sessionId":"%s"}\n' "$SPECIAL" "$SID_SPECIAL"
  printf '{"display":"missing dir","timestamp":500,"project":"%s","sessionId":"%s"}\n' "$PROJ/removed" "$SID_ALPHA"
} >"$CLAUDE_CONFIG_DIR/history.jsonl"

# Start the private server; plugin scripts reach it through $TMUX.
tm -f /dev/null new-session -d -s main -x 200 -y 50 -c "$PROJ/base"
tm set-option -g default-shell /bin/sh
tm set-option -g base-index 0
TMUX="$(tm display-message -p '#{socket_path}'),0,0"
export TMUX
case "$TMUX" in
  "$TMUX_TMPDIR"/*) ;;
  *)
    printf 'refusing to run: unexpected tmux socket %s\n' "$TMUX" >&2
    exit 1
    ;;
esac

nav() {
  "$TEST_BASH" "$SCRIPTS_DIR/navigate.sh" "$@"
}

# pick KEY TEXT: run the picker flow with the stub fzf.
pick() {
  CJ_TEST_KEY=$1 CJ_TEST_PICK=$2 PATH="$TMP/fzf-bin:$PATH" \
    "$TEST_BASH" "$SCRIPTS_DIR/jump.sh" --select "" "$3"
}

new_session() {
  tm new-session -d -s "$1" -x 200 -y 50 -c "$PROJ/base" -P -F '#{session_id}'
}

add_window() {
  local session=$1 dir=$2
  shift 2
  tm new-window -d -t "${session}:" -c "$dir" -P -F '#{window_id}' "$@"
}

active_window() {
  tm display-message -p -t "$1" '#{window_id}'
}

window_list() {
  tm list-windows -t "$1" -F '#{window_id}' | tr '\n' ' '
}

window_count() {
  tm list-windows -t "$1" | wc -l | tr -d ' '
}

window_option() {
  tm show-options -wqv -t "$1" "$2"
}

pane_path() {
  tm display-message -p -t "$1" '#{pane_current_path}'
}

pane_command() {
  tm display-message -p -t "$1" '#{pane_current_command}'
}

claude_calls() {
  [ -f "$CJ_TEST_CLAUDE_LOG" ] && cat "$CJ_TEST_CLAUDE_LOG"
}

file_exists() {
  [ -e "$1" ]
}

log_has_lines() {
  [ -f "$CJ_TEST_CLAUDE_LOG" ] && [ "$(wc -l <"$CJ_TEST_CLAUDE_LOG" | tr -d ' ')" -ge "$1" ]
}

test_case "switches to an existing window of the project"
S=$(new_session t-existing)
BASE=$(active_window "$S")
W=$(add_window "$S" "$ALPHA")
assert_eq "find returns the project window" "$W" "$(nav find "$S" "$ALPHA")"
nav focus "$S" "$W"
assert_eq "window is focused" "$W" "$(active_window "$S")"
assert_ne "focus changed the window" "$BASE" "$(active_window "$S")"

test_case "creates a window when none exists"
S=$(new_session t-create)
BEFORE=$(window_count "$S")
nav find "$S" "$ALPHA" >/dev/null
assert_eq "find fails when nothing matches" 1 "$?"
W=$(nav open "$S" "$ALPHA")
assert_eq "one window was added" $((BEFORE + 1)) "$(window_count "$S")"
assert_eq "new window is focused" "$W" "$(active_window "$S")"
assert_eq "working directory is the project" "$ALPHA" "$(pane_path "$W")"
assert_eq "window is tagged with the project" "$ALPHA" "$(window_option "$W" @claude_jump_project)"
assert_eq "window is named after the project" "alpha" "$(tm display-message -p -t "$W" '#{window_name}')"
assert_eq "shell window has no session tag" "" "$(window_option "$W" @claude_jump_session)"
assert_eq "claude is not started without a session" "" "$(claude_calls)"

test_case "does not select windows of other projects"
S=$(new_session t-other)
add_window "$S" "$ALPHA/sub" >/dev/null
add_window "$S" "$PROJ/alpha-other" >/dev/null
add_window "$S" "$PROJ/beta" -n alpha >/dev/null
nav find "$S" "$ALPHA" >/dev/null
assert_eq "child, sibling and same-named windows do not match" 1 "$?"
S2=$(new_session t-other-session)
add_window "$S2" "$ALPHA" >/dev/null
nav find "$S" "$ALPHA" >/dev/null
assert_eq "windows in other tmux sessions do not match" 1 "$?"

test_case "sets the project directory for special paths"
S=$(new_session t-special)
W=$(nav open "$S" "$SPECIAL")
assert_eq "path with spaces, wide characters and #" "$SPECIAL" "$(pane_path "$W")"
assert_eq "tag keeps the exact path" "$SPECIAL" "$(window_option "$W" @claude_jump_project)"
assert_eq "window name keeps # and wide characters" "dir with spaces #1 $WIDE_CHAR" "$(tm display-message -p -t "$W" '#{window_name}')"
assert_eq "found again by path" "$W" "$(nav find "$S" "$SPECIAL")"
W2=$(nav open "$S" "$TMP/alpha-link")
assert_eq "symlinked project opens the real directory" "$ALPHA" "$(window_option "$W2" @claude_jump_project)"

test_case "resolves symlinks when matching"
S=$(new_session t-symlink)
W=$(add_window "$S" "$ALPHA")
assert_eq "symlink matches the real directory" "$W" "$(nav find "$S" "$TMP/alpha-link")"
assert_eq "trailing slash matches" "$W" "$(nav find "$S" "$ALPHA/")"

test_case "opens a new window even if one exists (Ctrl-O)"
S=$(new_session t-ctrl-o)
rm -f "$CJ_TEST_CLAUDE_LOG"
EXISTING=$(add_window "$S" "$ALPHA")
BEFORE=$(window_count "$S")
W=$(nav open "$S" "$ALPHA" "$SID_ALPHA")
assert_eq "one window was added" $((BEFORE + 1)) "$(window_count "$S")"
assert_ne "it is a different window" "$EXISTING" "$W"
wait_until log_has_lines 1
assert_eq "claude resumes the session in the project" "$ALPHA|--resume $SID_ALPHA" "$(claude_calls)"
assert_eq "window is tagged with the session" "$SID_ALPHA" "$(window_option "$W" @claude_jump_session)"
# Typing into the window this test created proves a shell took over.
tm send-keys -t "$W" "pwd -P > $(printf '%q' "$TMP/shell-alive")" Enter
if wait_until file_exists "$TMP/shell-alive"; then
  pass "window keeps a working shell after claude exits"
else
  fail "window keeps a working shell after claude exits" "command: $(pane_command "$W")"
fi
assert_eq "shell runs in the project" "$ALPHA" "$(cat "$TMP/shell-alive" 2>/dev/null)"
assert_eq "shell runs in the project" "$ALPHA" "$(pane_path "$W")"

test_case "tracks windows by ID when indexes change"
S=$(new_session t-ids)
add_window "$S" "$PROJ/beta" >/dev/null
W=$(add_window "$S" "$ALPHA")
tm move-window -s "$W" -t "${S}:9"
assert_eq "found after move-window" "$W" "$(nav find "$S" "$ALPHA")"
tm move-window -r -t "$S"
assert_eq "found after renumbering" "$W" "$(nav find "$S" "$ALPHA")"
tm rename-window -t "$W" renamed
assert_eq "found after renaming" "$W" "$(nav find "$S" "$ALPHA")"

test_case "chooses deterministically among windows of the same project"
S=$(new_session t-multi)
W1=$(add_window "$S" "$ALPHA")
W2=$(add_window "$S" "$ALPHA")
assert_eq "lowest index when none is current" "$W1" "$(nav find "$S" "$ALPHA")"
tm select-window -t "$W2"
assert_eq "current window wins" "$W2" "$(nav find "$S" "$ALPHA")"
tm select-window -t "${S}:0"
W3=$(nav open "$S" "$ALPHA")
tm select-window -t "${S}:0"
assert_eq "plugin-managed window has priority" "$W3" "$(nav find "$S" "$ALPHA")"
tm send-keys -t "$W3" "cd $(printf '%q' "$PROJ/beta")" Enter
wait_until [ "$(pane_path "$W3")" = "$PROJ/beta" ]
assert_eq "managed window still matches after cd" "$W3" "$(nav find "$S" "$ALPHA")"

test_case "never sends input to an existing pane"
S=$(new_session t-input)
: >"$TMP/input.log"
# shellcheck disable=SC2016  # $1 is expanded by the inner sh
W=$(add_window "$S" "$ALPHA" -- sh -c 'exec cat >"$1"' sh "$TMP/input.log")
rm -f "$CJ_TEST_CLAUDE_LOG"
pick "" "$SID_ALPHA" "$S"
assert_eq "existing window is focused" "$W" "$(active_window "$S")"
assert_eq "no window was added" 2 "$(window_count "$S")"
sleep 0.3
assert_eq "pane received no input" "" "$(cat "$TMP/input.log")"
assert_eq "pane process is still running" "cat" "$(pane_command "$W")"
assert_eq "claude was not resumed" "" "$(claude_calls)"

test_case "cancelling the picker changes nothing"
S=$(new_session t-cancel)
add_window "$S" "$ALPHA" >/dev/null
BEFORE_LIST=$(window_list "$S")
BEFORE_ACTIVE=$(active_window "$S")
for code in 130 1; do
  CJ_TEST_FZF_EXIT=$code PATH="$TMP/fzf-bin:$PATH" "$TEST_BASH" "$SCRIPTS_DIR/jump.sh" --select "" "$S"
  assert_eq "exit status after fzf exit $code" 0 "$?"
  assert_eq "windows unchanged after fzf exit $code" "$BEFORE_LIST" "$(window_list "$S")"
  assert_eq "focus unchanged after fzf exit $code" "$BEFORE_ACTIVE" "$(active_window "$S")"
done

test_case "Enter resumes the session in a new window when none exists"
S=$(new_session t-enter-new)
rm -f "$CJ_TEST_CLAUDE_LOG"
pick "" "$SID_BETA" "$S"
W=$(active_window "$S")
assert_eq "new window in the project" "$PROJ/beta" "$(window_option "$W" @claude_jump_project)"
wait_until log_has_lines 1
assert_eq "claude resumed" "$PROJ/beta|--resume $SID_BETA" "$(claude_calls)"

test_case "@claude-jump-new-window-action shell opens only a shell"
S=$(new_session t-shell)
rm -f "$CJ_TEST_CLAUDE_LOG"
tm set-option -g @claude-jump-new-window-action shell
pick "" "$SID_BETA" "$S"
W=$(active_window "$S")
tm set-option -gu @claude-jump-new-window-action
assert_eq "new window in the project" "$PROJ/beta" "$(window_option "$W" @claude_jump_project)"
sleep 0.3
assert_eq "claude not started" "" "$(claude_calls)"
rm -f "$CJ_TEST_CLAUDE_LOG"
pick ctrl-o "$SID_BETA" "$S" 2>/dev/null
tm set-option -gu @claude-jump-new-window-action
wait_until log_has_lines 1
assert_eq "Ctrl-O still resumes" "$PROJ/beta|--resume $SID_BETA" "$(claude_calls)"

test_case "handles deleted conversations and missing directories"
S=$(new_session t-missing)
rm -f "$CJ_TEST_CLAUDE_LOG"
BEFORE=$(window_count "$S")
OUT=$(pick ctrl-o "$SID_GONE" "$S" 2>&1)
assert_eq "Ctrl-O on a deleted conversation adds no window" "$BEFORE" "$(window_count "$S")"
assert_contains "Ctrl-O reports it" "no longer exists; cannot resume" "$OUT"
OUT=$(pick "" "$SID_GONE" "$S" 2>&1)
W=$(active_window "$S")
assert_eq "Enter falls back to a shell window" "$PROJ/alpha-other" "$(window_option "$W" @claude_jump_project)"
assert_contains "Enter reports it" "opened a shell instead" "$OUT"
sleep 0.3
assert_eq "claude not started for a deleted conversation" "" "$(claude_calls)"
BEFORE=$(window_count "$S")
OUT=$(pick "" "$PROJ/removed" "$S" 2>&1)
assert_eq "missing directory adds no window" "$BEFORE" "$(window_count "$S")"
assert_contains "missing directory is reported" "project directory not found" "$OUT"
OUT=$(nav open "$S" "$PROJ/removed" 2>&1)
assert_eq "navigate open refuses a missing directory" 1 "$?"
assert_eq "still no window added" "$BEFORE" "$(window_count "$S")"

test_case "rejects invalid arguments"
nav find "not-an-id" "$ALPHA" 2>/dev/null
assert_eq "invalid tmux session ID" 2 "$?"
nav open "$S" "$ALPHA" 'x; rm -rf /' 2>/dev/null
assert_eq "invalid Claude session ID" 1 "$?"
assert_eq "no window added for invalid ID" "$BEFORE" "$(window_count "$S")"

test_case "TPM entry point binds the key"
"$TEST_BASH" "$ROOT_DIR/claude-jump.tmux"
BINDING=$(tm list-keys -T prefix y 2>/dev/null)
assert_contains "default key runs jump.sh" "$SCRIPTS_DIR/jump.sh" "$BINDING"
assert_contains "passes the client" "#{client_name}" "$BINDING"
assert_contains "runs in the background" "run-shell -b" "$BINDING"
tm set-option -g @claude-jump-key C-j
"$TEST_BASH" "$ROOT_DIR/claude-jump.tmux"
assert_contains "custom key is bound" "jump.sh" "$(tm list-keys -T prefix C-j 2>/dev/null)"
tm set-option -gu @claude-jump-key
tm unbind-key -T prefix C-j

# End-to-end: a real client presses prefix + y and drives fzf in the popup.
# `send-keys -K` does not reach popups, so keystrokes are written to a file
# that is streamed into the client's terminal through script(1).
attach_client() {
  : >"$TMP/keys-$1"
  (tail -f "$TMP/keys-$1" | TERM=xterm-256color script -q /dev/null \
    tmux -L "$SOCKET_NAME" attach -t "$1" >/dev/null 2>&1 &)
}

# type_keys SESSION BYTES: types BYTES on the client attached to SESSION.
type_keys() {
  printf "%b" "$2" >>"$TMP/keys-$1"
}

client_session() {
  tm list-clients -F "#{client_name}	#{session_id}" | awk -F "\t" -v c="$1" '$1 == c {print $2}'
}

client_of() {
  tm list-clients -t "$1" -F '#{client_name}' | head -n 1
}

has_client() {
  [ -n "$(client_of "$1")" ]
}

active_is() {
  [ "$(active_window "$1")" = "$2" ]
}

test_case "end to end: popup on the pressing client only"
if ! command -v script >/dev/null 2>&1 || ! command -v fzf >/dev/null 2>&1; then
  skip "script(1) or fzf not available"
else
  "$TEST_BASH" "$ROOT_DIR/claude-jump.tmux"
  E1=$(new_session t-e2e-1)
  E2=$(new_session t-e2e-2)
  TARGET=$(add_window "$E1" "$PROJ/beta")
  E2_ACTIVE=$(active_window "$E2")
  attach_client "$E1"
  attach_client "$E2"
  if wait_until has_client "$E1" && wait_until has_client "$E2"; then
    C2=$(client_of "$E2")
    type_keys "$E1" "\002y"
    sleep 1.5
    type_keys "$E1" "beta work"
    sleep 0.5
    type_keys "$E1" "\r"
    if wait_until active_is "$E1" "$TARGET"; then
      pass "Enter in the popup focuses the project window"
    else
      fail "Enter in the popup focuses the project window" "active: $(active_window "$E1")"
    fi
    assert_eq "other client's session is untouched" "$E2_ACTIVE" "$(active_window "$E2")"
    assert_eq "other client stays on its session" "$E2" \
      "$(client_session "$C2")"
    BEFORE=$(window_count "$E1")
    type_keys "$E1" "\002y"
    sleep 1.5
    type_keys "$E1" "\033"
    sleep 1
    assert_eq "Esc in the popup adds no window" "$BEFORE" "$(window_count "$E1")"
    assert_eq "Esc in the popup keeps focus" "$TARGET" "$(active_window "$E1")"
    rm -f "$CJ_TEST_CLAUDE_LOG"
    type_keys "$E1" "\002y"
    sleep 1.5
    type_keys "$E1" "beta work"
    sleep 0.5
    type_keys "$E1" "\017"
    wait_until log_has_lines 1
    assert_eq "Ctrl-O in the popup opens another window" $((BEFORE + 1)) "$(window_count "$E1")"
    assert_eq "Ctrl-O in the popup resumes the session" "$PROJ/beta|--resume $SID_BETA" "$(claude_calls)"
    tm detach-client -s "$E1" 2>/dev/null
    tm detach-client -s "$E2" 2>/dev/null
  else
    skip "could not attach a client through script(1)"
  fi
fi

finish
