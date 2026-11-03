// Totem — Google Drive sync + backups (scope: drive.file → the app only sees files it created).
// Layout in your Drive:  /Totem Authenticator/totem-vault.json            ← live synced vault (encrypted)
//                        /Totem Authenticator/backups/totem-backup-*.json  ← dated snapshots (encrypted)
// Uses launchWebAuthFlow so it works in Chrome, Brave and Edge.

const API = "https://www.googleapis.com/drive/v3";
const UPLOAD = "https://www.googleapis.com/upload/drive/v3";
const SCOPE = "https://www.googleapis.com/auth/drive.file";
export const FOLDER = "Totem Authenticator";
export const LIVE_FILE = "totem-vault.json";
const KEEP_BACKUPS = 30;

async function cachedToken() {
  const { driveToken } = await chrome.storage.session.get("driveToken");
  if (driveToken && driveToken.expires > Date.now() + 60_000) return driveToken.value;
  return null;
}

export async function getToken(clientId, interactive) {
  const cached = await cachedToken();
  if (cached) return cached;
  if (!clientId) throw new Error("Add your Google OAuth client ID in Settings first");
  const redirect = chrome.identity.getRedirectURL("oauth2");
  const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.search = new URLSearchParams({
    client_id: clientId, response_type: "token", redirect_uri: redirect, scope: SCOPE,
    include_granted_scopes: "true", prompt: interactive ? "select_account" : "none",
  });
  let result;
  try {
    result = await chrome.identity.launchWebAuthFlow({ url: url.toString(), interactive });
  } catch (e) {
    const err = new Error(interactive ? `Google sign-in failed: ${e.message}` : "Google sign-in needed");
    err.code = "AUTH_REQUIRED";
    throw err;
  }
  const params = new URLSearchParams(new URL(result).hash.slice(1));
  if (params.get("error")) {
    const err = new Error(`Google sign-in: ${params.get("error")}`);
    err.code = "AUTH_REQUIRED";
    throw err;
  }
  const value = params.get("access_token");
  const expires = Date.now() + (parseInt(params.get("expires_in") || "3600", 10) * 1000);
  await chrome.storage.session.set({ driveToken: { value, expires } });
  return value;
}

export async function signOut() {
  const t = await cachedToken();
  await chrome.storage.session.remove("driveToken");
  if (t) fetch(`https://oauth2.googleapis.com/revoke?token=${t}`, { method: "POST" }).catch(() => {});
}

async function api(token, path, opts = {}, base = API) {
  const res = await fetch(base + path, { ...opts, headers: { Authorization: `Bearer ${token}`, ...(opts.headers || {}) } });
  if (res.status === 401) {
    await chrome.storage.session.remove("driveToken");
    const err = new Error("Google sign-in expired");
    err.code = "AUTH_REQUIRED";
    throw err;
  }
  if (!res.ok) throw new Error(`Google Drive error ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return res.status === 204 ? null : res;
}

const q = (s) => s.replace(/\\/g, "\\\\").replace(/'/g, "\\'");

async function findOne(token, name, parent, folder = false) {
  const query = [`name='${q(name)}'`, "trashed=false",
    parent ? `'${parent}' in parents` : null,
    folder ? "mimeType='application/vnd.google-apps.folder'" : null].filter(Boolean).join(" and ");
  const res = await api(token, `/files?spaces=drive&fields=files(id,name,modifiedTime)&q=${encodeURIComponent(query)}`);
  return (await res.json()).files?.[0] || null;
}

async function ensureFolder(token, name, parent) {
  const found = await findOne(token, name, parent, true);
  if (found) return found.id;
  const res = await api(token, "/files?fields=id", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, mimeType: "application/vnd.google-apps.folder", ...(parent ? { parents: [parent] } : {}) }),
  });
  return (await res.json()).id;
}

async function createFile(token, name, parent, content) {
  const boundary = "totem" + crypto.randomUUID();
  const body = `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n` +
    JSON.stringify({ name, parents: [parent], mimeType: "application/json" }) +
    `\r\n--${boundary}\r\nContent-Type: application/json\r\n\r\n${content}\r\n--${boundary}--`;
  const res = await api(token, "/files?uploadType=multipart&fields=id", {
    method: "POST", headers: { "Content-Type": `multipart/related; boundary=${boundary}` }, body,
  }, UPLOAD);
  return (await res.json()).id;
}

async function updateFile(token, id, content) {
  await api(token, `/files/${id}?uploadType=media`, {
    method: "PATCH", headers: { "Content-Type": "application/json" }, body: content,
  }, UPLOAD);
}

async function folders(token) {
  const root = await ensureFolder(token, FOLDER, null);
  const backups = await ensureFolder(token, "backups", root);
  return { root, backups };
}

/** Download the live vault envelope from Drive (or null if none yet). */
export async function pullVault(token) {
  const { root } = await folders(token);
  const file = await findOne(token, LIVE_FILE, root);
  if (!file) return null;
  const res = await api(token, `/files/${file.id}?alt=media`);
  return JSON.parse(await res.text());
}

/** Upload the live vault envelope, plus one dated backup per day (keeps the last 30). */
export async function pushVault(token, envelope, { forceBackup = false } = {}) {
  const { root, backups } = await folders(token);
  const content = JSON.stringify(envelope, null, 2);
  const live = await findOne(token, LIVE_FILE, root);
  if (live) await updateFile(token, live.id, content);
  else await createFile(token, LIVE_FILE, root, content);

  const day = new Date().toISOString().slice(0, 10);
  const name = forceBackup
    ? `totem-backup-${new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)}.json`
    : `totem-backup-${day}.json`;
  const existing = await findOne(token, name, backups);
  if (existing) await updateFile(token, existing.id, content);
  else await createFile(token, name, backups, content);
  await prune(token, backups);
}

async function prune(token, backupsFolder) {
  const query = encodeURIComponent(`'${backupsFolder}' in parents and trashed=false`);
  const res = await api(token, `/files?spaces=drive&orderBy=createdTime desc&pageSize=200&fields=files(id)&q=${query}`);
  const files = (await res.json()).files || [];
  for (const f of files.slice(KEEP_BACKUPS)) await api(token, `/files/${f.id}`, { method: "DELETE" }).catch(() => {});
}

export async function listBackups(token) {
  const { backups } = await folders(token);
  const query = encodeURIComponent(`'${backups}' in parents and trashed=false`);
  const res = await api(token, `/files?spaces=drive&orderBy=createdTime desc&pageSize=50&fields=files(id,name,createdTime)&q=${query}`);
  return (await res.json()).files || [];
}

export async function downloadFile(token, id) {
  const res = await api(token, `/files/${id}?alt=media`);
  return JSON.parse(await res.text());
}
