#!/usr/bin/env bash
# Privileged installer for secure-browser. Run it yourself:
#
#     sudo bash setup/install.sh
#
# Creates the secrets user, the shared exchange group, the setgid exchange
# directory, the sudoers rule, and installs the executables to /opt where your
# own user CANNOT modify them.
#
# Why /opt and not the repo: the login helper runs AS the secrets user. If the
# calling user could edit that script, they could rewrite it to print the vault
# config, and the whole boundary would be decorative. Development happens in the
# repo; this script copies a frozen copy to root-owned /opt.
set -euo pipefail

AGENT_USER="${SECURE_BROWSER_AGENT_USER:-pwagent}"
SHARE_GROUP="${SECURE_BROWSER_GROUP:-browseragent}"
CALLER="${SUDO_USER:-}"
INSTALL_DIR="${SECURE_BROWSER_INSTALL:-/opt/secure-browser}"
EXCHANGE="${SECURE_BROWSER_EXCHANGE:-/srv/secure-browser-exchange}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUDOERS="/etc/sudoers.d/secure-browser"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -n "$CALLER" ]      || { echo "run via sudo from your normal user, not as root directly"; exit 1; }

say(){ printf '\n==> %s\n' "$*"; }

# The MCP server runs as the agent user under sudo, which resets PATH to
# secure_path. The caller's nvm node is invisible there; only a SYSTEM node
# counts, and @playwright/mcp needs Node 20+. Check with sudo's own PATH.
SYS_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SYS_NODE_MAJOR="$(/usr/bin/env -i PATH="$SYS_PATH" node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$SYS_NODE_MAJOR" -lt 20 ]; then
  echo "system node is $(/usr/bin/env -i PATH="$SYS_PATH" node -v 2>/dev/null || echo missing); @playwright/mcp needs Node 20+ on the SYSTEM path (nvm does not count)."
  echo "Install one first, e.g. NodeSource: curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs"
  exit 1
fi

say "1/8  secrets user and shared group"
getent group "$SHARE_GROUP" >/dev/null || groupadd "$SHARE_GROUP"
if ! id "$AGENT_USER" >/dev/null 2>&1; then
  # needs a real shell: it execs node/npx. Login is disabled via password lock.
  useradd --create-home --shell /bin/bash "$AGENT_USER"
  passwd -l "$AGENT_USER" >/dev/null
fi
usermod -aG "$SHARE_GROUP" "$AGENT_USER"
usermod -aG "$SHARE_GROUP" "$CALLER"
chmod 750 "/home/$AGENT_USER"          # caller cannot read the agent's home
echo "    $AGENT_USER ready; $CALLER added to $SHARE_GROUP"

say "2/8  exchange directory (the only path both users share)"
mkdir -p "$EXCHANGE"
chown "$CALLER:$SHARE_GROUP" "$EXCHANGE"
chmod 2770 "$EXCHANGE"                 # setgid: new files inherit the group
command -v setfacl >/dev/null && setfacl -d -m g::rwx "$EXCHANGE" 2>/dev/null || true
echo "    $EXCHANGE  (2770, setgid, group $SHARE_GROUP)"

say "3/8  installing executables to $INSTALL_DIR (not writable by $CALLER)"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/sites.d"
# Rewrite the shebang to the agent user's venv. Do NOT use '#' as the sed
# delimiter here: it swallows the '#' of '#!' and the kernel falls back to sh.
sed '1s|.*|#!/home/'"$AGENT_USER"'/.venv/bin/python3|' "$REPO/bin/login" > "$INSTALL_DIR/bin/login"
head -c 2 "$INSTALL_DIR/bin/login" | grep -q '^#!' || { echo "    FAILED: login shebang rewrite produced a non-#! first line"; exit 1; }
cp "$REPO/bin/mcp-server"       "$INSTALL_DIR/bin/mcp-server"
cp "$REPO/bin/secure-browser"   "$INSTALL_DIR/bin/secure-browser"
ln -sf "$INSTALL_DIR/bin/secure-browser" /usr/local/bin/secure-browser
cp "$REPO"/sites.d/*.json       "$INSTALL_DIR/sites.d/" 2>/dev/null || true
chown -R root:root "$INSTALL_DIR"
chmod -R 755 "$INSTALL_DIR"
chmod 644 "$INSTALL_DIR"/sites.d/*.json 2>/dev/null || true
echo "    installed, root-owned. Re-run this script after editing bin/ or sites.d/."

say "4/8  sudoers rule (exact commands only, no wildcards on the binary)"
cat > "$SUDOERS" <<SUDO
# secure-browser: $CALLER may run these two commands as $AGENT_USER without a password.
# Scoped to absolute paths under root-owned $INSTALL_DIR so the target cannot be swapped.
$CALLER ALL=($AGENT_USER) NOPASSWD: $INSTALL_DIR/bin/mcp-server
$CALLER ALL=($AGENT_USER) NOPASSWD: $INSTALL_DIR/bin/login *
SUDO
chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null && echo "    $SUDOERS validated" || { rm -f "$SUDOERS"; echo "SUDOERS INVALID - removed"; exit 1; }

say "5/8  1Password CLI and service-account token for $AGENT_USER"
# The credential store is 1Password. The login helper runs `op read op://...`
# as the agent user with a SERVICE ACCOUNT token that lives in the agent's
# home, mode 600. The token is the root secret here, exactly as the
# passphrase-less GPG key was before: unattended by design, protected by the
# OS user boundary. Scope it to the one vault automations may read.
if ! command -v op >/dev/null 2>&1; then
  echo "    installing 1password-cli from the 1Password apt repository"
  ARCH="$(dpkg --print-architecture)"
  curl -sS https://downloads.1password.com/linux/keys/1password.asc \
    | gpg --dearmor --yes --output /usr/share/keyrings/1password-archive-keyring.gpg
  echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$ARCH stable main" \
    > /etc/apt/sources.list.d/1password.list
  mkdir -p /etc/debsig/policies/AC2D62742012EA22/ /usr/share/debsig/keyrings/AC2D62742012EA22
  curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol \
    > /etc/debsig/policies/AC2D62742012EA22/1password.pol
  curl -sS https://downloads.1password.com/linux/keys/1password.asc \
    | gpg --dearmor --yes --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq 1password-cli >/dev/null 2>&1 || { echo "    FAILED to install 1password-cli; see https://developer.1password.com/docs/cli/get-started/"; exit 1; }
fi
echo "    op $(op --version 2>/dev/null || echo '?') present"

OP_DIR="/home/$AGENT_USER/.config/op"
OP_TOKEN="$OP_DIR/service-token"
install -d -m 700 -o "$AGENT_USER" -g "$AGENT_USER" "/home/$AGENT_USER/.config" "$OP_DIR"
if [ -s "$OP_TOKEN" ]; then
  echo "    token already present at $OP_TOKEN (delete it and re-run to replace)"
else
  # Hidden input, never echoed, never in argv, never in shell history. Written
  # with umask 077 then chowned to the agent user. Skipping leaves the helper
  # unable to log in until a token is stored.
  TOK=""
  if [ -t 0 ]; then
    read -rs -p "    Paste the 1Password service-account token (input hidden; Enter to skip): " TOK || true
    echo
  else
    echo "    no TTY: cannot prompt for the token; run the installer from a real terminal"
  fi
  if [ -n "$TOK" ]; then
    ( umask 077; printf '%s' "$TOK" > "$OP_TOKEN" )
    chown "$AGENT_USER:$AGENT_USER" "$OP_TOKEN"; chmod 600 "$OP_TOKEN"
    echo "    token stored at $OP_TOKEN (600, agent-owned)"
  else
    echo "    no token stored"
  fi
  unset TOK
fi
if [ -s "$OP_TOKEN" ]; then
  # Vault names are not secret; the token never leaves the agent's process.
  if VAULTS="$(sudo -u "$AGENT_USER" -H bash -c 'OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.config/op/service-token)" op vault list 2>/dev/null')"; then
    echo "    service account can see:"; echo "$VAULTS" | sed 's/^/        /'
  else
    echo "    NOTE: 'op vault list' failed as $AGENT_USER - token rejected, or no network. The login helper will report the detail."
  fi
fi

say "6/8  browser profile directory"
sudo -u "$AGENT_USER" mkdir -p "/home/$AGENT_USER/.browser-profile"
chmod 700 "/home/$AGENT_USER/.browser-profile"
echo "    /home/$AGENT_USER/.browser-profile (700, agent-owned)"

say "7/8  display access for headed mode (WSLg)"
if command -v xhost >/dev/null; then
  sudo -u "$CALLER" DISPLAY="${DISPLAY:-:0}" xhost "+SI:localuser:$AGENT_USER" >/dev/null 2>&1 \
    && echo "    granted for this session" \
    || echo "    could not grant now; add 'xhost +SI:localuser:$AGENT_USER' to your shell profile"
else
  echo "    xhost not installed; headless will still work"
fi

say "8/8  python playwright for $AGENT_USER"
# The login helper is Python, so it needs the playwright PYTHON package, not just
# the node browsers. A venv avoids PEP 668 "externally managed environment" on
# modern Debian/Ubuntu, which --user installs now refuse.
#
# Ubuntu ships python3 WITHOUT python3-venv/ensurepip. Without it, 'python3 -m
# venv' leaves a half-built venv (bin/python3 present, no pip) and a plain
# '[ -d .venv ]' guard would then skip the repair forever. So: install the
# package here (we are root), and rebuild the venv whenever pip is missing.
if ! python3 -c 'import ensurepip' 2>/dev/null; then
  apt-get install -y -q python3-venv >/dev/null 2>&1 \
    && echo "    installed python3-venv" \
    || echo "    WARNING: could not apt-get install python3-venv; step 8 will likely fail"
fi
sudo -u "$AGENT_USER" bash -lc '
  set -e
  if [ ! -x "$HOME/.venv/bin/pip" ]; then
    rm -rf "$HOME/.venv"
    python3 -m venv "$HOME/.venv"
  fi
  "$HOME/.venv/bin/pip" install --quiet --upgrade pip playwright
  "$HOME/.venv/bin/python3" -m playwright install chromium
' && echo "    venv + playwright + chromium ready for $AGENT_USER" \
  || echo "    FAILED - run manually: sudo apt-get install -y python3-venv && sudo -u $AGENT_USER bash -lc 'rm -rf ~/.venv && python3 -m venv ~/.venv && ~/.venv/bin/pip install playwright && ~/.venv/bin/python3 -m playwright install chromium'"

# Chromium's system libraries. 'install-deps' apt-installs them and, when run as
# a non-root user, calls sudo itself - which prompts for the AGENT user's
# (locked) password and can never succeed. We are root here, so run it directly
# with the agent's venv python. Failure is non-fatal: on a box that already has
# the libraries (any machine where Chromium has run before) nothing is missing.
"/home/$AGENT_USER/.venv/bin/python3" -m playwright install-deps chromium >/dev/null 2>&1 \
  && echo "    chromium system libraries present" \
  || echo "    NOTE: install-deps did not complete; if the login helper cannot launch Chromium, run: sudo /home/$AGENT_USER/.venv/bin/python3 -m playwright install-deps chromium"

cat <<NEXT

Done. Remaining steps, in order:

  1. In 1Password: vault "secure-browser", one Login item per site with the
     default username/password fields, and a read-only service account on
     that vault whose token you pasted above. Each sites.d/<site>.json
     references its item as op://secure-browser/<item title>/<field>.
     Nothing passes through the calling session.

  2. Register the MCP server (see README "Registering the server").

  3. Test:
         sudo -u $AGENT_USER $INSTALL_DIR/bin/login --list
         sudo -u $AGENT_USER $INSTALL_DIR/bin/login <site>

  4. Only once a login works end to end:
         echo enforce > $REPO/hooks/mode

NEXT
