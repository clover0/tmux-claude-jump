#!/usr/bin/env bash
#
# TPM entry point: registers the key binding for tmux-claude-jump.
# Only the binding is added; no other tmux option is changed.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "$CURRENT_DIR/scripts/utils.sh"

main() {
  local key jump command
  key=$(cj_get_option "$CJ_OPT_KEY" "$CJ_DEFAULT_KEY")
  jump=$(printf '%q' "$CURRENT_DIR/scripts/jump.sh")
  # run-shell expands formats, so '#' in the plugin path must be escaped.
  # The client and session are passed explicitly because the popup that
  # jump.sh opens cannot identify the client by itself.
  command="$(cj_escape_format "$jump") '#{client_name}' '#{session_id}'"
  tmux bind-key "$key" run-shell -b "$command"
}

main
