#!/usr/bin/env python3
"""PreToolUse guard: keep browser automation under ROOT on the secure server.

Wired in settings as a PreToolUse hook matching the Playwright MCP tools.
Reads the tool call as JSON on stdin and either stays silent (allow) or emits a
deny decision.

Modes, from hooks/mode (default "warn"):
  warn     - log the violation, allow the call. Use until the secure server works.
  enforce  - deny calls to the unscoped Playwright server when cwd is under ROOT.
  off      - do nothing.

Exit 0 with no stdout means "no opinion", which leaves normal permission flow intact.
"""
import json
import os
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
# The directory tree the guard applies to. Default: ~/projects of the user
# running the session. Override with SECURE_BROWSER_ROOT.
ROOT = pathlib.Path(os.environ.get("SECURE_BROWSER_ROOT", "~/projects")).expanduser().resolve()
LOG = HERE / "guard.log"
MODE_FILE = HERE / "mode"

# The hardened server. Anything else driving a browser under ROOT is a violation.
SECURE_SERVER = "playwright-secure"


def mode() -> str:
    try:
        m = MODE_FILE.read_text().strip().lower()
        return m if m in {"warn", "enforce", "off"} else "warn"
    except OSError:
        return "warn"


def log(msg: str) -> None:
    try:
        with LOG.open("a") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {msg}\n")
    except OSError:
        pass


def deny(reason: str) -> None:
    json.dump({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}, sys.stdout)
    sys.stdout.write("\n")


def main() -> int:
    m = mode()
    if m == "off":
        return 0

    try:
        event = json.load(sys.stdin)
    except Exception:
        return 0                      # never break the session on a parse error

    tool = event.get("tool_name", "")
    if "playwright" not in tool.lower():
        return 0

    if SECURE_SERVER in tool:         # already on the hardened server
        return 0

    cwd = event.get("cwd") or os.getcwd()
    try:
        under_root = ROOT == pathlib.Path(cwd).resolve() or ROOT in pathlib.Path(cwd).resolve().parents
    except Exception:
        under_root = False
    if not under_root:
        return 0                      # outside ROOT this guard does not apply

    msg = (f"{tool} from {cwd}")
    if m == "warn":
        log(f"WARN  {msg}")
        return 0

    log(f"DENY  {msg}")
    deny(
        f"Browser automation under {ROOT} must run on the hardened Playwright "
        f"server ('{SECURE_SERVER}'), which executes as the secrets user and holds "
        "credentials this session cannot read. The unscoped Playwright server would "
        "place session cookies in a profile readable by this user, which defeats the "
        "credential boundary.\n\n"
        "Use the mcp__playwright-secure__* tools instead, and see the secure-browser "
        "skill for the login and file-exchange protocol. If the secure server is not "
        "running, say so rather than falling back."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
