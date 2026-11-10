# tmux-claude-jump

A tmux plugin for moving between projects and Claude Code conversations.

Press `prefix + y` to search all of your past Claude Code sessions with fzf, across every project. Pick one, and the plugin takes you to that project's tmux window. If the project has no window yet, it creates one and resumes the conversation with `claude --resume`.

The plugin doesn't replace anything in Claude Code. It reads Claude Code's local history (read-only) and only adds a key binding to tmux.

## Preview

```text
Claude Sessions>
  4/4 ──────────────────────────────────────────────────────────────────────
  Enter: Jump to project  Ctrl-O: Open session in new window  Esc: Cancel
▌ 11/11 07:17  my-app                認証機能のリファクタリング            ··
  11/11 04:14  backend               APIエラーハンドリングの改善           ··
  11/10 04:20  my-app                テストコードの追加                    ··
  11/09 03:20  website               UIコンポーネントの修正                ··

╭──────────────────────────────────────────────────────────────────────────╮
│ Project:  /Users/me/src/my-app                                           │
│ Session:  5f0c2a9e-0000-4000-8000-000000000001                           │
│ Updated:  2026-11-11 07:17                                               │
│ Prompts:  2                                                              │
│                                                                          │
│ 11/11 07:07  認証機能のリファクタリング                                  │
│ 11/11 07:17  トークンの有効期限も見直して                                │
╰──────────────────────────────────────────────────────────────────────────╯
```

Each row is one conversation: last update time, project name, and the first prompt that isn't a slash command. The search also covers the project's absolute path, the session ID, and every prompt in the conversation.

## Requirements

- macOS is the primary target. Linux should work too, but it isn't tested.
- tmux 3.2 or later (for `display-popup`)
- fzf
- jq 1.6 or later
- bash. The macOS system bash 3.2 is enough.
- Claude Code CLI (`claude`) on the tmux server's `PATH`, so sessions can be resumed

No other runtimes (Python, Node.js, and so on) are used.

## Installing dependencies with Homebrew

```bash
brew install tmux fzf jq
```

Check the tmux version:

```bash
tmux -V
```

## Installation with TPM

Add the plugin to `~/.tmux.conf`, before the line that initializes TPM. Replace `<owner>` with the GitHub account that hosts this repository:

```tmux
set -g @plugin '<owner>/tmux-claude-jump'

run '~/.tmux/plugins/tpm/tpm'
```

Then press `prefix + I` in tmux to install. `prefix + U` updates the plugin.

To uninstall, remove the `@plugin` line and press `prefix + alt + u`. The key binding stays in the running tmux server until you restart it or run `tmux unbind-key y`.

## Manual installation

Clone or copy this repository anywhere, for example:

```bash
git clone <repository-url> ~/.tmux/plugins/tmux-claude-jump
```

Then load it from `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-claude-jump/claude-jump.tmux
```

Reload the configuration:

```bash
tmux source-file ~/.tmux.conf
```

## Usage

Press `prefix + y` in any tmux window. A popup lists your Claude Code sessions, newest first. Type to filter.

| Key | Action |
|---|---|
| `Enter` | Jump to the project's window. If none exists, create one (see `@claude-jump-new-window-action`). |
| `Ctrl-O` | Always open a new window and resume the selected session in it |
| `Ctrl-/` | Toggle the preview |
| `Esc` | Close the popup without changing anything |

`Enter` never resumes a session in a window that already exists. It only switches to that window, so a Claude Code process running there is left alone. `Ctrl-O` is for working on several conversations of one project side by side.

## Options

Set these in `~/.tmux.conf` before the plugin is loaded.

| Option | Default | Description |
|---|---|---|
| `@claude-jump-key` | `y` | Key, after the prefix, that opens the picker |
| `@claude-jump-popup-width` | `85%` | Popup width (cells or percentage) |
| `@claude-jump-popup-height` | `75%` | Popup height (cells or percentage) |
| `@claude-jump-new-window-action` | `resume` | What `Enter` does in a new window: `resume` runs `claude --resume <session-id>`, `shell` only opens a shell in the project directory |

`Ctrl-O` always resumes, regardless of `@claude-jump-new-window-action`.

Example:

```tmux
set -g @claude-jump-key 'C-j'
set -g @claude-jump-popup-width '90%'
set -g @claude-jump-popup-height '80%'
set -g @claude-jump-new-window-action 'shell'
```

The plugin reads Claude Code's data from `$CLAUDE_CONFIG_DIR`, or from `~/.claude` when that variable isn't set. The scripts run inside the tmux server, so the variable has to be in tmux's global environment:

```bash
tmux set-environment -g CLAUDE_CONFIG_DIR "$HOME/.config/claude"
```

## How tmux windows relate to Claude sessions

The plugin works on the tmux session you pressed the key in. Windows in other tmux sessions are never searched or changed.

When you press `Enter`, it looks for a window in this order:

1. A window created by this plugin whose `@claude_jump_project` window option is the project directory
2. A window with any pane whose current directory (`#{pane_current_path}`) is the project directory

Window names are ignored. Paths are compared exactly after resolving symlinks, so being in a parent or child directory doesn't count. If more than one window matches at the same level, the current window wins. Otherwise the window with the lowest index is used. Windows are tracked by their IDs (`@12`), so renumbering, moving or renaming them doesn't matter.

A window the plugin creates:

- is added to the current tmux session, starts in the project directory and is named after it
- gets the window options `@claude_jump_project` (the resolved project path) and, when it resumes a conversation, `@claude_jump_session` (the session ID)
- runs `claude --resume <session-id>`. When Claude Code exits, the window switches to your tmux `default-shell`, started as a login shell in the same directory, so the window stays open.

You can see the tags with:

```bash
tmux show-options -w @claude_jump_project
```

Existing windows and panes are never killed, respawned or sent keys. The plugin never passes `--dangerously-skip-permissions` and never writes to Claude Code's files.

When a conversation can no longer be found (no `projects/*/<session-id>.jsonl` under the Claude config directory), `Enter` opens a plain shell window and shows a message, while `Ctrl-O` shows a message and does nothing. A project directory that doesn't exist anymore is reported and no window is created.

## Running the tests

The tests use dummy history in `tests/fixtures` and a private tmux server (`tmux -L` with its own `TMUX_TMPDIR`). They don't read your Claude history and don't touch the tmux server you're running. A stub replaces `claude`, so no real session is resumed.

```bash
tests/run.sh
```

Run the plugin scripts with the macOS system bash 3.2:

```bash
TEST_BASH=/bin/bash tests/run.sh
```

The end-to-end test attaches a real client through `script(1)`, presses `prefix + y` and drives fzf in the popup. It's skipped if `script` isn't available.

Static analysis:

```bash
shellcheck -x claude-jump.tmux scripts/*.sh tests/*.sh
```

## Known limitations

- Only windows of the current tmux session are considered. Jumping across tmux sessions isn't supported.
- Clients attached to the same tmux session share its current window, so switching windows also changes what those clients show. Clients on other tmux sessions aren't affected.
- The plugin doesn't know whether Claude Code is running in a window. It matches by directory only.
- History entries without a `sessionId` (written by old Claude Code versions) can't be resumed and are skipped.
- fzf can't search hidden fields. So the path, session ID and other prompts sit at the end of each row, past the visible width, and matches there aren't highlighted. On a popup wider than about 400 columns they become visible.
- Column alignment estimates character width, so some characters (combining marks, some emoji) can shift columns slightly.
- Claude Code's local data format isn't a public interface and may change. All format-specific code lives in `scripts/sessions.sh`. If the `projects/` directory is missing, the check for deleted conversations is skipped and `claude` reports the error instead.
- Resumed windows run `claude` directly, not through your interactive shell, so shell aliases or functions named `claude` aren't used. `default-command` isn't applied to the shell that starts after Claude Code exits.
- On case-insensitive file systems, paths that differ only in letter case aren't treated as the same.

## Troubleshooting

Nothing happens when pressing the key. Check the binding and whether another binding replaced it:

```bash
tmux list-keys -T prefix y
```

"missing required command(s)" or "claude command not found". The scripts use the tmux server's environment, which may have a different `PATH` from your shell. Check it and update it:

```bash
tmux show-environment -g PATH
tmux set-environment -g PATH "$PATH"
```

"Claude Code history not found". Make sure the history file exists and that `CLAUDE_CONFIG_DIR` is set in tmux if you use a custom location:

```bash
ls ~/.claude/history.jsonl
tmux show-environment -g CLAUDE_CONFIG_DIR
```

"tmux 3.2 or later is required". Upgrade tmux, then restart the server so the new binary is used:

```bash
brew upgrade tmux
tmux kill-server
```

The list is empty or looks wrong. Run the history reader directly. This prints your prompts to the terminal:

```bash
~/.tmux/plugins/tmux-claude-jump/scripts/sessions.sh list | cut -f1,2 | head
```

## License

MIT. See [LICENSE](LICENSE).
