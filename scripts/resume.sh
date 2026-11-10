#!/usr/bin/env bash
#
# Runs inside a window created by navigate.sh: resumes a Claude Code session,
# then replaces itself with an interactive login shell so the window stays
# usable after Claude Code exits.
#
# Usage: resume.sh CLAUDE_SESSION SHELL

set -u

session=${1:-}
shell=${2:-}

# Keep this script alive if Claude Code is ended with Ctrl-C. A handler (not
# an ignore) is used so Claude Code still receives the default SIGINT action.
trap ':' INT

if command -v claude >/dev/null 2>&1; then
  claude --resume "$session"
  status=$?
  if [ "$status" -ne 0 ]; then
    printf '\nclaude-jump: claude --resume %s exited with status %d.\n' "$session" "$status"
  fi
else
  printf 'claude-jump: the "claude" command was not found in PATH.\n'
  printf 'claude-jump: PATH=%s\n' "$PATH"
fi

trap - INT
if [ -z "$shell" ] || [ ! -x "$shell" ]; then
  shell=${SHELL:-/bin/sh}
fi
exec -l "$shell"
