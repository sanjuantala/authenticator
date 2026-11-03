# Which inputs count as 2FA code boxes? Runs the real detector from content.js against
# real-world-shaped markup (Kite/Zerodha, GitHub, Google, AWS, split boxes) and look-alikes that must NOT match.
# Then loads the extension and checks the fill button appears on an autofocused Kite-style page.
# Run: python3 tests/e2e_detect.py
import json, os, sys, tempfile, threading, http.server, socketserver
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT = os.path.join(ROOT, "extension")
OUT = os.environ.get("TOTEM_SHOTS", tempfile.mkdtemp())
SRC = open(os.path.join(EXT, "content.js")).read().replace("  /** Split boxes:", "  window.__isCodeField = isCodeField;\n  /** Split boxes:", 1)

CASES = [  # (name, html, should_match)
    ("Kite / Zerodha", '<div class="su-input-group"><label class="su-input-label">Mobile App Code</label><div><span class="icon"></span><input id="userid" type="number" placeholder="••••••" maxlength="6" autocomplete="off"></div></div><p>Open the Kite mobile app on your phone to generate the 2FA App Code.</p>', True),
    ("Kite older (External TOTP)", '<div><label>External TOTP</label><input type="text" id="userid" label="External TOTP" maxlength="6" placeholder="••••••"></div>', True),
    ("GitHub", '<label for="app_totp">Authentication code</label><input id="app_totp" name="app_otp" type="text" autocomplete="one-time-code" maxlength="6">', True),
    ("Google", '<div><input type="tel" id="totpPin" name="totpPin" aria-label="Enter code" pattern="[0-9 ]*"></div><div>Get a verification code from the Google Authenticator app</div>', True),
    ("AWS", '<label>MFA code<input name="mfaCode" type="text" maxlength="6"></label>', True),
    ("Generic 6-digit", '<div><p>Enter the 6-digit code from your authenticator</p><input type="text" inputmode="numeric" maxlength="6"></div>', True),
    ("Split boxes", '<div><p>Two-step verification</p><input maxlength="1"><input maxlength="1"><input maxlength="1"><input maxlength="1"><input maxlength="1"><input maxlength="1"></div>', True),
    ("Username", '<label>User ID<input id="userid" type="text" maxlength="20" placeholder="Phone or User ID"></label>', False),
    ("Phone number", '<label>Phone number<input type="tel" id="phone" maxlength="10"></label>', False),
    ("Search", '<input type="text" name="q" placeholder="Search">', False),
    ("Promo code", '<label>Promo code<input name="promo" type="text" maxlength="8"></label>', False),
    ("Email", '<label>Email<input type="text" name="email"></label>', False),
    ("Zip code", '<label>ZIP code<input name="zip" maxlength="5" inputmode="numeric"></label>', False),
    ("Card CVC", '<label>Card security code<input name="cvc" maxlength="4" inputmode="numeric"></label>', False),
]

KITE = b"""<!doctype html><title>Kite</title><body style="font:16px sans-serif;padding:60px">
<div class="su-input-group" style="width:320px"><label class="su-input-label">Mobile App Code</label>
<div><span>&#9647;</span><input id="userid" type="number" placeholder="&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;" maxlength="6" autocomplete="off" autofocus style="width:260px;font-size:18px"></div></div>
<p>Open the Kite mobile app on your phone to generate the 2FA App Code.</p><button>Continue</button></body>"""

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.end_headers(); self.wfile.write(KITE)
    def log_message(self, *a): pass

results = []
def check(name, cond, detail=""):
    results.append(bool(cond)); print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/usr/bin/google-chrome", headless=True, args=["--no-sandbox"])
    page = b.new_page()
    page.set_content("<body></body>")
    page.add_script_tag(content="window.chrome = {runtime:{id:'x', onMessage:{addListener(){}}, sendMessage(){return Promise.resolve({})}}};")
    page.add_script_tag(content=SRC)
    for name, html, want in CASES:
        got = page.evaluate("""(h) => { document.body.innerHTML = h; const i = document.querySelector('input'); return window.__isCodeField(i); }""", html)
        check(f"{'detects' if want else 'ignores'} {name}", got == want, f"got {got}")
    b.close()

    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H); srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    ctx = p.chromium.launch_persistent_context(tempfile.mkdtemp(), executable_path="/usr/bin/google-chrome", headless=True,
        ignore_default_args=["--disable-extensions"],
        args=["--headless=new", f"--disable-extensions-except={EXT}", f"--load-extension={EXT}", "--no-sandbox"])
    if not ctx.service_workers: ctx.wait_for_event("serviceworker", timeout=15000)
    site = ctx.new_page(); site.goto(f"http://127.0.0.1:{srv.server_address[1]}/"); site.wait_for_timeout(2000)
    focused = site.evaluate("document.activeElement && document.activeElement.id")
    chip_box = site.evaluate("""() => { const h = document.querySelector('totem-fill'); if (!h) return null; const r = h.getBoundingClientRect(); return true; }""")
    site.screenshot(path=f"{OUT}/kite-autofocus.png")
    check("autofocused Kite box gets the Totem button without clicking", focused == "userid" and chip_box, f"focused={focused} chip={chip_box}")
    ctx.close(); srv.shutdown()

print(f"\n{sum(results)}/{len(results)} passed · screenshot in {OUT}")
sys.exit(0 if all(results) else 1)
