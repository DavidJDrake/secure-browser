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

**What this is meant to buy:** the credential cannot be exfiltrated into a transcript, an
API, a log, or anything outliving the session.

**What it does not buy today, see the next section:** the stock MCP server exposes tools
that run arbitrary code *as the secrets user*, so the boundary currently holds against the
agent's own tools but not against the browser server it is handed. Until that is closed,
the honest description is: the credential is not visible by default, not unreadable.

**What it does not buy by design:** it does not stop the agent doing something undesirable
*while* driving an authenticated browser. That risk is accepted and controlled by the
user's approval gates on outward-facing actions.

## Known gap (open as of 2026-10-14)

`bin/mcp-server` launches `@playwright/mcp` as the secrets user. The stock server includes
`browser_run_code_unsafe`, which runs arbitrary Node code inside the server process. That
process runs as the secrets user, so a call that reads
`~<secrets user>/.config/op/service-token` or `~<secrets user>/.browser-profile/storage-state.json`
from inside `run_code_unsafe` succeeds, and so does `page.context().cookies()`. The agent can
therefore reach the root secret through the one channel the design gives it, and with the
token it can `op read` every item in the vault the service account was granted.

Two smaller paths lead the same way. `browser_file_upload` can attach any file under the
server's workspace root to a form, and the launcher's workspace root is the secrets user's
home, so the token file is uploadable to any site. And `browser_evaluate` is *not* part of
this: it runs in the page, not the server process, and cannot read files or HttpOnly
cookies. An earlier version of this section listed it; that was wrong.

What still holds: the agent's shell, file and search tools run as the calling user and
cannot read any of those files. The gap was found by the author in a self-audit before
publishing, not through an incident.

`run_code_unsafe` is in the server's core tool set. As of `@playwright/mcp` 0.0.83, `--caps`
only *adds* optional capabilities (vision, pdf, devtools) and neither the command line nor
the config file can remove a core tool. So the fix is not a flag:

1. **A filtering layer.** Run a thin MCP proxy in front of the server that drops
   `run_code_unsafe` from `tools/list` and refuses `tools/call` for it, installed root-owned
   and executed as the secrets user like everything else. A client-side deny (a Claude Code
   permission rule or the PreToolUse hook) is not a substitute: both live in files the
   calling user, and so the agent, can edit. This is the planned fix. Alongside it, the
   launcher's working directory moves from the secrets user's home to the exchange
   directory, which closes the upload path.
2. **Pin the server version.** Done: `bin/mcp-server` pins `@playwright/mcp`, because an
   unpinned `npx --yes ...@latest` as the secrets user is an unreviewed install executing
   with access to the token.
3. **Split roles.** Run the browser server as a user that holds the cookie file but not the
   vault token, so even code execution in the server cannot reach the vault. The login
   helper stays with the token holder. This changes the installer.

Until 1 or 3 lands, the shipped skill tells the agent not to use `run_code_unsafe` for
anything but page interaction. That is an instruction, not a boundary, and this section
says so. It goes away when the fix lands.

## Layout

```
secure-browser/
  bin/            login helper, MCP server launcher, caller-side CLI
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
| Hook | `hooks/guard-playwright.py` | deterministic: denies any Playwright MCP call under the root that is not on the `playwright-secure` server. It guards which server is called, not what that server can run (see "Known gap") |

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
