# AI Usage

A macOS menu bar app that shows how much of your AI subscription limits is left, for several
Claude Code and Codex logins at once.

The menu bar shows one number per account: the remaining percentage of its tightest limit, e.g.
`CC 4% CCK 96% CO 50% COK 99%`. The dropdown lists every limit (session / 5-hour, weekly,
per-model weekly, Enterprise monthly spend) with the time until it resets.

## Build and run

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
scripts/bundle.sh             # build, install to ~/Applications/AIUsage.app and launch
scripts/bundle.sh --no-open   # build and install only
swift run AIUsage --dump      # print what the app would show, without the UI
```

Launch at login is turned on at first launch; toggle it in the dropdown.

## Accounts

Accounts live in `~/.config/ai-usage/accounts.json` (created on first run). Edits are picked up
on the next refresh.

```json
[
  { "short": "CC",  "name": "Claude Code work",     "provider": "claude", "dir": "~/.claude-work" },
  { "short": "CCK", "name": "Claude Code personal", "provider": "claude", "dir": "~/.claude" },
  { "short": "CO",  "name": "Codex work",           "provider": "codex",  "dir": "~/.codex-work" },
  { "short": "COK", "name": "Codex personal",       "provider": "codex",  "dir": "~/.codex" }
]
```

- `dir` is the `CLAUDE_CONFIG_DIR` or `CODEX_HOME` of that login.
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
