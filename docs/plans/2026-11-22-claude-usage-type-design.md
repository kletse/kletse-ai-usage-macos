# Claude usage type

Add the requested segmented Usage type row directly below Provider in each Claude account's
settings, with Session and Week choices. Existing and new accounts default to Session. Save
the choice per account in accounts.json, keeping it independent of credentials and usage caches.

Use the choice for both the menu bar percentage and the dropdown account headline. Week means
the overall weekly allowance, never a per-model weekly limit. If the overall week is absent,
show a dash rather than another allowance. Session retains the existing monthly-spend fallback
for Enterprise plans. Keep every usage bar visible and retain Codex's current behavior.

Use the existing account autosave and refresh flow so the saved choice applies to already loaded
usage. No additional API calls or new polling mechanisms are needed.

Implementation and validation: add the optional config preference with a Session default,
add the conditional picker, share headline selection across both displays, verify legacy and
modern Claude payloads, config persistence, Codex behavior and missing-week handling, then
build and inspect the rendered settings and installed app.
