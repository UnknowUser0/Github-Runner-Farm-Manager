#!/bin/sh
set -eu

REPO="SkyTeamExec/Github-Runner-Farm-Manager"
BRANCH="main"
URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/runner-farmctl"
DEST="/usr/local/bin/runner-farmctl"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || {
    echo "ERROR: sudo is required to install runner-farmctl into /usr/local/bin." >&2
    exit 1
  }
  SUDO="sudo"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT INT TERM

printf '%s\n' "Installing runner-farmctl..."
curl -fsSL "$URL" -o "$TMP"
chmod 0755 "$TMP"
$SUDO install -m 0755 "$TMP" "$DEST"

# Install shell completion definitions for Bash, Zsh, and Fish.
"$DEST" completion install

printf '%s\n' "Installed: $DEST"
"$DEST" version
printf '\nOpen the TUI:\n  runner-farmctl\n\nInstall a farm:\n  runner-farmctl install <repo/org>\n\nExamples:\n  runner-farmctl install SkyTeamExec/Github-Runner-Farm-Manager\n  runner-farmctl install SkyTeamExec\n\nRemove one farm:\n  runner-farmctl uninstall <farm>\n\nRemove all farms but keep the manager:\n  runner-farmctl uninstall --all\n\nUninstall runner-farmctl itself (after farms are removed):\n  runner-farmctl manager-uninstall\n'
