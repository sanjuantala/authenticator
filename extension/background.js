// Totem — background service worker.
// Secrets stay here. The popup gets codes; content scripts only ever get a code for the page's own site,
// and only after you click the Totem button or use the shortcut.
import * as V from "./lib/vault.js";
import { totp, toOtpAuthUri } from "./lib/totp.js";
import { parseImport, exportOtpAuthText } from "./lib/importers.js";
import * as Drive from "./lib/drive.js";

const NATIVE_HOST = "com.totem.bridge";
const DEFAULT_SETTINGS = {
  device: "Browser", autoLockMin: 15, clipboardClearSec: 30, autofill: true,
  driveEnabled: false, driveClientId: "", nativeEnabled: true, privacyMode: false,
};

let cache = null; // { data, session }

// ---------- storage helpers ----------
async function getLocal(keys) { return chrome.storage.local.get(keys); }
async function settings() {
  const { settings } = await getLocal("settings");
  return { ...DEFAULT_SETTINGS, ...(settings || {}) };
}
async function setSyncState(patch) {
  const { syncState } = await getLocal("syncState");
  await chrome.storage.local.set({ syncState: { ...(syncState || {}), ...patch } });
}

async function unlocked() {
  if (cache) return cache;
  const { session } = await chrome.storage.session.get("session");
  const { vault } = await getLocal("vault");
  if (!session || !vault) return null;
  try {
    cache = { session, data: await V.openEnvelope(vault, session) };
    return cache;
  } catch {
    await chrome.storage.session.remove("session");
    return null;
  }
}

async function saveData(data, { sync = true } = {}) {
  const s = await settings();
  const env = await V.sealEnvelope(data, cache.session, s.device);
  await chrome.storage.local.set({ vault: env });
  cache.data = data;
  if (sync) scheduleSync();
  return env;
}

async function startSession(session, data) {
  cache = { session, data };
  await chrome.storage.session.set({ session });
  await touch();
}

async function lock() {
  cache = null;
  await chrome.storage.session.remove(["session", "driveToken"]);
  chrome.alarms.clear("autolock");
}

async function touch() {
  const { autoLockMin } = await settings();
  if (autoLockMin > 0) chrome.alarms.create("autolock", { delayInMinutes: autoLockMin });
}

// ---------- codes ----------
async function codes() {
  const c = await unlocked();
  if (!c) return null;
  const now = Date.now();
  return Promise.all(V.liveAccounts(c.data).map(async (a) => {
    try {
      const t = await totp(a, now);
      return { id: a.id, issuer: a.issuer, label: a.label, domains: a.domains, pinned: a.pinned,
        digits: a.digits, period: a.period, algorithm: a.algorithm, ...t };
    } catch (e) {
      return { id: a.id, issuer: a.issuer, label: a.label, error: e.message };
    }
  }));
}

/**
 * Anti-phishing: a code is filled automatically ONLY on a site saved for that account
 * (exact host or its subdomain). A name-based guess ("github" in the address) is never
 * filled silently — the page shows the real address and asks you first, then remembers it.
 */
const cleanHost = (h) => String(h || "").toLowerCase().replace(/^www\./, "");

function isSavedSite(account, host) {
  host = cleanHost(host);
  return (account.domains || []).some((d) => host === d || host.endsWith("." + d));
}

function looksLike(account, host) {
  const issuer = (account.issuer || "").toLowerCase().replace(/[^a-z0-9]/g, "");
  if (issuer.length < 3) return false;
  return cleanHost(host).replace(/[^a-z0-9]/g, "").includes(issuer);
}

async function codeFor(a) {
  const t = await totp(a, Date.now());
  // in the last 3 seconds of a window, hand out the next code so it doesn't expire mid-submit
  return t.remaining <= 3 ? t.next : t.code;
}

async function matchesFor(host) {
  const c = await unlocked();
  if (!c) return { status: "locked" };
  const live = V.liveAccounts(c.data);
  const saved = live.filter((a) => isSavedSite(a, host));
  await touch();
  if (saved.length) {
    return { status: "ok", matches: await Promise.all(saved.map(async (a) => ({ id: a.id, issuer: a.issuer, label: a.label, code: await codeFor(a) }))) };
  }
  const guesses = live.filter((a) => looksLike(a, host));
  if (guesses.length) {
    return { status: "confirm", host: cleanHost(host), candidates: guesses.map((a) => ({ id: a.id, issuer: a.issuer, label: a.label })) };
  }
  return { status: "none", host: cleanHost(host) };
}

/** You confirmed this site belongs to the account: remember it, then fill. */
async function confirmAndFill(host, id) {
  const c = await need();
  const a = c.data.accounts.find((x) => x.id === id && !x.deleted);
  if (!a) throw new Error("Account not found");
  const h = cleanHost(host);
  if (!isSavedSite(a, h)) await saveData(V.updateAccount(c.data, id, { domains: [...(a.domains || []), h] }));
  return { status: "ok", matches: [{ id: a.id, issuer: a.issuer, label: a.label, code: await codeFor(a) }] };
}

// ---------- sync ----------
let syncTimer = null;
function scheduleSync() {
  clearTimeout(syncTimer);
  syncTimer = setTimeout(() => syncAll().catch(() => {}), 1500);
}

async function native(msg) {
  try {
    const r = await chrome.runtime.sendNativeMessage(NATIVE_HOST, msg);
    if (!r) throw new Error("No reply from Totem for Mac");
    return r;
  } catch (e) {
    const err = new Error(/not found|Specified native messaging host/i.test(e.message)
      ? "Totem for Mac bridge isn't installed" : e.message);
    err.code = "NATIVE_UNAVAILABLE";
    throw err;
  }
}

/** Pull from each source, merge, then push the merged vault back wherever it differs. */
let syncing = null;
async function syncAll({ interactive = false, forceBackup = false } = {}) {
  if (syncing) return syncing;
  syncing = (async () => {
    const c = await unlocked();
    if (!c) return { skipped: "locked" };
    const s = await settings();
    const report = {};
    let merged = c.data;
    const remotes = [];

    if (s.nativeEnabled) {
      try {
        const r = await native({ type: "getVault" });
        remotes.push({ name: "mac", env: r.vault, base: r.vault?.updatedAt ?? null });
      } catch (e) { report.mac = { ok: false, error: e.message, code: e.code }; }
    }
    let token = null;
    if (s.driveEnabled) {
      try {
        token = await Drive.getToken(s.driveClientId, interactive);
        remotes.push({ name: "drive", env: await Drive.pullVault(token) });
      } catch (e) { report.drive = { ok: false, error: e.message, code: e.code }; }
    }

    for (const r of remotes) {
      if (!r.env) continue;
      try {
        r.data = await V.openEnvelope(r.env, c.session);
        merged = V.mergeData(merged, r.data);
      } catch (e) {
        r.failed = true;
        report[r.name] = { ok: false, error: e.code === "KDF_MISMATCH"
          ? "Uses a different password setup — enter that vault's password in Settings to join it" : e.message, code: e.code };
        if (e.code === "KDF_MISMATCH") await chrome.storage.local.set({ pendingJoin: { source: r.name, env: r.env } });
      }
    }

    if (!V.sameData(merged, c.data)) await saveData(merged, { sync: false });
    const env = await V.sealEnvelope(merged, c.session, s.device);

    for (const r of remotes) {
      if (r.failed) continue;
      try {
        if (!r.env || !r.data || !V.sameData(r.data, merged) || forceBackup) {
          if (r.name === "mac") {
            const res = await native({ type: "putVault", vault: env, base: r.base });
            if (!res.ok) throw new Error(res.error || "Mac app rejected the update");
          } else await Drive.pushVault(token, env, { forceBackup });
        }
        report[r.name] = { ok: true, at: Date.now() };
      } catch (e) { report[r.name] = { ok: false, error: e.message }; }
    }
    await setSyncState({ ...report, lastRun: Date.now() });
    return report;
  })();
  try { return await syncing; } finally { syncing = null; }
}

// ---------- clipboard auto-clear (offscreen document) ----------
async function scheduleClipboardClear() {
  const { clipboardClearSec } = await settings();
  if (!clipboardClearSec) return;
  chrome.alarms.create("clipboard", { when: Date.now() + clipboardClearSec * 1000 });
}
async function clearClipboard() {
  try {
    if (!(await chrome.offscreen.hasDocument?.())) {
      await chrome.offscreen.createDocument({ url: "offscreen.html", reasons: ["CLIPBOARD"], justification: "Clear a copied 2FA code" });
    }
    await chrome.runtime.sendMessage({ target: "offscreen", type: "clear" });
    setTimeout(() => chrome.offscreen.closeDocument().catch(() => {}), 2000);
  } catch {}
}

// ---------- message router ----------
const handlers = {
  async checkUpdate() { return { reloading: await reloadIfUpdated() }; },
  async state() {
    const { vault, syncState, pendingJoin } = await getLocal(["vault", "syncState", "pendingJoin"]);
    return { hasVault: !!vault, unlocked: !!(await unlocked()), settings: await settings(),
      syncState: syncState || {}, pendingJoin: pendingJoin ? pendingJoin.source : null, extensionId: chrome.runtime.id };
  },
  async create({ password }) {
    if (!password || password.length < 10) throw new Error("Use at least 10 characters");
    const session = await V.createSession(password);
    await startSession(session, V.emptyData());
    await saveData(cache.data);
    return { ok: true };
  },
  async unlock({ password }) {
    const { vault } = await getLocal("vault");
    const session = await V.sessionForEnvelope(password, vault);
    await startSession(session, await V.openEnvelope(vault, session));
    scheduleSync();
    return { ok: true };
  },
  /** Unlock with Touch ID through the Mac app (it asks you to confirm on the Mac). */
  async unlockWithMac() {
    const r = await native({ type: "requestKey", reason: "unlock Totem in your browser" });
    if (!r.ok) throw new Error(r.error || "Mac app declined");
    const session = r.session;
    const { vault } = await getLocal("vault");
    if (vault) {
      try {
        await startSession(session, await V.openEnvelope(vault, session));
      } catch (e) {
        if (e.code !== "KDF_MISMATCH") throw e;
        // different vaults: adopt the Mac's, keeping local accounts
        await chrome.storage.local.set({ pendingJoin: { source: "mac", env: r.vault } });
        throw new Error("This browser's vault uses a different password. Use “Join vault” in Settings.");
      }
    } else {
      await startSession(session, r.vault ? await V.openEnvelope(r.vault, session) : V.emptyData());
      await saveData(cache.data);
    }
    scheduleSync();
    return { ok: true };
  },
  async restoreFromDrive({ password }) {
    const s = await settings();
    const token = await Drive.getToken(s.driveClientId, true);
    const env = await Drive.pullVault(token);
    if (!env) throw new Error("No Totem vault found in your Google Drive yet");
    const session = await V.sessionForEnvelope(password, env);
    await startSession(session, await V.openEnvelope(env, session));
    await saveData(cache.data);
    return { ok: true, count: V.liveAccounts(cache.data).length };
  },
  async lock() { await lock(); return { ok: true }; },
  async codes() { await touch(); return { codes: await codes() }; },
  async add({ accounts }) {
    const c = await need();
    const r = V.addAccounts(c.data, accounts);
    await saveData(r.data);
    return { added: r.added, skipped: r.skipped };
  },
  async update({ id, patch }) {
    const c = await need();
    await saveData(V.updateAccount(c.data, id, patch));
    return { ok: true };
  },
  async remove({ id }) {
    const c = await need();
    await saveData(V.deleteAccount(c.data, id));
    return { ok: true };
  },
  async reveal({ id }) {
    const c = await need();
    const a = c.data.accounts.find((x) => x.id === id && !x.deleted);
    if (!a) throw new Error("Account not found");
    return { account: a, uri: toOtpAuthUri(a) };
  },
  async importText({ text, password }) {
    const c = await need();
    const parsed = parseImport(text);
    if (parsed.kind === "totem") {
      if (!password) return { needsPassword: true };
      const s = await V.sessionForEnvelope(password, parsed.envelope);
      const other = await V.openEnvelope(parsed.envelope, s);
      const r = V.addAccounts(c.data, V.liveAccounts(other));
      await saveData(r.data);
      return { kind: "Totem", added: r.added, skipped: r.skipped };
    }
    const r = V.addAccounts(c.data, parsed.accounts);
    await saveData(r.data);
    return { kind: parsed.kind, added: r.added, skipped: r.skipped + (parsed.skipped || 0) };
  },
  async exportVault() {
    const c = await need();
    return { envelope: await V.sealEnvelope(c.data, c.session, (await settings()).device) };
  },
  async exportPlain() {
    const c = await need();
    return { text: exportOtpAuthText(V.liveAccounts(c.data)) };
  },
  async changePassword({ current, next }) {
    const c = await need();
    const { vault } = await getLocal("vault");
    await V.sessionForEnvelope(current, vault);
    if (!next || next.length < 10) throw new Error("Use at least 10 characters");
    const session = await V.createSession(next);
    await startSession(session, { ...c.data, updatedAt: Date.now() });
    await saveData(cache.data, { sync: false });
    // push to every target so other devices see the new setup and ask for the new password once
    const s = await settings();
    const env = await V.sealEnvelope(cache.data, session, s.device);
    const errors = [];
    if (s.nativeEnabled) await native({ type: "putVault", vault: env, force: true }).catch((e) => errors.push(e.message));
    if (s.driveEnabled) {
      try { await Drive.pushVault(await Drive.getToken(s.driveClientId, true), env, { forceBackup: true }); }
      catch (e) { errors.push(e.message); }
    }
    return { ok: true, warnings: errors };
  },
  /** Join a vault that was created elsewhere (different salt): merge it, then adopt its key setup. */
  async joinVault({ password }) {
    const c = await need();
    const { pendingJoin } = await getLocal("pendingJoin");
    if (!pendingJoin) throw new Error("Nothing to join");
    const session = await V.sessionForEnvelope(password, pendingJoin.env);
    const remote = await V.openEnvelope(pendingJoin.env, session);
    const merged = V.mergeData(c.data, remote);
    await startSession(session, merged);
    await saveData(merged);
    await chrome.storage.local.remove("pendingJoin");
    return { ok: true };
  },
  async sync({ interactive, forceBackup }) { return syncAll({ interactive, forceBackup }); },
  async driveConnect({ clientId }) {
    const s = await settings();
    const id = (clientId || s.driveClientId || "").trim();
    await chrome.storage.local.set({ settings: { ...s, driveClientId: id } });
    await Drive.getToken(id, true);
    await chrome.storage.local.set({ settings: { ...s, driveClientId: id, driveEnabled: true } });
    return syncAll({ forceBackup: true });
  },
  async driveDisconnect() {
    const s = await settings();
    await Drive.signOut();
    await chrome.storage.local.set({ settings: { ...s, driveEnabled: false } });
    return { ok: true };
  },
  async listBackups() {
    const s = await settings();
    return { backups: await Drive.listBackups(await Drive.getToken(s.driveClientId, true)) };
  },
  async restoreBackup({ id, password }) {
    const c = await need();
    const s = await settings();
    const env = await Drive.downloadFile(await Drive.getToken(s.driveClientId, true), id);
    const bs = password ? await V.sessionForEnvelope(password, env) : c.session;
    const data = await V.openEnvelope(env, bs);
    const r = V.addAccounts(c.data, V.liveAccounts(data)); // restore = bring back missing accounts, never wipe
    await saveData(r.data);
    return { added: r.added, skipped: r.skipped };
  },
  async nativeStatus() {
    try { return { connected: true, ...(await native({ type: "status" })), ok: true }; }
    catch (e) { return { connected: false, error: e.message }; }
  },
  async saveSettings({ patch }) {
    const s = await settings();
    await chrome.storage.local.set({ settings: { ...s, ...patch } });
    if (cache) await touch();
    return { ok: true };
  },
  async copied() { await scheduleClipboardClear(); await touch(); return { ok: true }; },
  async fill({ host }) {
    if (!(await settings()).autofill) return { status: "off" };
    return matchesFor(host);
  },
  async fillConfirm({ host, id }) {
    if (!(await settings()).autofill) return { status: "off" };
    return confirmAndFill(host, id);
  },
  async reset() { await lock(); await chrome.storage.local.clear(); return { ok: true }; },
};

async function need() {
  const c = await unlocked();
  if (!c) { const e = new Error("Totem is locked"); e.code = "LOCKED"; throw e; }
  return c;
}

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg?.target === "offscreen") return false;
  const h = handlers[msg?.type];
  if (!h) return false;
  // content scripts may only ask for a fill, and only for the frame's own host
  if (sender.tab && sender.id === chrome.runtime.id && !sender.url?.startsWith(chrome.runtime.getURL(""))) {
    // the host always comes from Chrome (sender.url), never from the page
    if (msg.type !== "fill" && msg.type !== "fillConfirm") return false;
    try { msg = { type: msg.type, id: String(msg.id || ""), host: new URL(sender.url).hostname }; } catch { return false; }
  }
  h(msg).then((r) => reply({ ok: true, ...r }), (e) => reply({ ok: false, error: e.message, code: e.code }));
  return true;
});

// ---------- self-update ----------
// The installer replaces this folder's files. Chrome keeps running the old copy until the extension
// reloads, so check the version on disk and reload when it changed. (Locks the vault: unlock once after.)
async function reloadIfUpdated() {
  try {
    const disk = await (await fetch(chrome.runtime.getURL("manifest.json"), { cache: "no-store" })).json();
    if (disk.version && disk.version !== chrome.runtime.getManifest().version) {
      chrome.runtime.reload();
      return true;
    }
  } catch {}
  return false;
}

// ---------- alarms, idle, shortcuts, menu ----------
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === "files") reloadIfUpdated();
  else if (a.name === "autolock") lock();
  else if (a.name === "sync") syncAll().catch(() => {});
  else if (a.name === "clipboard") clearClipboard();
});
chrome.idle.onStateChanged.addListener((state) => { if (state === "locked") lock(); });

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create("sync", { periodInMinutes: 10 });
  chrome.alarms.create("files", { periodInMinutes: 1 });
  chrome.contextMenus.create({ id: "totem-fill", title: "Fill 2FA code with Totem", contexts: ["editable"] });
  chrome.storage.session.setAccessLevel?.({ accessLevel: "TRUSTED_CONTEXTS" });
});
chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create("sync", { periodInMinutes: 10 });
  chrome.alarms.create("files", { periodInMinutes: 1 });
  reloadIfUpdated();
});

function triggerFill(tabId, frameId) {
  chrome.tabs.sendMessage(tabId, { type: "totem-fill-now" }, frameId !== undefined ? { frameId } : undefined).catch(() => {});
}
chrome.contextMenus.onClicked.addListener((info, tab) => { if (info.menuItemId === "totem-fill" && tab) triggerFill(tab.id, info.frameId); });
chrome.commands.onCommand.addListener(async (cmd) => {
  if (cmd !== "fill-code") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab) triggerFill(tab.id);
});
