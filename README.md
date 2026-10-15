# secure-browser

Browser automation for coding agents where **the agent can use an authenticated session
but cannot read the credential that created it.**

Built for Claude Code and the Playwright MCP server, on Linux. The pattern is not specific
to either: a login helper and a browser server run as a separate OS user, the agent talks
to the browser over MCP, and the credential never enters the agent's process, files, or
transcript.

## Why

An agent driving a browser needs to log in. The naive approach, a password in a file the
agent reads, puts the credential into model context, which is transmitted to an API,
summarised, and persisted in transcripts. Moving it to an encrypted store helps, but if the
agent can run the store's `show` command, the store is a convention rather than a boundary.

Here the credential is owned by a **separate OS user**. The Playwright MCP server runs as
that user, so the agent drives an authenticated browser while the calling user, and
therefore the agent's shell, file and search tools, cannot read the vault token, the
credentials, or the session cookies.

**What this buys:** the credential cannot be exfiltrated into a transcript, an API, a log,
or anything outliving the session. The server's code-execution tool, which would have
been the way around that, is removed by a proxy that runs with the server (see "Tool
filtering").

**What it does not buy by design:** it does not stop the agent doing something undesirable
*while* driving an authenticated browser. That risk is accepted and controlled by the
user's approval gates on outward-facing actions.

## Tool filtering

The stock `@playwright/mcp` server includes `browser_run_code_unsafe`, which runs arbitrary
Node code inside the server process. Here that process is the secrets user, so the tool
could read the service-account token, dump the cookie jar with `page.context().cookies()`,
or `op read` the vault. `--caps` only *adds* capabilities and neither the command line nor
the config file can remove a core tool (checked against 0.0.83).

So `bin/mcp-server` does not run the server directly. It runs
[mcp-tool-gate](https://github.com/DavidJDrake/mcp-tool-gate), vendored as
`bin/mcp-filter.js`, which spawns the server, strips `run_code_unsafe` from every
`tools/list` reply, and answers any call to it with a JSON-RPC error. The gate is one
dependency-free file, installed root-owned in `/opt` and executed as the secrets user, so
the agent can neither call the tool nor edit the rule. Refusals are logged to the secrets
user's home. `browser_evaluate` stays: it runs in the page, not the server process.

A client-side deny (a Claude Code permission rule or the PreToolUse hook) would not do:
both live in files the calling user, and therefore the agent, can edit.

The launcher also runs with the exchange directory as its working directory rather than
the secrets user's home. The server treats cwd as the workspace root and
`browser_file_upload` will attach any file under it, so with `$HOME` as the root the token
file was uploadable to any site.

**History.** Both paths were found by the author in a self-audit before the first public
commit, not through an incident, and the README of that commit recorded them as an open
gap while this fix was built. Remaining optional hardening: run the browser server as a
third user that holds the cookie file but not the vault token, so that even a future
code-execution tool upstream could not reach the vault.

## Layout

```
secure-browser/
  bin/            login helper, MCP server launcher, tool-filter proxy, caller-side CLI
  sites.d/        one JSON per site: login URL, expected origin, selectors, secret refs
  hooks/          PreToolUse guard that denies the unscoped Playwright server
  setup/          privileged installer (run by a human)
  claude/         the skill, the CLAUDE.md section and the hook registration
  CHANGELOG.md    dated history
```

## Three enforcement layers

| Layer | Where | Strength |
|---|---|---|
| Skill | `claude/skills/secure-browser/SKILL.md` | procedures; fires on description match |
| Instruction | `claude/CLAUDE.md.snippet`, pasted into the project's `CLAUDE.md` | always loaded |
| Hook | `hooks/guard-playwright.py` | deterministic: denies any Playwright MCP call under the root that is not on the `playwright-secure` server. It guards which server is called; what that server can run is bounded by the tool filter (see "Tool filtering") |

The hook has three modes in `hooks/mode` (missing file means `warn`):

- **`warn`**: logs violations to `hooks/guard.log`, allows the call. Correct until the
  secure server is actually running.
- **`enforce`**: denies any Playwright call under the root that is not on the
  `playwright-secure` server.
- **`off`**.

Leave it on `warn` until `setup/install.sh` has run and a login works end to end.
Switching to `enforce` first makes all browser automation fail.

## Credential store

**1Password**, read with the `op` CLI as the secrets user, using a **service account** whose
token lives at `~<secrets user>/.config/op/service-token` (mode 600, directory 700). The
calling user cannot read the token, and the helper never prints it or passes it in argv; it
goes into the child environment of `op read` and nowhere else.

The token is the root secret: unattended by design, protected by the OS user boundary. Two
consequences shape the setup:

- **Scope it to one vault.** A service-account token is cloud-scoped: whoever holds it can
  read every vault it was granted, from anywhere. So the service account gets **read-only
  access to a single vault**, which holds only the credentials automations are allowed to
  read. Private and shared vaults are never granted.
- **Login needs the network.** `op read` calls 1password.com. An outage shows up as
  `FAILED <site>: 1Password unreachable`.

Site files reference fields as `op://<vault>/<item title>/<field>`. The user manages the
items in the 1Password apps like any other login; the same item serves both the user and
the helper, so a password rotation is one edit. Legacy `pass` entries (no `op://` prefix)
still resolve through a local `pass` store if one exists.

Setup, done by the user in the 1Password web app: create the vault, create the Login items
(default `username`/`password` field names), create a service account under Developer
with read access to that vault only, and paste its token into the installer's hidden
prompt. 1Password shows the token once; keep a copy in your own Private vault.

## Install

**Prerequisite: a system-wide Node 20+.** The MCP server runs as the secrets user under
`sudo`, which resets `PATH` to `secure_path`, so a user-level nvm Node is invisible to it.
Debian and Ubuntu's apt `nodejs` is too old for `@playwright/mcp`. The installer checks and
stops if it is missing.

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs
/usr/bin/node -v                  # must print v20 or higher
```

The installer also needs `python3-venv` for the secrets user's Playwright venv and installs
it itself.

```bash
sudo bash setup/install.sh        # user, group, exchange dir, sudoers rule, /opt copy, op CLI, token
newgrp browseragent               # group membership does NOT apply to already-open shells
secure-browser status             # should show everything present
```

Names and paths are overridable with `SECURE_BROWSER_AGENT_USER`, `SECURE_BROWSER_GROUP`,
`SECURE_BROWSER_INSTALL` and `SECURE_BROWSER_EXCHANGE`, set for the installer and for the
caller-side CLI alike. Defaults: `pwagent`, `browseragent`, `/opt/secure-browser`,
`/srv/secure-browser-exchange`.

Then add a site: copy `sites.d/EXAMPLE-ats.json.template` to `sites.d/<site>.json`, fill it
in, create the matching Login item in the vault, and re-run the installer. Real site files
are gitignored on purpose; see `sites.d/README.md`.

## Registering the server

Add to `~/.claude.json` (user scope) or the project's `.mcp.json`:

```json
"mcpServers": {
  "playwright-secure": {
    "command": "sudo",
    "args": ["-n", "-u", "pwagent", "/opt/secure-browser/bin/mcp-server"]
  }
}
```

The name must stay **`playwright-secure`**: the guard hook recognises the hardened server
by that string in the tool name. Register the hook with the block in
`claude/settings.hooks.json`, and paste `claude/CLAUDE.md.snippet` into the project's
`CLAUDE.md`. Copy `claude/skills/secure-browser/` into the project's `.claude/skills/`.

### How a login reaches the MCP server

`login` signs in with Playwright-Python and saves the cookies to
`~<secrets user>/.browser-profile/storage-state.json` (one file for all sites, mode 600). The
MCP server runs `--isolated` and seeds its context from that file **at startup only**. So:

1. `secure-browser login <site>` → `OK ... session saved`
2. start a new agent session; the server is spawned at startup and reads the file then

A login done while a session is open does not reach the already-running server. Cookies the
agent picks up during a session are in memory only and are discarded at exit; the helper's
file is the source of truth. `login` is safe to run at any time: when the saved cookies are
still valid it reports `existing session reused` without touching the credential.

## Everyday use

```bash
secure-browser status                  # what is installed and what is not
secure-browser login <site>            # OK / FAILED / NEEDS-HUMAN, one line
secure-browser login <site> --check-secrets   # prove the store path; nothing is typed
secure-browser put ./upload.pdf        # stage a file for upload, prints the path
secure-browser ls                      # what is staged
secure-browser clean upload.pdf        # remove it again
```

## Why the registry is not editable by your normal user

`sites.d/*.json` says **where a credential gets typed**. A site file therefore carries the
same authority as the credential itself: anyone who can edit one can point a password at a
host they control. So the registry is installed to root-owned `/opt` alongside the
executables, and **adding a site means re-running the installer**.

That is real friction, and it is the price of the guarantee. The same reasoning applies to
`bin/login`: if your user could edit the script that runs as the secrets user, the boundary
would be decorative.

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
| `FAILED <site>: playwright is not installed ...` | environment, not security |
| `FAILED <site>: <ExceptionType> in the login helper` | unexpected. Detail goes to `~<secrets user>/login-errors.log`, mode 600 |

A traceback is never printed, because it can carry page fragments or the value. The
exception **type** is printed, because an opaque failure is its own kind of risk.

## Status

See `CHANGELOG.md`. The design has been in daily use by the author since 2026-10-11.

## License

MIT. See `LICENSE`.
