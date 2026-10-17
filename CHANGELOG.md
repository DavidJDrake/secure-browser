# Changelog

## 2026-10-17

- **`secure-browser-add-site`.** Publishing a site file no longer needs the full installer.
  `sudo secure-browser-add-site sites.d/<site>.json` validates one file (https origin,
  `login_url` on that origin, `op://` references only, required selectors), shows the
  origin and references it binds plus any origin or reference change against the
  published copy, requires typing the site name on the terminal, and writes it
  root:root 644 atomically. `--remove <site>` unregisters. Installed as a root-owned copy
  in `/opt/secure-browser/bin/add-site`, linked from `/usr/local/sbin`; not in the NOPASSWD
  rule. 1Password item changes still need no root step at all.

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
