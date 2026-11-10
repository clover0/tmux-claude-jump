#!/usr/bin/env bash
#
# Reads Claude Code's local conversation data and prints it in a form the
# picker can use. This is the only file that knows Claude Code's on-disk
# format, so it is the only file to update when that format changes. Files are
# only read, never written.
#
# Claude Code (CLI and Desktop) stores each conversation as
#   <config>/projects/<encoded-project-dir>/<session-id>.jsonl
# where <encoded-project-dir> is the project path with every character other
# than [A-Za-z0-9] replaced by "-". Each line is a JSON record; the ones used
# here are:
#   {"type":"user", "cwd", "timestamp", "isSidechain", "isMeta", "origin", "message":{"content"}}
#   {"type":"custom-title", "customTitle"}   title set by the user
#   {"type":"ai-title", "aiTitle"}           generated title
#   {"type":"relocated", "relocatedCwd"}     conversation moved to another directory
#
# Usage:
#   sessions.sh list                    One line per session, newest first:
#                                       <session-id> TAB <project> TAB <display>
#   sessions.sh preview SESSION PROJECT Human-readable details of one session
#   sessions.sh transcript SESSION      Exit 0 if the conversation data exists,
#                                       1 if it is missing, 2 if unknown
#   sessions.sh data-dir                Directory holding the conversation data

set -u

CJ_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "$CJ_SCRIPTS_DIR/utils.sh"

# Width (in terminal columns) of the visible part of each line. The text used
# only for searching is placed after this padding so it stays off screen.
CJ_DISPLAY_WIDTH=400

data_dir() {
  printf '%s/projects\n' "$(cj_claude_config_dir)"
}

# shellcheck disable=SC2016
JQ_SESSIONS='
def clean: gsub("[[:cntrl:]  ]+"; " ") | gsub("^ +| +$"; "") | gsub("  +"; " ");

# Seconds since the epoch from an ISO 8601 string or a millisecond number.
def seconds:
  if type == "string" then (sub("\\.[0-9]+"; "") | fromdateiso8601? // null)
  elif type == "number" then (if . > 100000000000 then . / 1000 else . end)
  else null end;

def safe_path: type == "string" and startswith("/") and (test("[[:cntrl:]]") | not);

# Text the user typed, or "" for tool results, injected and system messages.
def prompt_text:
  .message.content as $c
  | (if ($c | type) == "string" then $c
     elif ($c | type) == "array" then [$c[] | select(.type == "text") | .text | strings] | join(" ")
     else "" end)
  | if test("^<command-name>") then (capture("^<command-name>(?<n>[^<]*)</command-name>").n // "")
    elif test("^<(local-command|command-message|command-args|bash-|task-notification|system-reminder|user-prompt-submit-hook)") then ""
    else . end
  | clean;

def human:
  .type == "user" and .isSidechain != true and .isMeta != true
  and (.origin == null or .origin.kind == "human");

# Input: "<./encoded-dir/session-id.jsonl>:<json>" lines from grep -H.
def records:
  inputs
  | index(":{") as $i
  | select($i != null)
  | (.[0:$i] | split("/")) as $parts
  | select(($parts | length) == 3 and ($parts[2] | test("^[A-Za-z0-9_-]+\\.jsonl$")))
  | (.[$i + 1:] | fromjson? // empty) as $r
  | select($r | type == "object")
  | {dir: $parts[1], sid: ($parts[2] | sub("\\.jsonl$"; "")), r: $r};

def sessions:
  [records]
  | group_by([.dir, .sid])
  | map(
      .[0].dir as $dir
      | [.[].r] as $rs
      | ([$rs[] | select(.type == "relocated") | .relocatedCwd | select(safe_path)] | last) as $relocated
      | ([$relocated | values] + [$rs[] | select(.type == "user") | .cwd | select(safe_path)]) as $cwds
      | ([$rs[] | select(human) | {ts: (.timestamp | seconds), text: prompt_text}
          | select(.text != "")] | sort_by(.ts)) as $prompts
      | ([$rs[] | select(.type == "custom-title") | .customTitle | strings | clean | select(. != "")] | last) as $custom
      | ([$rs[] | select(.type == "ai-title") | .aiTitle | strings | clean | select(. != "")] | last) as $ai
      | { sid: .[0].sid,
          # claude --resume only finds the conversation from the directory
          # whose encoding names the folder it is stored in.
          project: (first($cwds[] | select(gsub("[^A-Za-z0-9]"; "-") == $dir)) // $cwds[0]
                    | if . != null and length > 1 then sub("/+$"; "") else . end),
          last: ([$rs[] | select(.type == "cj-mtime") | .mtime | numbers] | max
                 // ($prompts | map(.ts | values) | max) // 0),
          prompts: $prompts,
          title: ($custom // $ai
                  // ($prompts | map(.text | select(startswith("/") | not)) | first)
                  // ($prompts | first | .text?)) }
      | select(.project != null and .title != null))
  | sort_by(-.last, .project, .sid);

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

def fmt_time($f): if . > 0 then (floor | strflocaltime($f)) else "--/-- --:--" end;
'

# shellcheck disable=SC2016
JQ_LIST='
sessions[]
| (.project | if . == "/" then "/" else split("/") | last end) as $name
| ((.last | fmt_time("%m/%d %H:%M")) + "  " + ($name | truncate(20) | pad(20)) + "  "
   + (.title | truncate(80))) as $visible
| [ .sid, .project,
    ($visible | pad($width)) + "  " + .project + "  " + .sid + "  " + .title + "  "
    + (.prompts | map(.text) | join(" | ")) ]
| join("\t")
'

# shellcheck disable=SC2016
JQ_PREVIEW='
[sessions[] | select(.sid == $sid and .project == $project)] | first
| if . == null then "No conversation data found for this session."
  else
    "Title:    \(.title)",
    "Project:  \(.project)",
    "Session:  \(.sid)",
    "Updated:  \(.last | fmt_time("%Y-%m-%d %H:%M"))",
    "Prompts:  \(.prompts | length)",
    "",
    (.prompts[] | "\(.ts // 0 | fmt_time("%m/%d %H:%M"))  \(.text)")
  end
'

require_data_dir() {
  local dir
  dir=$(data_dir)
  if [ ! -d "$dir" ]; then
    printf 'Claude Code session data not found: %s\n' "$dir" >&2
    return 1
  fi
}

# cmd_records FILE...: prints, for each conversation file, a modification-time
# record and the lines the jq programs need, each prefixed with its file name
# ("<file>:<json>"). Tool results are dropped before jq parses anything,
# which keeps large transcripts fast. FILEs are relative to the data directory.
cmd_records() {
  [ $# -gt 0 ] || return 0
  if stat --version >/dev/null 2>&1; then
    stat -c '%n:{"type":"cj-mtime","mtime":%Y}' -- "$@"
  else
    stat -f '%N:{"type":"cj-mtime","mtime":%m}' -- "$@"
  fi
  LC_ALL=C grep -a -H -E '"type":"(user|custom-title|ai-title|relocated)"' -- "$@" |
    LC_ALL=C grep -v -F '"type":"tool_result"'
}

cmd_list() {
  local dir output
  require_data_dir || return 1
  dir=$(data_dir)
  if ! output=$(cd "$dir" &&
    find . -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -exec "$BASH" "$CJ_SCRIPTS_DIR/sessions.sh" records {} + |
    jq -nrR --argjson width "$CJ_DISPLAY_WIDTH" "$JQ_SESSIONS $JQ_LIST"); then
    printf 'Failed to read Claude Code session data: %s\n' "$dir" >&2
    return 1
  fi
  if [ -z "$output" ]; then
    printf 'No Claude Code sessions found in %s\n' "$dir" >&2
    return 1
  fi
  printf '%s\n' "$output"
}

cmd_preview() {
  local sid=${1:-} project=${2:-} files file
  require_data_dir || return 1
  if ! cj_is_session_id "$sid"; then
    printf 'Invalid session ID.\n'
    return 1
  fi
  if [ -n "$project" ] && [ ! -d "$project" ]; then
    printf 'Warning: project directory no longer exists.\n\n'
  fi
  (
    cd "$(data_dir)" || exit 1
    files=()
    for file in ./*/"$sid".jsonl; do
      [ -f "$file" ] && files+=("$file")
    done
    if [ "${#files[@]}" -eq 0 ]; then
      printf 'No conversation data found for this session.\n'
      exit 0
    fi
    cmd_records "${files[@]}" |
      jq -nrR --arg sid "$sid" --arg project "$project" "$JQ_SESSIONS $JQ_PREVIEW"
  )
}

cmd_transcript() {
  local sid=${1:-} dir file
  cj_is_session_id "$sid" || return 1
  dir=$(data_dir)
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
    data-dir) data_dir ;;
    records) cmd_records "$@" ;;
    *)
      printf 'Usage: %s {list|preview SESSION PROJECT|transcript SESSION|data-dir}\n' "$0" >&2
      return 2
      ;;
  esac
}

main "$@"
