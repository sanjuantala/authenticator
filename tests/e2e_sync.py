# Two browser profiles syncing through the Mac bridge protocol (fake bridge = Swift offline mode rules).
# Run: python3 tests/e2e_sync.py
import json, os, stat, subprocess, sys, tempfile
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT = os.path.join(ROOT, "extension")
EXT_ID = json.load(open(os.path.join(ROOT, "extension-key.json")))["id"]
HOST = os.path.join(ROOT, "tests", "fake_mac_bridge.py")
FAKE = tempfile.mkdtemp()
open(os.path.join(ROOT, "tests", ".fake_dir"), "w").write(FAKE)
os.chmod(HOST, os.stat(HOST).st_mode | stat.S_IEXEC)
results = []

def check(name, cond, detail=""):
    results.append(bool(cond)); print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))

def node(js):
    return json.loads(subprocess.check_output(["node", "--input-type=module", "-e", js], cwd=ROOT).decode())

def decrypt_file(password):
    return node(f"""import * as V from './extension/lib/vault.js'; import fs from 'fs';
      const env = JSON.parse(fs.readFileSync('{FAKE}/vault.json','utf8'));
      const s = await V.sessionForEnvelope('{password}', env); const d = await V.openEnvelope(env, s);
      console.log(JSON.stringify({{live: V.liveAccounts(d).map(a => a.issuer), session: s}}));""")

def profile(p):
    ud = tempfile.mkdtemp()
    hosts = os.path.join(ud, "NativeMessagingHosts"); os.makedirs(hosts)
    manifest = {"name": "com.totem.bridge", "description": "fake", "path": HOST, "type": "stdio",
                "allowed_origins": [f"chrome-extension://{EXT_ID}/"]}
    json.dump(manifest, open(os.path.join(hosts, "com.totem.bridge.json"), "w"))
    ctx = p.chromium.launch_persistent_context(ud, executable_path="/usr/bin/google-chrome", headless=True,
        ignore_default_args=["--disable-extensions"], env={**os.environ, "TOTEM_FAKE_DIR": FAKE},
        args=["--headless=new", f"--disable-extensions-except={EXT}", f"--load-extension={EXT}", "--no-sandbox"])
    if not ctx.service_workers: ctx.wait_for_event("serviceworker", timeout=15000)
    page = ctx.new_page(); page.goto(f"chrome-extension://{EXT_ID}/popup.html"); page.wait_for_selector(".view:not([hidden])")
    return ctx, page

def msg(page, type_, **kw):
    return page.evaluate("(m) => chrome.runtime.sendMessage(m)", {"type": type_, **kw})

with sync_playwright() as p:
    a_ctx, A = profile(p)
    st = msg(A, "nativeStatus")
    check("extension reaches the bridge via native messaging", st.get("connected") and st.get("hasVault") is False, str(st))
    msg(A, "create", password="shared-pass-1")
    msg(A, "add", accounts=[{"issuer": "GitHub", "label": "a", "secret": "JBSWY3DPEHPK3PXP"},
                            {"issuer": "Shopify", "label": "b", "secret": "GEZDGNBVGY3TQOJQ"}])
    r = msg(A, "sync")
    check("profile A pushes its vault to the Mac", r.get("mac", {}).get("ok"), str(r))
    f = decrypt_file("shared-pass-1")
    check("Mac vault file decrypts to A's accounts", sorted(f["live"]) == ["GitHub", "Shopify"], str(f))
    raw = open(os.path.join(FAKE, "vault.json")).read()
    check("Mac vault file is encrypted", "GitHub" not in raw and "JBSWY3" not in raw)

    # Profile B: brand new browser, unlocks with "Touch ID on Mac"
    json.dump(f["session"], open(os.path.join(FAKE, "session.json"), "w"))
    b_ctx, B = profile(p)
    B.reload(); B.wait_for_selector("#macUnlock:not([hidden])", timeout=8000)
    check("fresh browser offers “Use my Mac's vault”", "Mac" in B.inner_text("#macUnlock"))
    B.click("#macUnlock"); B.wait_for_selector("#main:not([hidden])", timeout=15000)
    B.wait_for_timeout(1200)
    check("profile B unlocked via Mac with A's accounts", B.locator(".acct").count() == 2)

    msg(B, "add", accounts=[{"issuer": "Figma", "label": "c", "secret": "JBSWY3DPEHPK3PXQ"}])
    r = msg(B, "sync"); check("profile B pushes its new account", r.get("mac", {}).get("ok"), str(r))
    r = msg(A, "sync"); codes = msg(A, "codes")["codes"]
    check("profile A receives B's account", sorted(c["issuer"] for c in codes) == ["Figma", "GitHub", "Shopify"], str(codes))

    gh = next(c for c in codes if c["issuer"] == "GitHub")
    msg(A, "remove", id=gh["id"]); msg(A, "sync"); msg(B, "sync")
    codes = msg(B, "codes")["codes"]
    check("delete on A reaches B (no resurrection)", sorted(c["issuer"] for c in codes) == ["Figma", "Shopify"], str(codes))

    # conflict protection: stale base is rejected by the bridge, then a re-sync succeeds
    env = msg(A, "exportVault")["envelope"]
    stale = A.evaluate("(e) => chrome.runtime.sendNativeMessage('com.totem.bridge', {type:'putVault', vault:e, base:1})", env)
    check("bridge rejects a stale write", stale.get("code") == "CONFLICT", str(stale))
    r = msg(A, "sync"); check("normal sync still fine after conflict", r.get("mac", {}).get("ok"), str(r))

    # password changed on A → B must ask once, then joins
    msg(A, "changePassword", current="shared-pass-1", next="shared-pass-2")
    r = msg(B, "sync")
    check("B detects the new password setup", r.get("mac", {}).get("code") == "KDF_MISMATCH", str(r))
    st = msg(B, "state"); check("B offers to join", st.get("pendingJoin") == "mac", str(st))
    j = msg(B, "joinVault", password="shared-pass-2"); check("B joins with the new password", j.get("ok"), str(j))
    r = msg(B, "sync"); check("B syncs normally afterwards", r.get("mac", {}).get("ok"), str(r))
    check("final vault opens with new password only", sorted(decrypt_file("shared-pass-2")["live"]) == ["Figma", "Shopify"])
    a_ctx.close(); b_ctx.close()

os.remove(os.path.join(ROOT, "tests", ".fake_dir"))
print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
