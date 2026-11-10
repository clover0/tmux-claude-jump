# shellcheck shell=bash disable=SC2034  # constants are used by the sourcing scripts
#
# Shared helpers for tmux-claude-jump.
# Compatible with bash 3.2 (the macOS system bash).

# Plugin options and their defaults. Add new options here.
CJ_OPT_KEY="@claude-jump-key"
CJ_OPT_POPUP_WIDTH="@claude-jump-popup-width"
CJ_OPT_POPUP_HEIGHT="@claude-jump-popup-height"
CJ_OPT_NEW_WINDOW_ACTION="@claude-jump-new-window-action"

CJ_DEFAULT_KEY="y"
CJ_DEFAULT_POPUP_WIDTH="85%"
CJ_DEFAULT_POPUP_HEIGHT="75%"
CJ_DEFAULT_NEW_WINDOW_ACTION="resume"

# Window options set by the plugin on windows it creates.
CJ_WINDOW_OPT_PROJECT="@claude_jump_project"
CJ_WINDOW_OPT_SESSION="@claude_jump_session"

CJ_MIN_TMUX_MAJOR=3
CJ_MIN_TMUX_MINOR=2

# cj_get_option NAME DEFAULT
# Prints the global tmux option NAME, or DEFAULT when it is unset or empty.
cj_get_option() {
  local value
  value=$(tmux show-option -gqv "$1" 2>/dev/null)
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$2"
  fi
}

# cj_escape_format STRING
# Escapes '#' so tmux does not expand STRING as a format.
cj_escape_format() {
  printf '%s\n' "${1//#/##}"
}

# cj_message CLIENT MESSAGE
# Shows MESSAGE on the tmux client CLIENT. Falls back to stderr when no
# client is given or tmux cannot display it (for example, in tests).
cj_message() {
  local client=$1 text="claude-jump: $2"
  if [ -n "$client" ] &&
    tmux display-message -c "$client" "$(cj_escape_format "$text")" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$text" >&2
}

# cj_missing_commands CMD...
# Prints the commands that are not available, separated by spaces.
cj_missing_commands() {
  local cmd missing=""
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  printf '%s\n' "${missing# }"
}

# cj_tmux_version_ok
# Succeeds when the running tmux is at least CJ_MIN_TMUX_MAJOR.CJ_MIN_TMUX_MINOR.
# Development builds ("tmux master", "tmux next-3.5") are accepted.
cj_tmux_version_ok() {
  local version major minor
  version=$(tmux -V 2>/dev/null) || return 1
  version=${version#tmux }
  version=${version#next-}
  case "$version" in
    master*) return 0 ;;
  esac
  if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
    return 1
  fi
  major=${BASH_REMATCH[1]}
  minor=${BASH_REMATCH[2]}
  if [ "$major" -gt "$CJ_MIN_TMUX_MAJOR" ]; then
    return 0
  fi
  [ "$major" -eq "$CJ_MIN_TMUX_MAJOR" ] && [ "$minor" -ge "$CJ_MIN_TMUX_MINOR" ]
}

# cj_normalize_path PATH
# Resolves symlinks for existing directories. For missing directories the
# path is returned with trailing slashes removed, so comparisons stay exact.
cj_normalize_path() {
  local path=$1 resolved
  if [ -d "$path" ] && resolved=$(CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$resolved"
    return 0
  fi
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
    path=${path%/}
  done
  printf '%s\n' "$path"
}

# cj_claude_config_dir
# Claude Code's configuration directory, honoring CLAUDE_CONFIG_DIR.
cj_claude_config_dir() {
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# cj_is_session_id STRING
# Session IDs are passed as command arguments, so only a safe character set
# is accepted.
cj_is_session_id() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

# cj_is_tmux_id PREFIX STRING
# Validates tmux object IDs such as "$3" (session) or "@12" (window).
cj_is_tmux_id() {
  case "$2" in
    "$1"*) [[ "${2#"$1"}" =~ ^[0-9]+$ ]] ;;
    *) return 1 ;;
  esac
}
