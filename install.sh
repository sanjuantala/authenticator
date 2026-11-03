#!/bin/bash
# Installs or updates Totem (the Mac app and the browser extension) in one go.
#   First time:  bash ~/Downloads/totem/install.sh   (after unzipping)
#   Later:       Totem's menu → "Install update" runs this for you.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$SRC/VERSION")"
HOME_DIR="$HOME/Totem"                    # permanent home: source + extension
EXT_ID="mdbaiajlghmojiingboeggblieidhpen"
echo "› Installing Totem $VERSION"

# 1. Keep a copy of the source in ~/Totem/source (keeps the build cache, so later updates build faster)
mkdir -p "${HOME_DIR:?}"
if [ "$SRC" != "$HOME_DIR/source" ]; then
  if [ -d "$HOME_DIR/source/mac/.build" ]; then mv "$HOME_DIR/source/mac/.build" "$HOME_DIR/.build-cache"; fi
  rm -rf "${HOME_DIR:?}/source"
  cp -R "$SRC" "${HOME_DIR:?}/source"
  rm -rf "${HOME_DIR:?}/source/mac/.build" "${HOME_DIR:?}/source/mac/build"
  if [ -d "$HOME_DIR/.build-cache" ]; then mv "$HOME_DIR/.build-cache" "$HOME_DIR/source/mac/.build"; fi
fi
NEW_EXT="$HOME_DIR/source/extension"

# 2. Update the extension in every folder a Chromium browser loads Totem from.
#    The extension notices its new files within a minute and reloads itself.
EXT_PATHS="$(/usr/bin/python3 - "$EXT_ID" <<'PY'
import glob, json, os, sys
eid = sys.argv[1]
base = os.path.expanduser("~/Library/Application Support")
found = set()

def is_totem(p):
    try:
        return json.load(open(os.path.join(p, "manifest.json"))).get("name") == "Totem Authenticator"
    except Exception:
        return False

def walk(node, under_id=False):
    """Find unpacked-extension paths for our ID anywhere in a browser's settings files."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "path" and isinstance(v, str) and under_id and os.path.isabs(v) and is_totem(v):
                found.add(os.path.realpath(v))
            walk(v, under_id or k == eid)
    elif isinstance(node, list):
        for v in node:
            walk(v, under_id)

# every Chromium browser keeps per-profile settings files a few folders deep
files = []
for depth in ("*", "*/*", "*/*/*", "*/*/*/*"):
    files += glob.glob(f"{base}/{depth}/Preferences") + glob.glob(f"{base}/{depth}/Secure Preferences")
for f in files:
    try:
        if os.path.getsize(f) > 50_000_000:
            continue
        text = open(f, encoding="utf-8", errors="ignore").read()
        if eid in text:
            walk(json.loads(text))
    except Exception:
        pass
print("\n".join(sorted(found)))
PY
)"
UPDATED=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if [ "$p" != "$(cd "$NEW_EXT" && pwd -P)" ]; then
    find "${p:?}" -mindepth 1 -delete   # same folder, fresh files (the browser keeps loading this path)
    cp -R "$NEW_EXT/." "$p/"
  fi
  echo "  extension updated in $p"
  UPDATED=1
done <<< "$EXT_PATHS"
if [ "$UPDATED" = 0 ]; then
  echo "  No browser has Totem loaded from a folder yet, so the extension wasn't updated."
  echo "  One time only: in chrome://extensions remove Totem, click Load unpacked and choose:"
  echo "      $NEW_EXT"
  echo "  (In the folder picker press Cmd+Shift+G and paste that path.) Updates then reach it automatically."
fi

# 3. Build and install the Mac app (it quits the running copy and opens the new one)
if [ "${TOTEM_SKIP_BUILD:-0}" != "1" ]; then
  cd "$HOME_DIR/source/mac"
  ./scripts/build-app.sh
fi
echo "✓ Totem $VERSION installed."
