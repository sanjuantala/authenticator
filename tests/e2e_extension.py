# End-to-end test of the extension in real Chrome (Chrome for Testing).
# Run: python3 tests/e2e_extension.py
import json, os, subprocess, sys, tempfile, threading, http.server, socketserver, time
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT = os.path.join(ROOT, "extension")
OUT = os.environ.get("TOTEM_SHOTS", tempfile.mkdtemp())
EXPECTED_ID = json.load(open(os.path.join(ROOT, "extension-key.json")))["id"]
SECRET = "JBSWY3DPEHPK3PXP"

PAGE = b"""<!doctype html><title>Login</title><body style="font:16px sans-serif;padding:40px">
<h2>Two-step verification</h2><label>Enter the code from your app
<input id="otp" name="otp" autocomplete="one-time-code" inputmode="numeric" maxlength="6"></label>
<div id="split" style="margin-top:30px"><input maxlength="1"><input maxlength="1"><input maxlength="1"><input maxlength="1"><input maxlength="1"><input maxlength="1"></div>
</body>"""

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(PAGE)
    def log_message(self, *a): pass

def node_code(secret, t=None):
    js = f"import('{ROOT}/extension/lib/totp.js').then(async m=>{{const r=await m.totp({{secret:'{secret}'}},{(t or 'Date.now()')});console.log(JSON.stringify(r))}})"
    return json.loads(subprocess.check_output(["node", "-e", js]).decode())

def main():
    socketserver.ThreadingTCPServer.daemon_threads = True
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H); port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    results = []
    def check(name, cond, detail=""):
        results.append((name, bool(cond))); print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))

    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(tempfile.mkdtemp(), executable_path="/usr/bin/google-chrome", headless=True, ignore_default_args=["--disable-extensions"],
            args=["--headless=new", f"--disable-extensions-except={EXT}", f"--load-extension={EXT}", "--no-sandbox"])
        sw = ctx.service_workers[0] if ctx.service_workers else ctx.wait_for_event("serviceworker", timeout=15000)
        ext_id = sw.url.split("/")[2]
        check("extension loads with the fixed ID", ext_id == EXPECTED_ID, ext_id)
        errors = []

        popup = ctx.new_page(); popup.set_viewport_size({"width": 370, "height": 600})
        popup.on("pageerror", lambda e: errors.append(str(e)))
        popup.emulate_media(color_scheme="dark")
        popup.goto(f"chrome-extension://{ext_id}/popup.html")
        popup.wait_for_selector("#lock:not([hidden])")
        check("first run asks to create a vault", popup.inner_text("#unlockBtn") == "Create vault")
        popup.screenshot(path=f"{OUT}/1-create.png")
        popup.fill("#pw", "short"); popup.fill("#pw2", "short"); popup.click("#unlockBtn")
        popup.wait_for_timeout(300)
        check("rejects short password", "10 characters" in popup.inner_text("#lockError"), popup.inner_text("#lockError"))
        popup.fill("#pw", "my-strong-pass"); popup.fill("#pw2", "my-strong-pass"); popup.click("#unlockBtn")
        popup.wait_for_selector("#main:not([hidden])", timeout=20000)
        check("vault created, main view shown", True)

        # add via pasted link
        popup.click("#addBtn")
        popup.fill("#addText", f"otpauth://totp/GitHub:me@example.com?secret={SECRET}&issuer=GitHub")
        popup.click("#addForm button[type=submit]")
        popup.wait_for_selector(".acct")
        shown = popup.inner_text(".acct .code").replace(" ", "").replace("\n", "")
        exp = node_code(SECRET)
        check("code shown matches RFC implementation", shown in (exp["code"], exp["next"]), f"{shown} vs {exp}")

        # manual add + search + keyboard copy
        popup.click("#addBtn"); popup.click("#manual summary")
        popup.fill("#fIssuer", "Shopify Partners"); popup.fill("#fLabel", "dev"); popup.fill("#fSecret", "GEZD GNBV GY3T QOJQ")
        popup.click("#addForm button[type=submit]")
        popup.locator(".acct").nth(1).wait_for()
        popup.fill("#q", "shop"); popup.wait_for_timeout(200)
        check("search filters", popup.locator(".acct:visible").count() == 1)
        popup.fill("#q", "")
        popup.wait_for_timeout(1100)
        popup.screenshot(path=f"{OUT}/2-list.png")

        # duplicate is skipped
        popup.click("#addBtn"); popup.fill("#addText", f"otpauth://totp/GitHub:me@example.com?secret={SECRET}&issuer=GitHub")
        popup.click("#addForm button[type=submit]"); popup.wait_for_timeout(400)
        check("duplicate import skipped", popup.locator(".acct").count() == 2)

        # edit: add a domain for autofill
        gh = popup.locator(".acct", has_text="GitHub")
        gh.hover(); gh.locator(".more").click()
        popup.wait_for_selector("#edit:not([hidden])")
        popup.fill("#eDomains", "127.0.0.1"); popup.click("#editForm button[type=submit]")
        popup.wait_for_selector("#main:not([hidden])")

        # QR: generate one with the bundled encoder and decode it with the bundled decoder (the scan path)
        decoded = popup.evaluate("""async () => {
          const q = qrcode(0,'M'); q.addData('otpauth://totp/Figma:me?secret=GEZDGNBVGY3TQOJQ&issuer=Figma'); q.make();
          const img = new Image(); img.src = q.createDataURL(8, 4); await img.decode();
          const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
          const x = c.getContext('2d'); x.drawImage(img,0,0);
          const d = x.getImageData(0,0,c.width,c.height); return jsQR(d.data,d.width,d.height)?.data; }""")
        check("QR encode → decode round trip", decoded and decoded.startswith("otpauth://totp/Figma"), str(decoded))

        # autofill on a real page
        site = ctx.new_page(); site.goto(f"http://127.0.0.1:{port}/"); site.wait_for_timeout(500)
        site.click("#otp")
        badge_visible = site.evaluate("!!document.querySelector('totem-fill')")
        check("fill button appears on code field", badge_visible)
        tab_id = popup.evaluate("Promise.all([chrome.tabs.query({}), chrome.tabs.getCurrent()]).then(([t,me]) => Math.max(...t.filter(x => x.id !== me.id).map(x => x.id)))")
        popup.evaluate(f"chrome.tabs.sendMessage({tab_id}, {{type:'totem-fill-now'}})")
        site.wait_for_timeout(800)
        val = site.input_value("#otp"); exp = node_code(SECRET)
        check("autofill fills the right code", val in (exp["code"], exp["next"]), f"{val} vs {exp}")
        site.screenshot(path=f"{OUT}/3-site.png")
        site.click("#split input:first-child")
        popup.evaluate(f"chrome.tabs.sendMessage({tab_id}, {{type:'totem-fill-now'}})"); site.wait_for_timeout(800)
        split = "".join(site.eval_on_selector_all("#split input", "els => els.map(e => e.value)"))
        check("autofill fills split digit boxes", split in (exp["code"], exp["next"]), split)

        # anti-phishing: a site that only *looks like* an account name is never filled silently
        popup.evaluate("chrome.runtime.sendMessage({type:'add', accounts:[{issuer:'Localhost', label:'admin', secret:'GEZDGNBVGY3TQOJQ'}]})")
        r = popup.evaluate("chrome.runtime.sendMessage({type:'fill', host:'localhost'})")
        check("look-alike site needs confirmation (no code sent)", r.get("status") == "confirm" and "matches" not in r and r.get("host") == "localhost", str(r))
        r2 = popup.evaluate("chrome.runtime.sendMessage({type:'fill', host:'github-login.example.net'})")
        check("unrelated look-alike gets no GitHub code", r2.get("status") in ("none", "confirm") and "matches" not in r2, str(r2))
        evil = ctx.new_page(); evil.emulate_media(color_scheme="dark"); evil.goto(f"http://localhost:{port}/"); evil.wait_for_timeout(500)
        evil.click("#otp")
        etab = popup.evaluate("Promise.all([chrome.tabs.query({}), chrome.tabs.getCurrent()]).then(([t,me]) => Math.max(...t.filter(x => x.id !== me.id).map(x => x.id)))")
        popup.evaluate(f"chrome.tabs.sendMessage({etab}, {{type:'totem-fill-now'}})"); evil.wait_for_timeout(700)
        check("page shows the address first, field stays empty", evil.input_value("#otp") == "")
        evil.screenshot(path=f"{OUT}/6-confirm-site.png")
        lid = popup.evaluate("chrome.runtime.sendMessage({type:'codes'}).then(r => r.codes.find(c => c.issuer === 'Localhost').id)")
        r3 = popup.evaluate(f"chrome.runtime.sendMessage({{type:'fillConfirm', host:'localhost', id:'{lid}'}})")
        check("after you confirm, it fills and remembers the site", r3.get("status") == "ok" and len(r3["matches"][0]["code"]) == 6, str(r3))
        r4 = popup.evaluate("chrome.runtime.sendMessage({type:'fill', host:'localhost'})")
        check("next time it fills directly", r4.get("status") == "ok", str(r4))
        popup.evaluate(f"chrome.runtime.sendMessage({{type:'remove', id:'{lid}'}})")
        evil.close()

        # import an Aegis export via settings
        popup.click("#settingsBtn"); popup.wait_for_selector("#settings:not([hidden])")
        popup.wait_for_timeout(500)
        popup.screenshot(path=f"{OUT}/4-settings.png", full_page=True)
        check("Mac bridge absent → shown clearly", "isn't installed" in popup.inner_text("#macStatus"), popup.inner_text("#macStatus"))
        aegis = json.dumps({"version": 1, "db": {"entries": [{"type": "totp", "name": "me", "issuer": "Proton", "info": {"secret": "JBSWY3DPEHPK3PXQ", "algo": "SHA1", "digits": 6, "period": 30}}]}})
        popup.fill("#importText", aegis); popup.click("#importBtn"); popup.wait_for_timeout(600)
        check("Aegis import", "Aegis: added 1" in popup.inner_text("#toast"), popup.inner_text("#toast"))

        # export encrypted, erase, re-import
        r = popup.evaluate("chrome.runtime.sendMessage({type:'exportVault'})")
        env = r["envelope"]
        check("export is encrypted", env["format"] == "totem-vault" and SECRET not in json.dumps(env))
        stored = popup.evaluate("chrome.storage.local.get('vault').then(v=>JSON.stringify(v))")
        check("nothing stored in plain text", SECRET not in stored and "GitHub" not in stored)

        # lock + wrong password + unlock
        popup.click("#settings [data-back]"); popup.click("#lockBtn"); popup.wait_for_selector("#lock:not([hidden])")
        r = popup.evaluate("chrome.runtime.sendMessage({type:'codes'})")
        check("locked → no codes", not r.get("codes"))
        popup.fill("#pw", "wrong-password"); popup.click("#unlockBtn"); popup.wait_for_timeout(2500)
        check("wrong password rejected", "Wrong password" in popup.inner_text("#lockError"), popup.inner_text("#lockError"))
        popup.fill("#pw", "my-strong-pass"); popup.click("#unlockBtn"); popup.wait_for_selector("#main:not([hidden])", timeout=20000)
        check("unlock works, 3 accounts", popup.locator(".acct").count() == 3)

        # reset then import the encrypted export into a fresh vault
        popup.evaluate("chrome.runtime.sendMessage({type:'reset'})")
        popup.reload(); popup.wait_for_selector("#lock:not([hidden])")
        popup.fill("#pw", "another-pass"); popup.fill("#pw2", "another-pass"); popup.click("#unlockBtn")
        popup.wait_for_selector("#main:not([hidden])", timeout=20000)
        r = popup.evaluate("(t) => chrome.runtime.sendMessage({type:'importText', text:t})", json.dumps(env))
        check("Totem backup asks for its password", r.get("needsPassword") is True)
        r = popup.evaluate("(t) => chrome.runtime.sendMessage({type:'importText', text:t, password:'my-strong-pass'})", json.dumps(env))
        check("Totem backup import restores accounts", r.get("added") == 3, str(r))
        popup.wait_for_timeout(1200)
        popup.screenshot(path=f"{OUT}/5-restored-dark.png")

        # delete through the real UI, confirmed inside the popup (browser dialogs can close a real popup)
        native = []
        popup.on("dialog", lambda d: (native.append(d.message), d.dismiss()))
        n0 = popup.locator(".acct").count()
        row = popup.locator(".acct").first
        name = row.locator(".name").inner_text()
        row.hover(); row.locator(".more").click(); popup.wait_for_selector("#edit:not([hidden])")
        popup.click("#eDelete"); popup.wait_for_selector("#dialog:not([hidden])")
        check("delete asks inside the popup", name in popup.inner_text("#dlgTitle"), popup.inner_text("#dlgTitle"))
        shown = popup.evaluate("""() => { let el = document.querySelector('#dialog .dialog'); const r = el.getBoundingClientRect();
          for (; el; el = el.parentElement) if (+getComputedStyle(el).opacity < 1) return false; return r.width > 0 && r.height > 0; }""")
        check("the dialog is actually visible on screen", shown)
        popup.wait_for_timeout(350); popup.screenshot(path=f"{OUT}/9-delete-confirm.png")
        popup.click("#dlgCancel"); popup.wait_for_timeout(200)
        check("cancel keeps the account open", popup.locator("#dialog").is_hidden() and popup.locator("#edit").is_visible())
        popup.click("#eDelete"); popup.wait_for_selector("#dialog:not([hidden])")
        popup.keyboard.press("Escape"); popup.wait_for_timeout(200)
        check("Escape closes the dialog without deleting", popup.locator("#dialog").is_hidden() and popup.locator("#edit").is_visible())
        popup.click("#eDelete"); popup.click("#dlgOk"); popup.wait_for_selector("#main:not([hidden])")
        popup.wait_for_timeout(1300)
        check("Delete removes the account", popup.locator(".acct").count() == n0 - 1 and name not in popup.inner_text("#list"),
              f"{popup.locator('.acct').count()} rows")
        gone = popup.evaluate("(n) => chrome.runtime.sendMessage({type:'codes'}).then(r => r.codes.some(c => c.issuer === n))", name)
        check("deleted account is gone from the vault", gone is False)

        # the other confirmations are in-popup too
        popup.click("#settingsBtn"); popup.wait_for_selector("#settings:not([hidden])")
        popup.click("#exportPlain"); popup.wait_for_selector("#dialog:not([hidden])")
        check("plain export warns inside the popup", "unencrypted" in popup.inner_text("#dlgTitle").lower())
        popup.click("#dlgCancel")
        popup.click("#resetBtn"); popup.wait_for_selector("#dialog:not([hidden])")
        popup.click("#dlgOk"); popup.wait_for_timeout(200)
        check("erase needs the word erase typed", "Type erase" in popup.inner_text("#dlgError") and popup.evaluate("chrome.runtime.sendMessage({type:'state'}).then(s => s.hasVault)"))
        popup.click("#dlgCancel")
        check("no browser-native dialogs were used", not native, str(native))
        popup.click("#settings [data-back]")
        popup.emulate_media(color_scheme="light"); popup.wait_for_timeout(300)
        popup.screenshot(path=f"{OUT}/7-light.png")
        popup.evaluate("chrome.runtime.sendMessage({type:'lock'})"); popup.reload(); popup.wait_for_selector("#lock:not([hidden])")
        popup.emulate_media(color_scheme="dark"); popup.wait_for_timeout(1700)
        popup.screenshot(path=f"{OUT}/8-lock-dark.png")
        check("no page errors", not errors, "; ".join(errors))
        ctx.close()
    srv.shutdown()
    print(f"\n{sum(ok for _, ok in results)}/{len(results)} passed · screenshots in {OUT}")
    sys.exit(0 if all(ok for _, ok in results) else 1)

main()
