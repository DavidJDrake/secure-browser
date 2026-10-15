# History: the original working tree

This is the README of the private working tree as it stood on 2026-10-14, the day the
project went public, kept because the public README was rewritten the same day and the
write-up refers back to this one. It documents the first three days of use (2026-10-11 to
2026-10-14), the 1Password migration, and the "Known gap" section as it was written when
the code-execution path was found in a self-audit and before the fix landed. Paths and
names in it are the private ones (`~/projects`, `pwagent`), and its "Known gap — closed"
section was the last edit before the tree was retired. Nothing here is current; the public
README is.

---

Browser automation for `~/projects` where **the agent can use an authenticated session but
cannot read the credential that created it.**

## Why

An agent driving a browser needs to log in. The naive approach — a password in a file the
agent reads — puts the credential into model context, which is transmitted to an API,
summarised, and persisted in transcripts. Moving it to an encrypted store helps, but if the
agent can run `pass show`, the store is a convention rather than a boundary.

Here the credential is owned by a **separate OS user**. The Playwright MCP server runs as
that user, so the agent drives an authenticated browser while the calling user, and
therefore the agent's shell, file and search tools, cannot read the vault token, the
credentials, or the session cookies.

**What this is meant to buy:** the credential cannot be exfiltrated into a transcript, an
API, a log, or anything outliving the session.

**What it does not buy today, see the next section:** the MCP server exposes tools that run
arbitrary code *as the secrets user*, so the boundary currently holds against the agent's
own tools but not against the browser server it is handed. Until that is closed, the
honest description is: the credential is not visible by default, not unreadable.

**What it does not buy by design:** it does not stop the agent doing something undesirable
*while* driving an authenticated browser. That risk is accepted and controlled by the
user's approval gates on outward-facing actions.

## Known gap — closed 2026-10-14

The launcher in *this* tree (`bin/mcp-server`) still runs `@playwright/mcp@latest` as
`pwagent` with no tool restriction, so it still exposes `browser_run_code_unsafe` (Node code
in the secrets user's process: can read the service-account token and the cookie jar) and
`browser_file_upload` rooted at `$HOME` (token file uploadable to any site).
`browser_evaluate` was never part of it; it runs in the page.

**Do not install from this tree.** The fix landed the same day in the public tree and is
what `/opt/secure-browser` now runs: the server sits behind
[mcp-tool-gate](https://github.com/DavidJDrake/mcp-tool-gate) (vendored as
`bin/mcp-filter.js`, root-owned, executed as `pwagent`) with `run_code_unsafe` dropped from
`tools/list` and refused on `tools/call`; the launcher's working directory is the exchange
directory, not `$HOME`; and the server version is pinned to 0.0.83. Verified on this
machine 2026-10-14 ~21:00: 24 tools listed, the unsafe tool absent and refused. The
"Tool filtering" section of the public README is the current description. Optional
follow-up still open there: a third user that owns the cookie file but not the token.

## Layout

```
secure-browser/
  bin/            login helper and exchange commands (run as the secrets user)
  sites.d/        one JSON per site: login URL, expected origin, selectors, store paths
  hooks/          PreToolUse guard + mode file + guard.log
  setup/          privileged installer (run by a human)
  exchange/       setgid shared dir — the only path both users touch
```

## Three enforcement layers

| Layer | Where | Strength |
|---|---|---|
| Skill | `~/projects/.claude/skills/secure-browser/` | procedures, fires on description match |
| Instruction | `~/projects/CLAUDE.md` | always loaded under `~/projects` |
| Hook | `hooks/guard-playwright.py` | deterministic — denies the unscoped server. Guards MCP tool calls only; it does not restrict what the secure server itself can run (bounded by the tool-filter proxy in the public tree; see "Known gap — closed") |

The hook has three modes in `hooks/mode`:

- **`warn`** — logs violations to `hooks/guard.log`, allows the call. Correct until
  the secure server is actually running.
- **`enforce`** (current since 2026-10-12) — denies any Playwright call under `~/projects`
  that is not on the `playwright-secure` server.
- **`off`**.

**Leave it on `warn` until `setup/install.sh` has run and a login works end to end.**
Switching to `enforce` first makes all browser automation fail.

## Credential store

**1Password**, read with the `op` CLI as the secrets user, using a **service account** whose token lives at `/home/pwagent/.config/op/service-token` (mode 600, directory 700). The calling user cannot read the token, and the helper never prints it or passes it in argv; it goes into the child environment of `op read` and nowhere else.

The token is the root secret, in the same position the passphrase-less GPG key held before 2026-10-12: unattended by design, protected by the **OS user boundary**. Two consequences shape the setup:

- **Scope it to one vault.** A service-account token is cloud-scoped: whoever holds it can read every vault it was granted, from anywhere. So the service account gets **read-only access to a single vault, `secure-browser`**, which holds only the credentials automations are allowed to read. Private and family vaults are never granted. (1Password will not grant a service account a Private vault in any case.)
- **Login now needs the network.** `op read` calls 1password.com. An outage or DNS failure shows up as `FAILED <site>: 1Password unreachable`.

Site files reference fields as `op://secure-browser/<item title>/<field>`. The user manages the items in the 1Password apps like any other login; the same item serves both the user and the helper, so a password rotation is one edit. Legacy `pass` entries (no `op://` prefix) still resolve through the old local store if one exists.

Setup, done by the user in the 1Password web app: create the vault, move or create the Login item (default `username`/`password` field names), create the service account under Developer with read access to that vault only, and paste its token into the installer's hidden prompt. Keep a copy of the token in the user's Private vault; 1Password shows it once.

## Install

**Prerequisite: a system-wide Node 20+.** The MCP server runs as `pwagent` under `sudo`, which
resets `PATH` to `secure_path`, so your nvm Node is invisible to it. Ubuntu's apt `nodejs` is
18.x and `@playwright/mcp` refuses it. The installer checks this and stops if it is missing.

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs
/usr/bin/node -v                  # must print v20 or higher
```

The installer also needs `python3-venv` for the agent user's Playwright venv. Ubuntu's `python3`
ships without it, and a venv built without it has no `pip`. The installer apt-installs it itself
and rebuilds a pip-less venv, so a re-run after a failed step 8 is safe.

```bash
sudo bash setup/install.sh        # creates the user, group, exchange, sudoers rule, /opt copy
newgrp browseragent               # group membership does NOT apply to already-open shells
secure-browser status             # should show everything present
```

Then store the credentials, which only you can do: create the Login item in the 1Password
vault `secure-browser` and paste the service-account token when the installer prompts for
it (step 5). The `op://` references in the matching `sites.d/*.json` must name that vault,
item title and field. The `pass insert` path from before 2026-10-12 is gone; see
"Credential store".

## Registering the server

Add to `~/.claude.json` at user scope, so every project under `~/projects` picks it up:

```json
"mcpServers": {
  "playwright-secure": {
    "command": "sudo",
    "args": ["-n", "-u", "pwagent", "/opt/secure-browser/bin/mcp-server"]
  }
}
```

The name must stay **`playwright-secure`** — the guard hook recognises the hardened server by that string in the tool name.

### How a login reaches the MCP server

`login` signs in with Playwright-Python and saves the cookies to
`~pwagent/.browser-profile/storage-state.json` (one file for all sites, mode 600). The MCP server
runs `--isolated` and seeds its context from that file **at startup only**. So the order is:

1. `secure-browser login linkedin` → `OK ... session saved`
2. start a new Claude Code session (the server is spawned at startup and reads the file then)

A login done while a session is open does not reach the already-running server. Cookies the agent
picks up during a session are in memory only and are discarded at exit; the helper's file is the
source of truth. Rerun `login` whenever the agent reports it is signed out. (Since 2026-10-12
`login` is also safe to run mid-session: it reports `existing session reused` without touching
the credential when the saved cookies are still valid.)

## Everyday use

```bash
secure-browser status                  # what is installed and what is not
secure-browser login linkedin          # OK / FAILED / NEEDS-HUMAN, one line
secure-browser put ./resume.pdf        # stage a file for upload, prints the path
secure-browser ls                      # what is staged
secure-browser clean resume.pdf        # remove it again
```

## Why the registry is not editable by your normal user

`sites.d/*.json` says **where a credential gets typed**. A site file therefore carries the same authority as the credential itself: anyone who can edit one can point a password at a host they control. So the registry is installed to root-owned `/opt` alongside the executables, and **adding a site means re-running the installer**.

That is real friction, and it is the price of the guarantee. The same reasoning applies to `bin/login` — if your user could edit the script that runs as the secrets user, the boundary would be decorative.

## Error taxonomy

`login` prints exactly one line and nothing else.

| Output | Meaning |
|---|---|
| `OK <site>: existing session reused` | cookies still valid; no credential was touched |
| `OK <site>: signed in, session saved` | credential used, session persisted |
| `NEEDS-HUMAN <site>: ...` | captcha, MFA or an interstitial. Stop and tell the user; do not attempt it |
| `FAILED <site>: origin mismatch ...` | the page was not where it should be. **Nothing was typed.** Treat as hostile, do not retry blind |
| `FAILED <site>: no item or field at 'op://...'` | vault, item title or field name does not match 1Password, or the service account cannot read that vault |
| `FAILED <site>: 1Password rejected the service-account token` | token revoked, mistyped, or not granted this vault; create a new one and re-run the installer |
| `FAILED <site>: 1Password unreachable` | network or DNS from this machine; retry later |
| `FAILED <site>: 1Password service-account token missing` | installer has not stored a token yet |
| `FAILED <site>: no entry ... in the password store` | legacy `pass` entry referenced and not stored |
| `FAILED <site>: playwright is not installed ...` | environment, not security |
| `FAILED <site>: <ExceptionType> in the login helper` | unexpected. Detail goes to `~pwagent/login-errors.log`, mode 600 |

A traceback is never printed, because it can carry page fragments or the value. The exception **type** is printed, because an opaque failure is its own kind of risk.

## Status — 2026-10-12 (1Password migration)

Credential store moved from the local `pass` store to 1Password (`op read` + service account), see "Credential store". `bin/login` resolves `op://` references; `sites.d/linkedin.json` points at `op://secure-browser/LinkedIn/*`; installer step 5 installs `1password-cli` and stores the token. **Verified 2026-10-12 20:40:** `login --check-secrets linkedin` → `OK linkedin: username resolved from 1Password (…); password resolved from 1Password (…)` as pwagent. `login` also now waits out LinkedIn's remembered-device "We're signing you in" page (up to 25 s) instead of returning NEEDS-HUMAN. The old `pass` store was deleted 2026-10-12; the GPG key and `pass` package remain installed but unused.

## Status — 2026-10-11

| Piece | State |
|---|---|
| Skill, `CLAUDE.md`, guard hook | ✅ built; hook tested four ways, in **warn** mode |
| `setup/install.sh` | ✅ run 2026-10-11. Fixed since: shebang sed delimiter, Node 20+ preflight, python3-venv + venv rebuild |
| `bin/login` | ✅ runs end to end under the pwagent venv. LinkedIn selectors updated 2026-10-11 (React form, no `#username`); `.first` on locators; screenshot + URL on NEEDS-HUMAN and on failure; `li_at` cookie counts as signed in. **Sign-in confirmed 2026-10-11: `OK linkedin: signed in, session saved`** |
| `bin/secure-browser` | ✅ written; all failure paths tested |
| `bin/mcp-server` | ✅ answers `initialize` as pwagent from the project dir (2026-10-11). Now `--isolated --storage-state` so it shares the helper's session. **Needs a fresh Claude Code session to connect** |
| `sites.d/linkedin.json` | ✅ points at `web/linkedin/*` in the store |
| Credentials in the store | ⏳ yours to insert |
| End-to-end login | ⏳ blocked on the two above |
| Hook `enforce` mode | ⏳ flip only after a login works end to end |

**Known untested:** whether the secrets user can reach the WSLg display for headed mode, and whether MCP stdio survives the `sudo` boundary cleanly. Both look right on paper and neither can be confirmed until the installer runs.
