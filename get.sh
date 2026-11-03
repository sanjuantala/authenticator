#!/bin/bash
# One-line install or update, straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/sanjuantala/authenticator/main/get.sh | bash
set -euo pipefail

REPO="sanjuantala/authenticator"
T="$(mktemp -d)"
echo "› Downloading Totem from github.com/$REPO"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.zip" -o "$T/totem.zip"
/usr/bin/unzip -q "$T/totem.zip" -d "$T"
INSTALLER="$(find "$T" -mindepth 2 -maxdepth 2 -name install.sh | head -n 1)"
[ -n "$INSTALLER" ] || { echo "The download didn't contain install.sh"; exit 1; }
/bin/bash "$INSTALLER" < /dev/null
