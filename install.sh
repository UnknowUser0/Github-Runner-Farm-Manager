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

printf '%s\n' "Installed: $DEST"
"$DEST" version
printf '\nNext step:\n  runner-farmctl install <repo/org>\n\nExamples:\n  runner-farmctl install SkyTeamExec/Github-Runner-Farm-Manager\n  runner-farmctl install SkyTeamExec\n'
