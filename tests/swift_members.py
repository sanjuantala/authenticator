# Catches a missing method or property before a Mac build fails:
# every `model.x`, `AppModel.shared.x` and bare call inside AppModel must be declared somewhere.
# Run: python3 tests/swift_members.py
import os, re, sys

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mac", "Sources", "Totem")
files = {f: open(os.path.join(SRC, f)).read() for f in os.listdir(SRC) if f.endswith(".swift")}
app = files["AppModel.swift"]

declared = set(re.findall(r"\b(?:func|var|let|case|struct|enum|class)\s+([A-Za-z_]\w*)", app))
declared |= {"objectWillChange"}  # from ObservableObject

used = {}
for name, text in files.items():
    for m in re.finditer(r"(?:\bmodel|AppModel\.shared)\.([A-Za-z_]\w*)", text):
        used.setdefault(m.group(1), set()).add(name)
# bare calls inside AppModel to its own methods
own = set(re.findall(r"\bfunc\s+([A-Za-z_]\w*)", app))
for m in re.finditer(r"(?<![.\w])([a-z]\w*)\(", app):
    n = m.group(1)
    if n in {"say", "applyHotKey", "persist", "touch", "lock", "didUnlock", "storeTouchID", "readEnvelope",
             "writeEnvelope", "backupCurrentFile", "scheduleSync", "syncBackup", "unlockWithTouchID", "add", "checkForUpdate"}:
        used.setdefault(n, set()).add("AppModel.swift (own call)")

missing = {k: v for k, v in used.items() if k not in declared}
for k, v in sorted(missing.items()):
    print(f"MISSING AppModel.{k}  used in {', '.join(sorted(v))}")
print(f"{len(used)} AppModel members used, {len(missing)} missing")
sys.exit(1 if missing else 0)
