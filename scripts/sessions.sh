#!/usr/bin/env bash
#
# Reads Claude Code's local history and prints it in a form the picker can
# use. This is the only file that knows Claude Code's on-disk format, so it is
# the only file to update when that format changes. Files are only read.
#
# Usage:
#   sessions.sh list                    One line per session, newest first:
#                                       <session-id> TAB <project> TAB <display>
#   sessions.sh preview SESSION PROJECT Human-readable details of one session
#   sessions.sh transcript SESSION      Exit 0 if the conversation data exists,
#                                       1 if it is missing, 2 if unknown
#   sessions.sh history-file            Path of the history file

set -u

CJ_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "$CJ_SCRIPTS_DIR/utils.sh"

# Width (in terminal columns) of the visible part of each line. The text used
# only for searching is placed after this padding so it stays off screen.
CJ_DISPLAY_WIDTH=400

history_file() {
  printf '%s/history.jsonl\n' "$(cj_claude_config_dir)"
}

# Shared jq definitions: validation of history entries and text cleanup.
# shellcheck disable=SC2016
JQ_COMMON='
def clean: gsub("[[:cntrl:]  ]+"; " ") | gsub("^ +| +$"; "") | gsub("  +"; " ");

# Approximate terminal width: East Asian wide characters and emoji count as 2.
def cwidth: if (. >= 4352 and . <= 4447) or (. >= 11904 and . <= 42191)
                or (. >= 44032 and . <= 55203) or (. >= 63744 and . <= 64255)
                or (. >= 65040 and . <= 65049) or (. >= 65072 and . <= 65135)
                or (. >= 65280 and . <= 65376) or (. >= 65504 and . <= 65510)
                or (. >= 127744 and . <= 129791) or (. >= 131072 and . <= 262141)
            then 2 else 1 end;
def width: [explode[] | cwidth] | add // 0;
def truncate($n):
  if width <= $n then .
  else reduce explode[] as $c ({w: 0, out: [], full: false};
         if .full then .
         elif .w + ($c | cwidth) > $n - 1 then .full = true
         else .w += ($c | cwidth) | .out += [$c] end)
       | (.out | implode) + "…"
  end;
def pad($n): ($n - width) as $k | if $k > 0 then . + (" " * $k) else . end;

def entries:
  inputs
  | (fromjson? // empty)
  | select(type == "object")
  | select((.sessionId | type) == "string" and (.sessionId | test("^[A-Za-z0-9_-]+$")))
  | select((.project | type) == "string" and (.project | startswith("/"))
           and (.project | test("[[:cntrl:]]") | not))
  | select((.timestamp | type) == "number")
  | { sid: .sessionId,
      project: (.project | if length > 1 then sub("/+$"; "") else . end),
      ts: .timestamp,
      text: (if (.display | type) == "string" then .display | clean else "" end) };

def fmt_time($f): (. / 1000 | floor | strflocaltime($f));
'

# shellcheck disable=SC2016
JQ_LIST='
[entries]
| group_by([.project, .sid])
| map(sort_by(.ts)
      | { sid: .[0].sid,
          project: .[0].project,
          last: (map(.ts) | max),
          prompts: [.[].text | select(length > 0)] })
| sort_by(-.last, .project, .sid)
| .[]
| ((.prompts | map(select(startswith("/") | not)) | first)
   // (.prompts | first) // "(no prompt)") as $title
| (.project | if . == "/" then "/" else split("/") | last end) as $name
| ((.last | fmt_time("%m/%d %H:%M")) + "  " + ($name | truncate(20) | pad(20)) + "  "
   + ($title | truncate(80))) as $visible
| [ .sid, .project,
    ($visible | pad($width)) + "  " + .project + "  " + .sid + "  " + (.prompts | join(" | ")) ]
| join("\t")
'

# shellcheck disable=SC2016
JQ_PREVIEW='
[entries | select(.sid == $sid and .project == $project)]
| sort_by(.ts)
| if length == 0 then "No history entries found for this session."
  else
    "Project:  \($project)",
    "Session:  \($sid)",
    "Updated:  \(map(.ts) | max | fmt_time("%Y-%m-%d %H:%M"))",
    "Prompts:  \(length)",
    "",
    (.[] | select(.text != "") | "\(.ts | fmt_time("%m/%d %H:%M"))  \(.text)")
  end
'

require_history() {
  local file
  file=$(history_file)
  if [ ! -e "$file" ]; then
    printf 'Claude Code history not found: %s\n' "$file" >&2
    return 1
  fi
  if [ ! -r "$file" ]; then
    printf 'Claude Code history is not readable: %s\n' "$file" >&2
    return 1
  fi
}

cmd_list() {
  local output
  require_history || return 1
  if ! output=$(jq -nrR --argjson width "$CJ_DISPLAY_WIDTH" "$JQ_COMMON $JQ_LIST" <"$(history_file)"); then
    printf 'Failed to read Claude Code history: %s\n' "$(history_file)" >&2
    return 1
  fi
  if [ -z "$output" ]; then
    printf 'No Claude Code sessions found in %s\n' "$(history_file)" >&2
    return 1
  fi
  printf '%s\n' "$output"
}

cmd_preview() {
  local sid=${1:-} project=${2:-}
  require_history || return 1
  if [ -n "$project" ] && [ ! -d "$project" ]; then
    printf 'Warning: project directory no longer exists.\n\n'
  fi
  jq -nrR --arg sid "$sid" --arg project "$project" "$JQ_COMMON $JQ_PREVIEW" <"$(history_file)"
}

# Claude Code stores each conversation as projects/<encoded-project>/<id>.jsonl.
# The encoding of the project path is not relied upon; any match counts.
cmd_transcript() {
  local sid=${1:-} dir file
  cj_is_session_id "$sid" || return 1
  dir="$(cj_claude_config_dir)/projects"
  [ -d "$dir" ] || return 2
  for file in "$dir"/*/"$sid".jsonl; do
    [ -f "$file" ] && return 0
  done
  return 1
}

main() {
  local command=${1:-}
  [ $# -gt 0 ] && shift
  case "$command" in
    list) cmd_list ;;
    preview) cmd_preview "$@" ;;
    transcript) cmd_transcript "$@" ;;
    history-file) history_file ;;
    *)
      printf 'Usage: %s {list|preview SESSION PROJECT|transcript SESSION|history-file}\n' "$0" >&2
      return 2
      ;;
  esac
}

main "$@"
