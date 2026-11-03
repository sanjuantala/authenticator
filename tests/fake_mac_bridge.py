#!/usr/bin/env python3
# Test stand-in for TotemBridge (mac/Sources/TotemBridge/main.swift, offline mode):
# same native-messaging framing and the same status/getVault/putVault rules.
# requestKey returns the session in $TOTEM_FAKE_DIR/session.json (stands in for "Touch ID approved").
import json, os, struct, sys

D = os.environ.get("TOTEM_FAKE_DIR") or open(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".fake_dir")).read().strip()
VAULT = os.path.join(D, "vault.json")

def read_msg():
    raw = sys.stdin.buffer.read(4)
    if len(raw) < 4: sys.exit(0)
    n = struct.unpack("<I", raw)[0]
    return json.loads(sys.stdin.buffer.read(n))

def send(obj):
    b = json.dumps(obj).encode()
    sys.stdout.buffer.write(struct.pack("<I", len(b)) + b); sys.stdout.buffer.flush()

def vault():
    try: return json.load(open(VAULT))
    except Exception: return None

req = read_msg()
t = req.get("type")
with open(os.path.join(D, "log.txt"), "a") as log: log.write(t + "\n")
if t == "status":
    send({"ok": True, "running": False, "unlocked": False, "hasVault": vault() is not None})
elif t == "getVault":
    send({"ok": True, "vault": vault(), "running": False})
elif t == "putVault":
    inc, cur = req.get("vault"), vault()
    if not inc or inc.get("format") != "totem-vault":
        send({"ok": False, "error": "Not a Totem vault"})
    elif cur is not None and not req.get("force") and req.get("base") != cur.get("updatedAt"):
        send({"ok": False, "error": "The Mac vault changed meanwhile. Sync again.", "code": "CONFLICT"})
    else:
        json.dump(inc, open(VAULT, "w"), indent=2); send({"ok": True})
elif t == "requestKey":
    try: send({"ok": True, "session": json.load(open(os.path.join(D, "session.json"))), "vault": vault()})
    except Exception: send({"ok": False, "error": "Open Totem for Mac first, then try again"})
else:
    send({"ok": False, "error": "Unknown request"})
