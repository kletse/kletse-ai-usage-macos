# Claude session renewal

## Approved behavior

Read the stored Claude access-token expiry and schedule a renewal check four minutes before
it expires. Run Claude Code's noninteractive local `/usage` command, then reread the saved
credentials. Confirm renewal only when the access token changes and its expiry advances.
Use that saved expiry to schedule the next renewal. Recheck on launch, wake, and normal polls
so another CLI's renewal or an account edit replaces the previous deadline.

## Implementation

- Retain the credential source so the subprocess uses the same default or account-specific
  Claude login. Leave unsupported custom Keychain services alone and explain the limitation.
- Let Claude Code own credential writes. Disable hooks, tools, MCP, Chrome, and conversation
  persistence for the local command; discard its output and bound its runtime.
- Serialize attempts for the same login. Back off after failed or unconfirmed renewal, even
  when the CLI exits successfully. Keep usage requests subject to their existing API backoff.
- Keep the renewal timer independent of the five-minute usage poll. Reread credentials before
  acting, and reschedule from the observed expiry after every attempt.
- Continue after a missed deadline on wake while credentials remain renewable. A missing
  refresh credential or known final login expiry requires login instead of repeated launches.
- Fixed-data diagnostics must never start renewal tasks, read credentials, or launch the CLI.

## Verification

Test deadline scheduling across successive renewals, credential readback, failure backoff,
account isolation, external credential updates, subprocess timeout, and environment isolation.
Run the app's real renewal coordinator and subprocess against disposable OAuth fixtures,
then run Swift tests, diagnostic privacy checks, and a release build/install check.

The installed Claude CLI 2.1.325 renewed disposable credentials four minutes before expiry in
local tests. Actual Anthropic renewal and its granted lifetime remain unverified until the real
login reaches its renewal window; no claim of extending the final login deadline is made.
