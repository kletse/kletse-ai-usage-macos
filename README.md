# AI Usage

A macOS menu bar app that shows how much of your AI subscription limits you have used, for several
Claude Code and Codex logins at once.

The menu bar shows a provider icon (the Claude Code mascot or the OpenAI knot for Codex) and the
used percentage of each account's tightest limit, in config order, with a dot between groups:
`[claude] 96% [codex] 50% · [claude] 5% [codex] 1%`. The dropdown lists the same accounts in the
same order, with every limit (session / 5-hour, weekly, per-model weekly, Enterprise monthly
spend) and the time until it resets.

## Build and run

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
scripts/bundle.sh             # build, install to ~/Applications/AIUsage.app and launch
scripts/bundle.sh --no-open   # build and install only
swift run AIUsage --dump      # print what the app would show, without the UI
swift run AIUsage --render-panel panel.png      # render the dropdown with live data
swift run AIUsage --render-menubar menubar.png  # render the menu bar item with sample data
```

Launch at login is turned on at first launch; turn it off in System Settings → General → Login Items.

## Accounts

Accounts live in `~/.config/ai-usage/accounts.json` (created on first run). Edits are picked up
on the next refresh.

```json
[
  { "name": "Claude Code", "group": "Work",   "provider": "claude", "dir": "~/.claude-work" },
  { "name": "Codex",       "group": "Work",   "provider": "codex",  "dir": "~/.codex-work" },
  { "name": "Claude",      "group": "Kletse", "provider": "claude", "dir": "~/.claude" },
  { "name": "Codex",       "group": "Kletse", "provider": "codex",  "dir": "~/.codex" }
]
```

- The order of the list is the order in the menu bar and the dropdown.
- `group` is optional. Accounts in the same group are shown together under a header, and the
  menu bar puts a dot wherever the group changes.
- `dir` is the `CLAUDE_CONFIG_DIR` or `CODEX_HOME` of that login.
- `short` is an optional label, only used by `--dump`.
- Claude accounts may set `keychainService` to override the derived keychain item name.
- `AI_USAGE_CONFIG=/path/to/accounts.json` uses a different config file.

## Where the data comes from

**Claude Code** — `GET https://api.anthropic.com/api/oauth/usage`, the endpoint behind `/usage`.
- The OAuth token is read from the keychain with `/usr/bin/security`, the tool Claude Code uses
  to store it, so no keychain prompt appears.
- The service is `Claude Code-credentials` for the default `~/.claude`. With `CLAUDE_CONFIG_DIR`
  set, it's `Claude Code-credentials-<first 8 hex chars of sha256(absolute config dir)>`.
- Enterprise accounts report a monthly spend cap instead of session/weekly windows. The API gives
  no reset date for it, so the app assumes the 1st of next month (shown as `~`).
- If the token is expired or rejected, the app shows Claude Code's own last cached usage from
  `.claude.json` (`cachedUsageUtilization`), marked as cached.

**Codex** — `GET https://chatgpt.com/backend-api/wham/usage`, the data behind `/status`.
- The token and account ID come from `$CODEX_HOME/auth.json`.
- If the call fails, the app shows the newest `rate_limits` snapshot from
  `$CODEX_HOME/sessions/**/*.jsonl`, marked as cached.

## Safety

- **Read-only.** The app never writes to the CLIs' config files or keychain items.
- **No token refresh.** Refreshing rotates the refresh token and would log the CLI out. Using the
  CLI refreshes it; the app picks up the new token on the next poll.
- **No secrets in output.** Tokens stay in memory. Errors show HTTP status codes only, never
  response bodies or tokens.
- Polls every 5 minutes and backs off on HTTP 429 (`Retry-After`).

## Credits

The Codex icon is the OpenAI knot as shipped in [CodexBar](https://github.com/steipete/CodexBar)
(MIT). The Claude icon is drawn from the block characters Claude Code prints on startup.
