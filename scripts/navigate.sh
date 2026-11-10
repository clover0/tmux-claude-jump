#!/usr/bin/env bash
#
# Finds, focuses and creates tmux windows for a project directory.
# Knows nothing about Claude Code's data format; it only receives a project
# path and, optionally, a session ID to resume.
#
# All tmux objects are addressed by their stable IDs ($session, @window), never
# by index or name. Existing windows and panes are never killed, respawned or
# sent keys.
#
# Usage:
#   navigate.sh find  TMUX_SESSION PROJECT
#       Print the ID of the window that best matches PROJECT in TMUX_SESSION.
#       Exit 1 when there is none.
#   navigate.sh focus TMUX_SESSION WINDOW
#       Make WINDOW the current window of TMUX_SESSION.
#   navigate.sh open  TMUX_SESSION PROJECT [CLAUDE_SESSION]
#       Create a window in PROJECT and focus it. With CLAUDE_SESSION, the
#       window runs `claude --resume CLAUDE_SESSION` and then a shell.
#       Print the new window ID.
#
# Window matching, in order of priority:
#   1. windows created by this plugin whose @claude_jump_project equals PROJECT
#   2. windows with any pane whose current path equals PROJECT
# Paths are compared exactly after resolving symlinks. Within a tier the
# session's current window wins, otherwise the one with the lowest index.

set -u

CJ_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "$CJ_SCRIPTS_DIR/utils.sh"

TAB=$(printf '\t')

# pick_window: reads "window_id TAB window_active" lines (in index order) and
# prints the active window if present, otherwise the first one.
pick_window() {
  local wid active first=""
  while IFS="$TAB" read -r wid active; do
    [ -n "$wid" ] || continue
    if [ "$active" = "1" ]; then
      printf '%s\n' "$wid"
      return 0
    fi
    [ -n "$first" ] || first=$wid
  done
  [ -n "$first" ] || return 1
  printf '%s\n' "$first"
}

managed_matches() {
  local session=$1 target=$2 wid active project
  tmux list-windows -t "$session" \
    -F "#{window_id}${TAB}#{window_active}${TAB}#{${CJ_WINDOW_OPT_PROJECT}}" |
    while IFS="$TAB" read -r wid active project; do
      [ -n "$project" ] || continue
      if [ "$(cj_normalize_path "$project")" = "$target" ]; then
        printf '%s\t%s\n' "$wid" "$active"
      fi
    done
}

path_matches() {
  local session=$1 target=$2 wid active path last=""
  tmux list-panes -s -t "$session" \
    -F "#{window_id}${TAB}#{window_active}${TAB}#{pane_current_path}" |
    while IFS="$TAB" read -r wid active path; do
      [ "$wid" != "$last" ] || continue
      if [ -n "$path" ] && [ "$(cj_normalize_path "$path")" = "$target" ]; then
        printf '%s\t%s\n' "$wid" "$active"
        last=$wid
      fi
    done
}

cmd_find() {
  local session=$1 project=$2 target
  target=$(cj_normalize_path "$project")
  managed_matches "$session" "$target" | pick_window && return 0
  path_matches "$session" "$target" | pick_window
}

cmd_focus() {
  local session=$1 window=$2
  tmux select-window -t "${session}:${window}"
}

cmd_open() {
  local session=$1 project=$2 claude_session=${3:-} name shell window
  if [ ! -d "$project" ]; then
    printf 'Project directory not found: %s\n' "$project" >&2
    return 1
  fi
  project=$(cj_normalize_path "$project")
  name=$(basename "$project")

  if [ -n "$claude_session" ]; then
    if ! cj_is_session_id "$claude_session"; then
      printf 'Invalid Claude session ID.\n' >&2
      return 1
    fi
    shell=$(tmux show-option -gqv default-shell)
    [ -n "$shell" ] || shell=${SHELL:-/bin/sh}
    # The command is passed as separate arguments, so tmux executes it
    # directly without a shell parsing it.
    window=$(tmux new-window -d -P -F '#{window_id}' -t "${session}:" \
      -c "$(cj_escape_format "$project")" -n "$(cj_escape_format "$name")" \
      -- "$BASH" "$CJ_SCRIPTS_DIR/resume.sh" "$claude_session" "$shell") || return 1
  else
    window=$(tmux new-window -d -P -F '#{window_id}' -t "${session}:" \
      -c "$(cj_escape_format "$project")" -n "$(cj_escape_format "$name")") || return 1
  fi

  # Tag the window so it is found again even after its panes change
  # directory. Remove the window again if that fails, so no stray window
  # is left behind.
  if ! tmux set-option -w -t "$window" "$CJ_WINDOW_OPT_PROJECT" "$project" ||
    { [ -n "$claude_session" ] &&
      ! tmux set-option -w -t "$window" "$CJ_WINDOW_OPT_SESSION" "$claude_session"; } ||
    ! cmd_focus "$session" "$window"; then
    tmux kill-window -t "$window" 2>/dev/null
    printf 'Failed to set up the new window.\n' >&2
    return 1
  fi
  printf '%s\n' "$window"
}

usage() {
  printf 'Usage: %s {find SESSION PROJECT|focus SESSION WINDOW|open SESSION PROJECT [CLAUDE_SESSION]}\n' "$0" >&2
  return 2
}

main() {
  local command=${1:-} valid=0
  [ $# -gt 0 ] && shift
  case "$command" in
    find) [ $# -eq 2 ] && valid=1 ;;
    focus) [ $# -eq 2 ] && cj_is_tmux_id @ "$2" && valid=1 ;;
    open) { [ $# -eq 2 ] || [ $# -eq 3 ]; } && valid=1 ;;
  esac
  if [ "$valid" -ne 1 ]; then
    usage
    return
  fi
  if ! cj_is_tmux_id '$' "$1"; then
    printf 'Invalid tmux session ID: %s\n' "$1" >&2
    return 2
  fi
  "cmd_$command" "$@"
}

main "$@"
