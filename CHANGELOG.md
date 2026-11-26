# Changelog

## 2026-11-25

- **One-time login codes.** `login --code-wait SECONDS` (max 600) no longer gives up on an
  emailed/SMS code prompt: it keeps the browser open on that page and waits for
  `login.code` in the exchange, written by the new `secure-browser code <code>`. The code
  must be 4-10 letters/digits, is typed only after the usual origin gate, is deleted as soon
  as it is read, and a stale file from an earlier run is discarded. Before this the helper
  closed its browser on the code page, so a code-protected site (Humble Bundle's new
  auth.humblebundle.com flow) could never be completed. Optional `code_selector` item field.
  Captchas are unchanged: still NEEDS-HUMAN.

## 2026-10-17

- **The 1Password vault is the site registry.** `sites.d/`, the site-file template and the
  root publishing step are gone. Every Login item in the `secure-browser` vault with an
  https website is a site; the credential is typed only on that website's host. Adding a
  site is adding the item, with no install. `bin/login` lists the vault at login time,
  reads credentials by item ID (renames are harmless), carries built-in knowledge for
  LinkedIn and all Workday tenants, falls back to generic form detection (including
  two-step forms), and accepts optional plain-text hint fields on the item. A short-lived
  `secure-browser-add-site` command was written and dropped in the same day in favour of
  this. `secure-browser sites`/`status` now ask the helper for the vault listing, and the
  CLI passes `--check-secrets` through.

## 2026-10-15

- **Runtime from npm, not vendored.** `mcp-tool-gate` is now a pinned npm dependency
  alongside `@playwright/mcp` (`package.json` + `package-lock.json`). The installer runs
  `npm ci` into the root-owned install directory and the launcher executes both from
  there; `npx` is gone from the runtime path, so no code the secrets user runs lives in a
  directory that user can write. `bin/mcp-filter.js` removed. One source of truth for the
  gate: a fix upstream is a version bump here.

## 2026-10-14

- **Tool filtering.** `bin/mcp-server` now runs the Playwright server behind
  [mcp-tool-gate](https://github.com/DavidJDrake/mcp-tool-gate) (vendored as
  `bin/mcp-filter.js`) with `browser_run_code_unsafe` denied, and uses the exchange
  directory as the workspace root so `browser_file_upload` cannot reach the token file.
  Closes the gap recorded earlier the same day: the code-execution tool ran as the secrets
  user and could read the token and the cookie jar, and no server flag could remove it.
- README corrected twice: first to record that gap honestly, then to drop `browser_evaluate`
  from it (page context, not server process) and add the upload path.
- `bin/mcp-server` pins `@playwright/mcp` instead of `@latest`.
- Paths, user and group names are overridable through `SECURE_BROWSER_*` variables;
  the guard hook no longer hardcodes a home directory.
- Skill, `CLAUDE.md` section and hook registration moved into `claude/` so the three
  enforcement layers ship together.
- First public cut. Site files are gitignored; only the template ships.

## 2026-10-12

- Credential store moved from a local `pass` store to 1Password: `op read` with a
  service-account token held by the secrets user. `login --check-secrets <site>` proves
  the store path without typing anything. Old `pass` store deleted.
- `login` waits out remembered-device interstitials instead of returning NEEDS-HUMAN.
- Guard hook switched to `enforce`.

## 2026-10-11

- Installer run end to end. Fixes: shebang sed delimiter, Node 20+ preflight,
  `python3-venv` and venv rebuild, `install-deps` as root.
- Login helper: visible-first selectors, auth-cookie success check, screenshot and URL
  on NEEDS-HUMAN and on failure.
- MCP server runs `--isolated --storage-state` so it shares the helper's session.
