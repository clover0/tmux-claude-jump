#!/usr/bin/env bash
#
# Entry point bound to the plugin key.
#
# Usage:
#   jump.sh [CLIENT TMUX_SESSION]
#       Check dependencies and open the picker popup on CLIENT. Without
#       arguments, the client and session running this command are used.
#   jump.sh --select CLIENT TMUX_SESSION
#       Run the picker (inside the popup) and act on the selection.
#
# The key binding passes #{client_name} and #{session_id} explicitly, because
# a popup has no pane of its own and tmux cannot tell which client opened it.

set -u

CJ_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "$CJ_SCRIPTS_DIR/utils.sh"

SESSIONS="$CJ_SCRIPTS_DIR/sessions.sh"
NAVIGATE="$CJ_SCRIPTS_DIR/navigate.sh"

open_popup() {
  local client=$1 session=$2 missing width height command
  missing=$(cj_missing_commands fzf jq)
  if [ -n "$missing" ]; then
    cj_message "$client" "missing required command(s): $missing (brew install $missing)"
    return 1
  fi
  if ! cj_tmux_version_ok; then
    cj_message "$client" "tmux ${CJ_MIN_TMUX_MAJOR}.${CJ_MIN_TMUX_MINOR} or later is required ($(tmux -V))"
    return 1
  fi
  if [ ! -e "$("$BASH" "$SESSIONS" history-file)" ]; then
    cj_message "$client" "Claude Code history not found: $("$BASH" "$SESSIONS" history-file)"
    return 1
  fi

  width=$(cj_get_option "$CJ_OPT_POPUP_WIDTH" "$CJ_DEFAULT_POPUP_WIDTH")
  height=$(cj_get_option "$CJ_OPT_POPUP_HEIGHT" "$CJ_DEFAULT_POPUP_HEIGHT")
  # tmux runs the popup command with /bin/sh; every argument is quoted.
  command=$(printf '%q ' "$BASH" "$CJ_SCRIPTS_DIR/jump.sh" --select "$client" "$session")
  tmux display-popup -E -c "$client" -w "$width" -h "$height" "$command"
}

run_fzf() {
  local preview
  preview="$(printf '%q ' "$BASH" "$SESSIONS") preview {1} {2}"
  # fzf runs the preview command with $SHELL; force a POSIX shell because
  # the placeholders are quoted for one.
  SHELL=/bin/sh fzf \
    --delimiter "$(printf '\t')" \
    --with-nth 3.. \
    --no-hscroll \
    --tiebreak index \
    --layout reverse \
    --prompt 'Claude Sessions> ' \
    --header 'Enter: Jump to project  Ctrl-O: Open session in new window  Esc: Cancel' \
    --expect ctrl-o \
    --preview "$preview" \
    --preview-window 'down,40%,wrap' \
    --bind 'ctrl-/:toggle-preview'
}

# Prints a session ID to resume in a new window, or nothing to open a shell.
# STRICT=1 means resuming is the whole point, so failure is an error.
resume_target() {
  local client=$1 claude_session=$2 strict=$3 status
  "$BASH" "$SESSIONS" transcript "$claude_session"
  status=$?
  if [ "$status" -eq 1 ]; then
    if [ "$strict" -eq 1 ]; then
      cj_message "$client" "conversation $claude_session no longer exists; cannot resume it"
      return 1
    fi
    cj_message "$client" "conversation $claude_session no longer exists; opened a shell instead"
    return 0
  fi
  # 0: found, 2: Claude Code's data layout is unknown, so let claude decide.
  printf '%s\n' "$claude_session"
}

open_window() {
  local client=$1 session=$2 project=$3 claude_session=$4 error
  if ! error=$("$BASH" "$NAVIGATE" open "$session" "$project" "$claude_session" 2>&1 >/dev/null); then
    cj_message "$client" "${error:-failed to open a window for $project}"
    return 1
  fi
}

jump_to_project() {
  local client=$1 session=$2 project=$3 claude_session=$4 window action
  if window=$("$BASH" "$NAVIGATE" find "$session" "$project"); then
    "$BASH" "$NAVIGATE" focus "$session" "$window"
    return
  fi
  if [ ! -d "$project" ]; then
    cj_message "$client" "project directory not found: $project"
    return 1
  fi
  action=$(cj_get_option "$CJ_OPT_NEW_WINDOW_ACTION" "$CJ_DEFAULT_NEW_WINDOW_ACTION")
  case "$action" in
    resume) claude_session=$(resume_target "$client" "$claude_session" 0) ;;
    shell) claude_session="" ;;
    *)
      cj_message "$client" "invalid $CJ_OPT_NEW_WINDOW_ACTION '$action' (use resume or shell)"
      return 1
      ;;
  esac
  open_window "$client" "$session" "$project" "$claude_session"
}

select_and_go() {
  local client=$1 session=$2 list output status key line claude_session project
  if ! list=$("$BASH" "$SESSIONS" list 2>&1); then
    cj_message "$client" "$list"
    return 1
  fi

  output=$(printf '%s\n' "$list" | run_fzf)
  status=$?
  # 1: no match, 130: cancelled. Leave tmux untouched.
  [ "$status" -eq 0 ] || return 0

  key=${output%%$'\n'*}
  line=${output#*$'\n'}
  line=${line%%$'\n'*}
  claude_session=${line%%$'\t'*}
  project=${line#*$'\t'}
  project=${project%%$'\t'*}
  if [ -z "$line" ] || ! cj_is_session_id "$claude_session"; then
    return 0
  fi

  case "$key" in
    ctrl-o)
      claude_session=$(resume_target "$client" "$claude_session" 1) || return 1
      open_window "$client" "$session" "$project" "$claude_session"
      ;;
    *)
      jump_to_project "$client" "$session" "$project" "$claude_session"
      ;;
  esac
}

main() {
  local client session
  if [ "${1:-}" = "--select" ]; then
    client=${2:-}
    session=${3:-}
  else
    client=${1:-$(tmux display-message -p '#{client_name}' 2>/dev/null)}
    session=${2:-$(tmux display-message -p '#{session_id}' 2>/dev/null)}
  fi
  if ! cj_is_tmux_id '$' "$session"; then
    cj_message "$client" "could not determine the tmux session"
    return 1
  fi
  if [ "${1:-}" = "--select" ]; then
    select_and_go "$client" "$session"
  else
    open_popup "$client" "$session"
  fi
}

main "$@"
