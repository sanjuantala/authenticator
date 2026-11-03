// Totem — popup UI.
import { strength } from "./lib/strength.js";

const $ = (id) => document.getElementById(id);
const send = (type, data = {}) => chrome.runtime.sendMessage({ type, ...data }).then((r) => {
  if (!r) throw new Error("No response");
  if (!r.ok) { const e = new Error(r.error); e.code = r.code; throw e; }
  return r;
});

let state = null;
let codes = [];
let sel = 0;
let editing = null;
let activeHost = "";
let tickTimer = null;
let macInfo = null;
const MIN_SCORE = 2; // new master passwords must be at least "Fair"

// ---------- helpers ----------
function show(view) {
  for (const v of document.querySelectorAll(".view")) v.hidden = v.id !== view;
  if (view === "main") setTimeout(() => $("q").focus(), 0);
}
function toast(msg, ms = 1800) {
  const t = $("toast");
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toast.t);
  toast.t = setTimeout(() => (t.hidden = true), ms);
}
function download(name, text, type = "application/json") {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([text], { type }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}
const stamp = () => new Date().toISOString().slice(0, 10);
function ago(t) {
  if (!t) return "never";
  const s = Math.round((Date.now() - t) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return new Date(t).toLocaleDateString();
}
function hash(str) {
  let h = 2166136261;
  for (const c of str) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
  return h >>> 0;
}
/** A calm monogram tile, tinted per service (same hue on the Mac). */
function monogram(name) {
  const el = document.createElement("div");
  el.className = "mono-tile";
  el.style.setProperty("--h", String(hash((name || "?").toLowerCase()) % 360));
  const words = (name || "?").trim().split(/\s+/);
  el.textContent = (words.length > 1 && words[1][0] ? words[0][0] + words[1][0] : (name || "?").trim().slice(0, 1)).toUpperCase();
  return el;
}
function formatCode(code) {
  const half = code.length === 8 ? 4 : 3;
  return `${code.slice(0, half)}<span class="gap"></span>${code.slice(half)}`;
}
function hostMatch(c) {
  if (!activeHost) return false;
  const h = activeHost.replace(/^www\./, "");
  return !!c.domains?.some((d) => h === d || h.endsWith("." + d));
}
function meter(el, pw) {
  const r = strength(pw);
  el.hidden = !pw;
  el.dataset.score = String(r.score);
  el.querySelector("span").textContent = r.hint ? `${r.label}. ${r.hint}` : r.label;
  return r;
}

// ---------- boot ----------
async function boot() {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (tab?.url?.startsWith("http")) activeHost = new URL(tab.url).hostname;
  } catch {}
  // a newer version was installed on disk: reload into it (this popup closes; open it again)
  if ((await send("checkUpdate").catch(() => ({}))).reloading) return;
  state = await send("state");
  $("version").textContent = `Totem ${chrome.runtime.getManifest().version}. Extension ID ${state.extensionId}`;
  if (!state.unlocked) return showLock();
  enterMain();
}

async function showLock() {
  clearInterval(tickTimer);
  show("lock");
  const first = !state.hasVault;
  $("pw2").hidden = !first;
  $("meter").hidden = true;
  $("pw").autocomplete = first ? "new-password" : "current-password";
  $("unlockBtn").textContent = first ? "Create vault" : "Unlock";
  $("lockTitle").textContent = first ? "Create your vault" : "Unlock Totem";
  $("lockHint").textContent = first ? "Choose a master password. It never leaves this device, and can't be recovered." : "Your codes stay encrypted on this device.";
  $("driveRestore").hidden = !first || !state.settings.driveClientId;
  $("pw").focus();
  const mac = await send("nativeStatus").catch(() => ({ connected: false }));
  if (mac.connected && mac.hasVault) {
    $("macUnlock").hidden = false;
    $("macUnlock").querySelector("span").textContent = first ? "Use my Mac's vault with Touch ID" : "Unlock with Touch ID on Mac";
  }
}

$("pw").addEventListener("input", () => { if (!state?.hasVault) meter($("meter"), $("pw").value); });

$("unlockForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("lockError").textContent = "";
  const pw = $("pw").value;
  const btn = $("unlockBtn");
  try {
    if (!state.hasVault) {
      if (strength(pw).score < MIN_SCORE) throw new Error(strength(pw).hint || "Choose a stronger password");
      if (pw !== $("pw2").value) throw new Error("The passwords don't match");
      btn.textContent = "Creating…";
      await send("create", { password: pw });
    } else {
      btn.textContent = "Unlocking…";
      await send("unlock", { password: pw });
    }
    $("pw").value = $("pw2").value = "";
    state = await send("state");
    enterMain();
  } catch (err) {
    $("lockError").textContent = err.message;
    btn.textContent = state.hasVault ? "Unlock" : "Create vault";
    $("pw").select();
  }
});

$("macUnlock").addEventListener("click", async () => {
  $("lockError").textContent = "";
  $("macUnlock").disabled = true;
  try {
    toast("Confirm on your Mac", 4000);
    await send("unlockWithMac");
    state = await send("state");
    enterMain();
  } catch (e) { $("lockError").textContent = e.message; }
  $("macUnlock").disabled = false;
});

$("driveRestore").addEventListener("click", async () => {
  const pw = $("pw").value;
  if (!pw) return ($("lockError").textContent = "Type the password of the vault in your Drive first");
  try {
    const r = await send("restoreFromDrive", { password: pw });
    toast(`Restored ${r.count} accounts`);
    state = await send("state");
    enterMain();
  } catch (e) { $("lockError").textContent = e.message; }
});

// ---------- main ----------
function enterMain() {
  show("main");
  document.body.classList.toggle("privacy", !!state.settings.privacyMode);
  tick();
  clearInterval(tickTimer);
  tickTimer = setInterval(tick, 1000);
  renderSyncDot();
}

async function tick() {
  try {
    const r = await send("codes");
    if (!r.codes) { state = await send("state"); return showLock(); }
    codes = r.codes;
    render();
  } catch (e) {
    if (e.code === "LOCKED") { state = await send("state"); showLock(); }
  }
}

function renderFuse() {
  const remaining = 30 - (Math.floor(Date.now() / 1000) % 30);
  const fuse = $("fuse").parentElement;
  const wrap = remaining === 30;
  fuse.classList.toggle("reset", wrap);
  fuse.classList.toggle("ending", remaining <= 5);
  $("fuse").style.transform = `scaleX(${remaining / 30})`;
}

function filtered() {
  const q = $("q").value.trim().toLowerCase();
  const list = codes.filter((c) => !q || `${c.issuer} ${c.label} ${(c.domains || []).join(" ")}`.toLowerCase().includes(q));
  return list.map((c, i) => [hostMatch(c) ? 0 : 1, i, c]).sort((a, b) => a[0] - b[0] || a[1] - b[1]).map((x) => x[2]);
}

function render() {
  renderFuse();
  const list = filtered();
  $("empty").hidden = codes.length > 0;
  $("list").hidden = codes.length === 0;
  sel = Math.min(sel, Math.max(0, list.length - 1));
  const ul = $("list");
  const existing = new Map([...ul.querySelectorAll(".acct")].map((li) => [li.dataset.id, li]));
  const keep = new Set();
  list.forEach((c, i) => {
    const li = existing.get(c.id) || buildRow(c);
    keep.add(c.id);
    updateRow(li, c);
    li.classList.toggle("sel", i === sel);
    li.setAttribute("aria-selected", String(i === sel));
    li.classList.toggle("match", hostMatch(c));
    if (ul.children[i] !== li) ul.insertBefore(li, ul.children[i] || null);
  });
  for (const [id, li] of existing) if (!keep.has(id)) li.remove();
  const nores = ul.querySelector(".nores");
  if (!list.length && codes.length) {
    if (!nores) { const li = document.createElement("li"); li.className = "nores"; li.textContent = "No accounts match your search"; ul.appendChild(li); }
  } else nores?.remove();
}

function buildRow(c) {
  const li = document.createElement("li");
  li.className = "acct";
  li.dataset.id = c.id;
  li.setAttribute("role", "option");
  const meta = document.createElement("div");
  meta.className = "meta";
  meta.innerHTML = `<div class="who"><span class="here" title="Saved for this site"></span><span class="name"></span></div><div class="sub2"></div>`;
  const otp = document.createElement("div");
  otp.className = "otp";
  otp.innerHTML = `<div class="code"></div><div class="next"></div>`;
  if (c.period && c.period !== 30) {
    const mf = document.createElement("div");
    mf.className = "mini-fuse";
    mf.innerHTML = "<span></span>";
    otp.appendChild(mf);
  }
  const more = document.createElement("button");
  more.className = "more";
  more.title = "Edit";
  more.setAttribute("aria-label", "Edit account");
  more.innerHTML = `<svg class="i" viewBox="0 0 24 24" style="width:15px;height:15px"><circle cx="6" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="18" cy="12" r="1"/></svg>`;
  more.addEventListener("click", (e) => { e.stopPropagation(); openEdit(li.dataset.id); });
  li.append(monogram(c.issuer || c.label), meta, otp, more);
  li.addEventListener("click", () => copy(li.dataset.id));
  return li;
}

function updateRow(li, c) {
  li.querySelector(".name").textContent = c.issuer || c.label || "Unnamed";
  li.querySelector(".sub2").textContent = c.issuer ? c.label : "";
  const codeEl = li.querySelector(".code");
  if (c.error) { codeEl.textContent = "Invalid key"; return; }
  if (!li.classList.contains("copied") && codeEl.dataset.v !== c.code) { codeEl.innerHTML = formatCode(c.code); codeEl.dataset.v = c.code; }
  li.querySelector(".next").textContent = `next ${c.next.slice(0, c.next.length / 2)} ${c.next.slice(c.next.length / 2)}`;
  const mf = li.querySelector(".mini-fuse span");
  if (mf) mf.style.transform = `scaleX(${c.remaining / c.period})`;
  li.classList.toggle("ending", c.remaining <= 5);
}

async function copy(id) {
  const c = codes.find((x) => x.id === id);
  if (!c?.code) return;
  // in the final 2 seconds, copy the next code so it doesn't expire before you paste it
  const value = c.remaining <= 2 ? c.next : c.code;
  await navigator.clipboard.writeText(value);
  send("copied").catch(() => {});
  const li = document.querySelector(`.acct[data-id="${CSS.escape(id)}"]`);
  if (!li) return;
  const codeEl = li.querySelector(".code");
  li.classList.add("copied");
  codeEl.textContent = c.remaining <= 2 ? "Next copied" : "Copied";
  setTimeout(() => { li.classList.remove("copied"); codeEl.dataset.v = ""; render(); }, 900);
}

$("q").addEventListener("input", () => { sel = 0; render(); });
document.addEventListener("keydown", (e) => {
  if ($("main").hidden) {
    if (e.key === "Escape" && $("lock").hidden) { e.preventDefault(); back(); }
    return;
  }
  const list = filtered();
  if (e.key === "ArrowDown") { sel = Math.min(list.length - 1, sel + 1); render(); e.preventDefault(); scrollSel(); }
  else if (e.key === "ArrowUp") { sel = Math.max(0, sel - 1); render(); e.preventDefault(); scrollSel(); }
  else if (e.key === "Enter" && list[sel]) { copy(list[sel].id); e.preventDefault(); }
  else if (e.key === "Escape" && $("q").value) { $("q").value = ""; render(); e.preventDefault(); }
  else if (document.activeElement !== $("q")) {
    if (e.key === "n") { e.preventDefault(); openAdd(); }
    if (e.key === "l") { e.preventDefault(); doLock(); }
  }
});
function scrollSel() { document.querySelector(".acct.sel")?.scrollIntoView({ block: "nearest" }); }

async function doLock() {
  clearInterval(tickTimer);
  await send("lock");
  state = await send("state");
  showLock();
}
$("lockBtn").addEventListener("click", doLock);
$("addBtn").addEventListener("click", () => openAdd());
$("emptyAdd").addEventListener("click", () => openAdd());
$("emptyScan").addEventListener("click", () => { openAdd(); $("scanTab").click(); });
$("settingsBtn").addEventListener("click", openSettings);
for (const b of document.querySelectorAll("[data-back]")) b.addEventListener("click", back);
function back() { $("qrBox").hidden = true; enterMain(); }

// ---------- sync ----------
function renderSyncDot() {
  const s = state.syncState || {};
  const dot = $("syncDot");
  const targets = [state.settings.nativeEnabled && s.mac, state.settings.driveEnabled && s.drive].filter(Boolean);
  dot.className = "dot " + (!targets.length ? "" : targets.every((t) => t.ok) ? "ok" : "err");
  const lines = [];
  if (state.settings.nativeEnabled) lines.push(`Mac: ${s.mac?.ok ? "synced " + ago(s.mac.at) : s.mac?.error || "not synced yet"}`);
  if (state.settings.driveEnabled) lines.push(`Drive: ${s.drive?.ok ? "synced " + ago(s.drive.at) : s.drive?.error || "not synced yet"}`);
  $("syncBtn").title = lines.join("\n") || "Sync is off. Turn it on in Settings.";
}
$("syncBtn").addEventListener("click", async () => {
  $("syncDot").className = "dot spin";
  try {
    const r = await send("sync", { interactive: true });
    const errs = Object.entries(r).filter(([, v]) => v && v.ok === false).map(([k, v]) => `${k === "mac" ? "Mac" : "Drive"}: ${v.error}`);
    toast(errs.length ? errs.join(" ") : "Synced", errs.length ? 4000 : 1500);
  } catch (e) { toast(e.message, 3500); }
  state = await send("state");
  renderSyncDot();
  tick();
});

// ---------- add ----------
function openAdd(prefill) {
  clearInterval(tickTimer);
  show("add");
  $("addError").textContent = "";
  $("addText").value = prefill || "";
  $("addText").focus();
}

async function addFromText(text) {
  const r = await send("importText", { text });
  if (r.needsPassword) throw new Error("That's a Totem backup. Import it from Settings.");
  toast(r.added ? `Added ${r.added} account${r.added > 1 ? "s" : ""}` + (r.skipped ? `, skipped ${r.skipped}` : "") : "Already in Totem");
  back();
}

$("addForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("addError").textContent = "";
  try {
    const text = $("addText").value.trim();
    if (text) return await addFromText(text);
    const secret = $("fSecret").value.trim();
    if (!secret) throw new Error("Scan a QR code, paste a link, or enter a secret key");
    const r = await send("add", { accounts: [{ issuer: $("fIssuer").value, label: $("fLabel").value, secret,
      algorithm: $("fAlg").value, digits: +$("fDigits").value, period: +$("fPeriod").value }] });
    toast(r.added ? "Account added" : "Already in Totem");
    for (const id of ["fIssuer", "fLabel", "fSecret"]) $(id).value = "";
    back();
  } catch (err) { $("addError").textContent = err.message; }
});

function decodeQR(img) {
  const canvas = $("canvas");
  const scale = Math.min(1, 2000 / Math.max(img.width, img.height));
  canvas.width = Math.round(img.width * scale);
  canvas.height = Math.round(img.height * scale);
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
  const data = ctx.getImageData(0, 0, canvas.width, canvas.height);
  return window.jsQR(data.data, data.width, data.height, { inversionAttempts: "attemptBoth" })?.data || null;
}
const loadImage = (src) => new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = src; });
async function handleQRResult(text) {
  if (!text) throw new Error("No QR code found. Make sure it's fully visible (zoom in if it's small), then try again.");
  if (!/^otpauth(-migration)?:\/\//.test(text)) throw new Error("That QR code isn't for an authenticator app");
  await addFromText(text);
}

$("scanTab").addEventListener("click", async () => {
  $("addError").textContent = "";
  try {
    const shot = await chrome.tabs.captureVisibleTab(null, { format: "png" });
    await handleQRResult(decodeQR(await loadImage(shot)));
  } catch (e) {
    $("addError").textContent = /permission|activeTab|Cannot access/i.test(e.message)
      ? "Can't read this tab. Open the site's QR page in a normal tab, then open Totem from the toolbar." : e.message;
  }
});
$("qrFile").addEventListener("change", async (e) => {
  const f = e.target.files[0];
  if (!f) return;
  try { await handleQRResult(decodeQR(await loadImage(URL.createObjectURL(f)))); }
  catch (err) { $("addError").textContent = err.message; }
  e.target.value = "";
});
document.addEventListener("paste", async (e) => {
  if ($("add").hidden) return;
  const item = [...(e.clipboardData?.items || [])].find((i) => i.type.startsWith("image/"));
  if (!item) return;
  e.preventDefault();
  try { await handleQRResult(decodeQR(await loadImage(URL.createObjectURL(item.getAsFile())))); }
  catch (err) { $("addError").textContent = err.message; }
});

// ---------- edit ----------
async function openEdit(id) {
  clearInterval(tickTimer);
  const { account } = await send("reveal", { id });
  editing = account;
  $("eMono").replaceChildren(monogram(account.issuer || account.label));
  $("eTitle").textContent = account.issuer || account.label || "Unnamed";
  $("eSub").textContent = account.issuer ? account.label : "";
  $("eIssuer").value = account.issuer;
  $("eLabel").value = account.label;
  $("eDomains").value = (account.domains || []).join(", ");
  $("eDomains").placeholder = activeHost ? activeHost.replace(/^www\./, "") : "github.com";
  $("ePinned").checked = !!account.pinned;
  $("qrBox").hidden = true;
  show("edit");
}
$("editForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const domains = $("eDomains").value.split(/[,\s]+/).map((d) => d.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "").replace(/^www\./, "")).filter(Boolean);
  await send("update", { id: editing.id, patch: { issuer: $("eIssuer").value, label: $("eLabel").value, domains, pinned: $("ePinned").checked } });
  toast("Saved");
  back();
});
$("eDelete").addEventListener("click", async () => {
  if (!confirm(`Delete ${editing.issuer || editing.label}? Make sure two-factor is turned off on that site, or you have another way in.`)) return;
  await send("remove", { id: editing.id });
  toast("Deleted");
  back();
});
$("eQr").addEventListener("click", async () => {
  const box = $("qrBox");
  if (!box.hidden) { box.hidden = true; return; }
  const { uri } = await send("reveal", { id: editing.id });
  const qr = window.qrcode(0, "M");
  qr.addData(uri);
  qr.make();
  box.innerHTML = qr.createSvgTag({ cellSize: 4, margin: 2, scalable: true });
  box.firstElementChild.style.width = "190px";
  const n = document.createElement("small");
  n.textContent = "Anyone who sees this can copy your two-factor codes. It hides itself after a minute.";
  box.appendChild(n);
  box.hidden = false;
  setTimeout(() => (box.hidden = true), 60000);
});

// ---------- settings ----------
async function openSettings() {
  clearInterval(tickTimer);
  state = await send("state");
  const s = state.settings;
  show("settings");
  $("sNative").checked = s.nativeEnabled;
  $("sDrive").checked = s.driveEnabled;
  $("sLock").value = String(s.autoLockMin);
  $("sClip").value = String(s.clipboardClearSec);
  $("sAutofill").checked = s.autofill;
  $("sPrivacy").checked = !!s.privacyMode;
  $("sDevice").value = s.device;
  $("clientId").value = s.driveClientId || "";
  $("redirectUri").textContent = chrome.identity.getRedirectURL("oauth2");
  const join = state.pendingJoin;
  $("joinCard").hidden = !join;
  if (join) $("joinText").textContent = `The vault in ${join === "mac" ? "Totem for Mac" : "Google Drive"} uses a different master password. Enter it to merge both into one vault.`;
  macInfo = await send("nativeStatus").catch((e) => ({ connected: false, error: e.message }));
  $("macStatus").textContent = macInfo.connected
    ? `Connected, ${macInfo.unlocked ? "unlocked" : "locked"}${state.syncState.mac?.at ? `. Synced ${ago(state.syncState.mac.at)}` : ""}`
    : macInfo.error || "Not found";
  renderDrive();
}
function renderDrive() {
  const s = state.settings, ds = state.syncState.drive, b = macInfo?.backup;
  let text;
  if (s.driveEnabled) text = ds?.ok ? `Backed up from this browser ${ago(ds.at)}` : ds?.error || "Connected from this browser";
  else if (b?.enabled) text = `${b.provider}. Last backup ${ago(b.at)}`;
  else if (macInfo?.connected) text = "Turn on in Totem for Mac, Settings, Backup";
  else text = "Set up in Totem for Mac";
  $("driveStatus").textContent = text;
  $("driveTools").hidden = !s.driveEnabled;
  $("driveOff").hidden = !s.driveEnabled;
  $("driveConnect").hidden = s.driveEnabled;
}
const saveSetting = (patch) => send("saveSettings", { patch }).then(async () => { state = await send("state"); });
$("sNative").addEventListener("change", (e) => saveSetting({ nativeEnabled: e.target.checked }));
$("sLock").addEventListener("change", (e) => saveSetting({ autoLockMin: +e.target.value }));
$("sClip").addEventListener("change", (e) => saveSetting({ clipboardClearSec: +e.target.value }));
$("sAutofill").addEventListener("change", (e) => saveSetting({ autofill: e.target.checked }));
$("sPrivacy").addEventListener("change", (e) => saveSetting({ privacyMode: e.target.checked }));
$("sDevice").addEventListener("change", (e) => saveSetting({ device: e.target.value.trim() || "Browser" }));
$("redirectUri").addEventListener("click", () => { navigator.clipboard.writeText($("redirectUri").textContent); toast("Copied"); });

$("driveConnect").addEventListener("click", async () => {
  const clientId = $("clientId").value.trim();
  if (!clientId.endsWith(".apps.googleusercontent.com")) return toast("That doesn't look like a Google OAuth client ID", 3000);
  try {
    $("driveConnect").textContent = "Connecting…";
    const r = await send("driveConnect", { clientId });
    toast(r.drive?.ok === false ? r.drive.error : "Google Drive connected. Backup saved.", 3000);
  } catch (e) { toast(e.message, 4000); }
  $("driveConnect").textContent = "Connect";
  state = await send("state");
  renderDrive();
});
$("driveOff").addEventListener("click", async () => {
  await send("driveDisconnect");
  state = await send("state");
  renderDrive();
});
$("backupNow").addEventListener("click", async () => {
  try {
    const r = await send("sync", { interactive: true, forceBackup: true });
    toast(r.drive?.ok ? "Backup saved to Google Drive" : r.drive?.error || "Backup failed", 3000);
  } catch (e) { toast(e.message, 3000); }
  state = await send("state");
  renderDrive();
});
$("showBackups").addEventListener("click", async () => {
  const ul = $("backupList");
  if (!ul.hidden) return (ul.hidden = true);
  ul.innerHTML = "<li>Loading…</li>";
  ul.hidden = false;
  try {
    const { backups } = await send("listBackups");
    ul.innerHTML = "";
    if (!backups.length) ul.innerHTML = "<li>No backups yet</li>";
    for (const b of backups) {
      const li = document.createElement("li");
      li.textContent = new Date(b.createdTime).toLocaleString();
      const btn = document.createElement("button");
      btn.className = "link";
      btn.textContent = "Restore";
      btn.onclick = async () => {
        try {
          let r;
          try { r = await send("restoreBackup", { id: b.id }); }
          catch (e) {
            if (e.code !== "KDF_MISMATCH") throw e;
            const pw = prompt("This backup used an older password. Enter it:");
            if (!pw) return;
            r = await send("restoreBackup", { id: b.id, password: pw });
          }
          toast(r.added ? `Brought back ${r.added} account${r.added > 1 ? "s" : ""}` : "Nothing missing. All accounts are already here.", 3000);
        } catch (e) { toast(e.message, 3000); }
      };
      li.appendChild(btn);
      ul.appendChild(li);
    }
  } catch (e) { ul.innerHTML = ""; toast(e.message, 3000); }
});
$("joinBtn").addEventListener("click", async () => {
  try {
    await send("joinVault", { password: $("joinPw").value });
    $("joinPw").value = "";
    toast("Merged. You now have one vault.", 2500);
    await send("sync", {});
    openSettings();
  } catch (e) { toast(e.message, 3000); }
});

// import
async function runImport(text) {
  try {
    let r = await send("importText", { text });
    if (r.needsPassword) {
      const pw = prompt("Password for that Totem backup:");
      if (!pw) return;
      r = await send("importText", { text, password: pw });
    }
    toast(`${r.kind}: added ${r.added}${r.skipped ? `, skipped ${r.skipped}` : ""}`, 3000);
    $("importText").value = "";
  } catch (e) { toast(e.message, 4500); }
}
$("importBtn").addEventListener("click", () => runImport($("importText").value));
$("importFile").addEventListener("change", async (e) => {
  const f = e.target.files[0];
  if (f) runImport(await f.text());
  e.target.value = "";
});
const drop = $("drop");
drop.addEventListener("dragover", (e) => { e.preventDefault(); drop.classList.add("over"); });
drop.addEventListener("dragleave", () => drop.classList.remove("over"));
drop.addEventListener("drop", async (e) => {
  e.preventDefault();
  drop.classList.remove("over");
  const f = e.dataTransfer.files[0];
  if (!f) return;
  if (f.type.startsWith("image/")) {
    try { await handleQRResult(decodeQR(await loadImage(URL.createObjectURL(f)))); } catch (err) { toast(err.message, 3500); }
  } else runImport(await f.text());
});

// export
$("exportEnc").addEventListener("click", async () => {
  const { envelope } = await send("exportVault");
  download(`totem-backup-${stamp()}.totem`, JSON.stringify(envelope, null, 2));
  toast("Saved. It opens with your master password.");
});
$("exportPlain").addEventListener("click", async () => {
  if (!confirm("This file will contain your two-factor secrets in plain text. Anyone with it can generate your codes. Continue?")) return;
  const { text } = await send("exportPlain");
  download(`totem-plain-${stamp()}.txt`, text, "text/plain");
});

// security
$("cpNew").addEventListener("input", () => meter($("cpMeter"), $("cpNew").value));
$("cpBtn").addEventListener("click", async () => {
  try {
    const r0 = strength($("cpNew").value);
    if (r0.score < MIN_SCORE) throw new Error(r0.hint || "Choose a stronger password");
    const r = await send("changePassword", { current: $("cpOld").value, next: $("cpNew").value });
    $("cpOld").value = $("cpNew").value = "";
    $("cpMeter").hidden = true;
    toast(r.warnings?.length ? `Changed. Other devices will ask for it once. (${r.warnings.join("; ")})` : "Password changed. Other devices will ask for it once.", 4500);
  } catch (e) { toast(e.message, 3000); }
});
$("resetBtn").addEventListener("click", async () => {
  if (!confirm("Erase the vault from this browser? Your Mac app and Google Drive copies stay as they are.")) return;
  if (prompt('Type "erase" to confirm') !== "erase") return;
  await send("reset");
  state = await send("state");
  showLock();
});

boot().catch((e) => { document.body.textContent = e.message; });
