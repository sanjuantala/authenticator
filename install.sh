#!/bin/bash
# Installs or updates Totem — the Mac app and the browser extension — in one go.
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
roots = ["Google/Chrome", "Google/Chrome Beta", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Chromium", "Vivaldi"]
found = set()
for r in roots:
    for f in glob.glob(f"{base}/{r}/*/Preferences") + glob.glob(f"{base}/{r}/*/Secure Preferences"):
        try:
            p = json.load(open(f)).get("extensions", {}).get("settings", {}).get(eid, {}).get("path", "")
        except Exception:
            continue
        if p and os.path.isabs(p) and os.path.isfile(os.path.join(p, "manifest.json")):
            try:
                if json.load(open(os.path.join(p, "manifest.json"))).get("name") == "Totem Authenticator":
                    found.add(os.path.realpath(p))
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
  echo "  extension is ready in $NEW_EXT"
  echo "  → In chrome://extensions turn on Developer mode, click Load unpacked, and choose that folder (one time only)."
fi

# 3. Build and install the Mac app (it quits the running copy and opens the new one)
if [ "${TOTEM_SKIP_BUILD:-0}" != "1" ]; then
  cd "$HOME_DIR/source/mac"
  ./scripts/build-app.sh
fi
echo "✓ Totem $VERSION installed."
