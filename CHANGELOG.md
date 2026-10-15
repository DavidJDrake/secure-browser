# Changelog

## 2026-10-14

- README corrected: the agent's own tools cannot read the token or cookies, but the
  Playwright MCP server's code-execution tools run as the secrets user and can. Recorded
  as a known gap; see README.
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
