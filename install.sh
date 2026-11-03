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
seen = {}

def walk(node, under_id=False):
    """Collect unpacked-extension folders recorded for our ID in a browser's settings files."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "path" and isinstance(v, str) and under_id and os.path.isabs(v):
                seen[os.path.realpath(v)] = True
            walk(v, under_id or k == eid)
    elif isinstance(node, list):
        for v in node:
            walk(v, under_id)

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

for p in sorted(seen):
    manifest = os.path.join(p, "manifest.json")
    try:
        name = json.load(open(manifest)).get("name")
        print(("OK" if name == "Totem Authenticator" else "OTHER") + "\t" + p)
    except PermissionError:
        print("BLOCKED\t" + p)          # macOS privacy: Terminal may not read Desktop/Documents
    except FileNotFoundError:
        print("MISSING\t" + p)          # the folder was moved or deleted
    except Exception:
        print("OTHER\t" + p)
PY
)"
UPDATED=0
NEW_REAL="$(cd "$NEW_EXT" && pwd -P)"
while IFS=$'\t' read -r state p; do
  [ -z "$p" ] && continue
  case "$state" in
    OK)
      if [ "$p" != "$NEW_REAL" ]; then
        find "${p:?}" -mindepth 1 -delete   # same folder, fresh files (the browser keeps loading this path)
        cp -R "$NEW_EXT/." "$p/"
      fi
      echo "  extension updated in $p"
      UPDATED=1 ;;
    BLOCKED) echo "  found the extension in $p, but macOS doesn't let Terminal read that folder (Desktop/Documents are protected)." ;;
    MISSING) echo "  your browser points to $p, but that folder no longer exists." ;;
  esac
done <<< "$EXT_PATHS"
if [ "$UPDATED" = 0 ]; then
  echo "  The extension wasn't updated. One time only, switch it to Totem's own folder (not protected by macOS):"
  echo "  in chrome://extensions remove Totem, click Load unpacked and choose:"
  echo "      $NEW_EXT"
  echo "  (In the folder picker press Cmd+Shift+G and paste that path.) Updates then reach it automatically."
fi

# 3. Build and install the Mac app (it quits the running copy and opens the new one)
if [ "${TOTEM_SKIP_BUILD:-0}" != "1" ]; then
  cd "$HOME_DIR/source/mac"
  ./scripts/build-app.sh
fi
echo "✓ Totem $VERSION installed."
