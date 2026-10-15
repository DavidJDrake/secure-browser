---
name: secure-browser
description: "Use this skill for ANY browser automation that touches an authenticated site — logging into a web application, filling an application or portal form, reading a signed-in page, posting or messaging, or anything needing a credential. Trigger whenever Playwright or a browser is used against a site that requires sign-in, whenever a password, token, session or cookie is involved, and whenever a login fails or a session has expired. Also trigger when adding a new site to automation, when a file must be uploaded to or downloaded from a site, and when deciding where a credential should live. Do NOT trigger for unauthenticated fetches, public pages, public JSON APIs, or local HTML."
---

# Secure browser automation

Credentials for automated sites live in **1Password, read through a service-account token
owned by a separate OS user** (the secrets user, `pwagent` by default). This session runs as
the normal user and **cannot read them** — that is the point, not an obstacle to route around.

## The boundary

| Thing | Owner | Readable by this session |
|---|---|---|
| 1Password service-account token | `~pwagent/.config/op/service-token`, mode 600 | **no** |
| Site credentials | 1Password vault `secure-browser`, read-only to that token | **no** |
| Browser profile + cookies | secrets user, mode 700 | **no** |
| Exchange directory | shared group | yes |
| Page content, screenshots | — | yes |

Drive the browser through the **`mcp__playwright-secure__*`** tools. They run as the
secrets user, so an authenticated session is usable without any credential being visible here.

**Known gap, until the project's README says otherwise:** the secure server exposes
`browser_run_code_unsafe`, which runs Node code as the secrets user. Do not use it to read
files, environment variables, cookies or anything outside the page. Use it for page
interaction only, and prefer `browser_evaluate` (page context) and the click, type, snapshot
and navigate tools. Never pass a path outside the exchange directory to `browser_file_upload`.

## Rules

1. **Never type a credential yourself.** No `page.fill()` with a password, no reading a
   password from a file, env var, or the user's message and entering it. Call the login
   helper and let it resolve the secret in its own process.
2. **Never fall back to the unscoped Playwright server** when the secure one is unavailable.
   Say it is down. A fallback puts session cookies in a profile this session can read,
   which silently removes the boundary.
3. **Never copy a credential into context** — not into a file, a log, a commit, a report, or
   a reply. If one appears on screen or in a page, do not transcribe it.
4. **An authenticated session is still the user's identity.** The boundary protects the
   credential, not against misuse. Destructive or outward-facing actions — posting,
   messaging, submitting, deleting — still need the user's approval per their standing rules.

## Logging in

```bash
secure-browser login <site>          # prints: OK <site> | FAILED <site>: <reason>
```

Resolves the credential inside its own process, verifies the page origin matches the one
registered for that site, and refuses to type anything if it does not. Session death is
routine — just call it again.

If it returns `FAILED ... needs human`, the site is asking for something only the user can
supply (a captcha, a device confirmation). Report that and stop; do not attempt to solve it.

## File exchange

Both users can read and write the exchange directory (`/srv/secure-browser-exchange` by
default; `secure-browser status` prints it) and nothing else in common.

**Upload:** copy the file in, upload from there, delete it.

```bash
secure-browser put ./path/to/upload.pdf     # -> exchange/, returns the path to use
# ... upload via the browser ...
secure-browser clean upload.pdf
```

**Download:** the browser writes to `exchange/`; move it out, then clean.

Never point an upload at a path outside `exchange/` — the browser user cannot read your
project directories, and the failure is usually silent in the page rather than loud in the
terminal. **Always verify the upload landed** by checking the page, not the exit code.

## Adding a site

Add `sites.d/<site>.json` with the login URL, the expected origin, the field selectors, and
the `op://secure-browser/<item>/<field>` references. Then the user creates that Login item in the
`secure-browser` vault in 1Password (the vault the service account can read). The user does that
part — this session cannot write to 1Password.

## Errors worth knowing

| Symptom | Cause |
|---|---|
| `FAILED: origin mismatch` | the page redirected somewhere unregistered — treat as hostile, do not retry blind |
| `FAILED: no item or field at 'op://...'` | item missing in 1Password or the service account cannot read that vault; ask the user |
| `FAILED: 1Password rejected the service-account token` | token revoked or mis-scoped; the user creates a new one and re-runs the installer |
| `FAILED: 1Password unreachable` | network; retry later, do not fall back |
| upload silently does nothing | file was outside `exchange/`, or was cleaned too early |
