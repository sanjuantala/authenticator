// Totem — spots 2FA code fields and offers a one-click fill.
// It never sees secrets: it asks the background for "the code for this site" and gets only that.
// Anti-phishing: on a site not yet saved for an account, it shows the real address and asks first.
(() => {
  if (window.__totem) return;
  window.__totem = true;

  // Words that mean "this is a 2FA code box", in the field itself or the text around it.
  const HINT = /(one[-_ ]?time|\botp\b|totp|2fa|mfa|two[-_ ]?(factor|step)|2[-_ ]?step|verif(y|ication)|authenticat(or|ion)|security[-_ ]?code|access[-_ ]?code|app[-_ ]?code|passcode|sms[-_ ]?code|login[-_ ]?code|6[-_ ]?digit|\bcode\b|[-_]code\b|\btoken\b)/i;
  const STRONG = /(one[-_ ]?time|\botp\b|totp|2fa|mfa|two[-_ ]?(factor|step)|authenticator|app[-_ ]?code)/i;
  const NOT = /(zip|postal|promo|coupon|discount|gift|referral|country|phone|mobile[-_ ]?number|card|cvc|cvv|search|captcha|e-?mail|amount|quantity|qty|price)/i;
  const DOTS = /^[\s•●·*_\-0xX#]{4,10}$/;            // placeholders like "••••••" or "000000"

  const labelText = (el) => {
    const parts = [];
    if (el.labels?.length) parts.push(...[...el.labels].map((l) => l.textContent));
    for (const id of (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean)) parts.push(document.getElementById(id)?.textContent || "");
    return parts.join(" ");
  };
  const ownText = (el) => [el.name, el.id, el.placeholder, el.title, el.getAttribute("aria-label"), el.getAttribute("label"),
    el.getAttribute("data-testid"), el.getAttribute("data-test"), typeof el.className === "string" ? el.className : "", labelText(el)]
    .filter(Boolean).join(" ");
  /** Visible text near the field (custom floating labels, help text). Stops before it grabs the whole page. */
  function nearText(el) {
    let node = el.parentElement;
    for (let i = 0; node && i < 4; i++, node = node.parentElement) {
      const t = (node.innerText || node.textContent || "").replace(/\s+/g, " ").trim();
      if (t.length > 400) break;
      if (t.length > 3) return t;
    }
    return "";
  }

  /** Scores how likely an input is a 2FA code box. Names like id="userid" no longer veto a real code field. */
  function isCodeField(el) {
    if (!(el instanceof HTMLInputElement) || el.disabled || el.readOnly) return false;
    if (!["text", "tel", "number", "password", ""].includes(el.type)) return false;
    if (el.autocomplete === "one-time-code") return true;
    const own = ownText(el), near = nearText(el);
    const max = el.maxLength;
    let score = 0;
    if (HINT.test(own)) score += STRONG.test(own) ? 5 : 3;
    if (HINT.test(near)) score += STRONG.test(near) ? 4 : 2;
    if (DOTS.test(el.placeholder || "")) score += 3;
    if (max >= 4 && max <= 8) score += 2;
    else if (max === 1) score += 1;
    else if (max > 10) score -= 3;
    if (el.inputMode === "numeric" || el.type === "number" || el.type === "tel" || /\\d|\[0-9\]/.test(el.pattern || "")) score += 1;
    if (NOT.test(own)) score -= 3;
    if (NOT.test(near) && !STRONG.test(near)) score -= 2;
    return score >= 5;
  }

  /** Split boxes: 4–8 single-character inputs side by side. */
  function splitGroup(el) {
    if (el.maxLength !== 1) return null;
    const parent = el.closest("form, fieldset, [role=group], div");
    const boxes = parent ? [...parent.querySelectorAll("input")].filter((i) => i.maxLength === 1 && !i.disabled && i.type !== "hidden") : [];
    return boxes.length >= 4 && boxes.length <= 8 ? boxes : null;
  }

  function setValue(input, value) {
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), "value")?.set;
    input.focus();
    setter ? setter.call(input, value) : (input.value = value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function fillCode(el, code) {
    const group = splitGroup(el);
    if (group) {
      group.forEach((box, i) => setValue(box, code[i] || ""));
      group[Math.min(code.length, group.length) - 1]?.focus();
    } else setValue(el, code);
  }

  // ---------- UI (closed shadow DOM: the page can't style or read it) ----------
  const MARK = `<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="8" y="4.5" width="8" height="3.6" rx="1.4" fill="#E2C38A"/><rect x="6" y="10.2" width="12" height="3.6" rx="1.4" fill="#D4B074" opacity=".85"/><rect x="4" y="15.9" width="16" height="3.6" rx="1.4" fill="#C49A55" opacity=".7"/></svg>`;
  const host = document.createElement("totem-fill");
  const shadow = host.attachShadow({ mode: "closed" });
  shadow.innerHTML = `
  <style>
    :host { all: initial; }
    * { box-sizing: border-box; }
    .chip, .panel { position: fixed; z-index: 2147483647; font: 13px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      --bg: #161A22; --fg: #ECE8E1; --muted: #98A0AE; --line: rgba(255,255,255,.08); --brass: #D4B074; --hover: rgba(255,255,255,.05); }
    @media (prefers-color-scheme: light) {
      .chip, .panel { --bg: #FFFFFF; --fg: #161A22; --muted: #667085; --line: rgba(22,26,34,.1); --brass: #9A7434; --hover: rgba(22,26,34,.04); }
    }
    .chip { width: 26px; height: 26px; padding: 0; border: 1px solid var(--line); border-radius: 8px; background: var(--bg); cursor: pointer;
      display: grid; place-items: center; box-shadow: 0 6px 18px rgba(0,0,0,.22); transition: transform .12s ease; }
    .chip:hover { transform: translateY(-1px); }
    .chip:focus-visible { outline: 2px solid var(--brass); outline-offset: 2px; }
    .chip svg { width: 18px; height: 18px; }
    .panel { width: 280px; background: var(--bg); color: var(--fg); border: 1px solid var(--line); border-radius: 14px; padding: 6px;
      box-shadow: 0 18px 44px rgba(0,0,0,.32); }
    .head { display: flex; gap: 8px; align-items: center; padding: 8px 10px 6px; color: var(--muted); font-size: 12px; }
    .head svg { width: 16px; height: 16px; flex: none; }
    .row { display: flex; justify-content: space-between; align-items: center; gap: 10px; width: 100%; padding: 9px 10px; border: 0;
      border-radius: 9px; background: none; color: inherit; font: inherit; text-align: left; cursor: pointer; }
    .row:hover, .row:focus-visible { background: var(--hover); outline: none; }
    .row small { display: block; color: var(--muted); font-size: 11.5px; }
    .code { font: 600 15px/1 ui-monospace, "SF Mono", Menlo, monospace; letter-spacing: .06em; color: var(--brass); font-variant-numeric: tabular-nums; }
    .warn { padding: 6px 10px 10px; }
    .warn p { margin: 0 0 6px; }
    .site { display: inline-block; padding: 2px 7px; border-radius: 6px; background: var(--hover); border: 1px solid var(--line);
      font: 600 12.5px/1.5 ui-monospace, "SF Mono", Menlo, monospace; word-break: break-all; }
    .muted { color: var(--muted); font-size: 12px; }
    .btn { width: 100%; margin-top: 4px; padding: 9px 10px; border-radius: 9px; border: 1px solid var(--line); background: none; color: inherit;
      font: 600 13px/1.2 inherit; font-family: inherit; cursor: pointer; text-align: left; }
    .btn.primary { background: var(--brass); color: #1A1408; border-color: transparent; }
    .btn:hover { filter: brightness(1.06); }
    .btn:focus-visible { outline: 2px solid var(--brass); outline-offset: 1px; }
    [hidden] { display: none !important; }
  </style>
  <button class="chip" hidden title="Fill with Totem" aria-label="Fill 2FA code with Totem">${MARK}</button>
  <div class="panel" hidden role="dialog" aria-label="Totem"></div>`;
  const chip = shadow.querySelector(".chip");
  const panel = shadow.querySelector(".panel");
  let target = null, hideTimer = null;

  const mount = () => { if (!host.isConnected) (document.body || document.documentElement).appendChild(host); };
  const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };

  function placeChip(rect) {
    chip.style.left = Math.max(8, Math.min(window.innerWidth - 16, rect.right) - 32) + "px";
    chip.style.top = rect.top + (rect.height - 26) / 2 + "px";
  }
  function placePanel() {
    const r = target?.getBoundingClientRect() || { right: window.innerWidth - 20, bottom: 20 };
    panel.style.left = Math.max(8, Math.min(window.innerWidth - 288, r.right - 280)) + "px";
    const below = r.bottom + 8;
    panel.style.top = (below + panel.offsetHeight > window.innerHeight ? Math.max(8, r.top - panel.offsetHeight - 8) : below) + "px";
  }

  function showChip(input) {
    if (!chrome.runtime?.id) return;
    target = input;
    mount();
    chip.hidden = false;
    placeChip(input.getBoundingClientRect());
  }
  function hideAll() { chip.hidden = true; panel.hidden = true; clearTimeout(hideTimer); }

  function openPanel(children, { autoClose = 0 } = {}) {
    mount();
    panel.replaceChildren(...children);
    panel.hidden = false;
    placePanel();
    clearTimeout(hideTimer);
    if (autoClose) hideTimer = setTimeout(() => (panel.hidden = true), autoClose);
    panel.querySelector("button")?.focus();
  }

  function header(text) {
    const h = el("div", "head");
    h.innerHTML = MARK;
    h.append(text);
    return h;
  }

  function note(text) { openPanel([header("Totem"), el("div", "warn muted", text)], { autoClose: 4200 }); }

  function accountRow(m, onPick) {
    const b = el("button", "row");
    const left = el("span", null, m.issuer || m.label);
    if (m.issuer && m.label) left.append(el("small", null, m.label));
    b.append(left);
    if (m.code) b.append(el("span", "code", m.code.replace(/^(\d{3,4})(\d+)$/, "$1 $2")));
    b.addEventListener("mousedown", (e) => e.preventDefault());
    b.addEventListener("click", onPick);
    return b;
  }

  function done(code) { fillCode(target, code); hideAll(); }

  async function ask(type, extra = {}) {
    try { return await chrome.runtime.sendMessage({ type, ...extra }); }
    catch { return { ok: false, error: "Totem was updated. Reload this page to use it here." }; }
  }

  async function request(input) {
    target = input;
    const r = await ask("fill");
    if (!r?.ok) return note(r?.error || "Totem couldn't fill this field.");
    if (r.status === "off") return;
    if (r.status === "locked") return note("Totem is locked. Press Alt+Shift+T to unlock it, then try again.");
    if (r.status === "none") return note(`No account is saved for ${r.host}. In Totem, open the account and add this site.`);
    if (r.status === "confirm") return confirmSite(r);
    if (r.matches.length === 1) return done(r.matches[0].code);
    openPanel([header("Choose an account"), ...r.matches.map((m) => accountRow(m, () => done(m.code)))]);
  }

  /** The page's real address, shown before the first fill on a site — this is what stops look-alike sites. */
  function confirmSite(r) {
    const w = el("div", "warn");
    const p = el("p", null, "You're on ");
    p.append(el("span", "site", r.host));
    w.append(p, el("div", "muted", "This site isn't saved for any account yet. Fill only if the address is exactly right — look-alike sites use names like these to steal codes."));
    const rows = r.candidates.map((c) => {
      const b = el("button", "btn", `Fill ${c.issuer || c.label} and remember this site`);
      b.addEventListener("mousedown", (e) => e.preventDefault());
      b.addEventListener("click", async () => {
        const res = await ask("fillConfirm", { id: c.id });
        if (res?.ok && res.matches?.[0]) done(res.matches[0].code);
        else note(res?.error || "Totem couldn't fill this field.");
      });
      return b;
    });
    rows[0]?.classList.add("primary");
    const cancel = el("button", "btn", "Cancel");
    cancel.addEventListener("click", hideAll);
    openPanel([header("Check the address"), w, ...rows, cancel]);
  }

  chip.addEventListener("mousedown", (e) => { e.preventDefault(); if (target) request(target); });
  chip.addEventListener("keydown", (e) => { if ((e.key === "Enter" || e.key === " ") && target) { e.preventDefault(); request(target); } });

  document.addEventListener("focusin", (e) => {
    const t = e.composedPath()[0];
    if (isCodeField(t)) showChip(t);
    else if (t !== host) hideAll();
  }, true);
  document.addEventListener("scroll", () => {
    if (target && !chip.hidden) placeChip(target.getBoundingClientRect());
    if (!panel.hidden) placePanel();
  }, true);
  window.addEventListener("resize", hideAll);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") hideAll(); }, true);

  document.addEventListener("pointerdown", (e) => {
    const t = e.composedPath()[0];
    if (t instanceof HTMLInputElement && isCodeField(t)) setTimeout(() => showChip(t), 0);
  }, true);
  // many login pages focus the code box before Totem starts: check again shortly after load
  for (const delay of [0, 400, 1200, 2500]) {
    setTimeout(() => {
      const a = document.activeElement;
      if (a instanceof HTMLInputElement && chip.hidden && isCodeField(a)) showChip(a);
    }, delay);
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type !== "totem-fill-now") return;
    let input = document.activeElement;
    if (!(input instanceof HTMLInputElement)) input = [...document.querySelectorAll("input")].find(isCodeField);
    if (input) request(input);
  });
})();
