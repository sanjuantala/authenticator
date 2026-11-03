// Totem: encrypted vault format, shared byte-for-byte with the Mac app.
// See docs/VAULT_FORMAT.md. PBKDF2-SHA256 (600k) -> AES-256-GCM, AAD "totem-vault-v1".

import { normalizeSecret, normalizeAlgorithm, base32Decode } from "./totp.js";

export const FORMAT = "totem-vault";
export const VERSION = 1;
export const ITERATIONS = 600000;
const AAD = new TextEncoder().encode("totem-vault-v1");

export const b64 = {
  enc(bytes) {
    let s = "";
    const u = new Uint8Array(bytes);
    for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000));
    return btoa(s);
  },
  dec(str) {
    const s = atob(str);
    const u = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
    return u;
  },
};

export function randomBytes(n) {
  return crypto.getRandomValues(new Uint8Array(n));
}

export function uuid() {
  return crypto.randomUUID();
}

/** Derive raw 32-byte key material from a password. */
export async function deriveKeyBytes(password, salt, iterations = ITERATIONS) {
  const base = await crypto.subtle.importKey("raw", new TextEncoder().encode(String(password).normalize("NFC")), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, base, 256);
  return new Uint8Array(bits);
}

async function aesKey(raw) {
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

/**
 * A "session" is what we keep while unlocked: the raw key + the KDF params it came from.
 * Raw key is kept only in memory/session storage, never written to disk.
 */
export async function createSession(password, iterations = ITERATIONS) {
  const salt = randomBytes(16);
  const key = await deriveKeyBytes(password, salt, iterations);
  return { key: b64.enc(key), salt: b64.enc(salt), iterations };
}

export async function sessionForEnvelope(password, env) {
  assertEnvelope(env);
  const salt = b64.dec(env.kdf.salt);
  const key = await deriveKeyBytes(password, salt, env.kdf.iterations);
  const session = { key: b64.enc(key), salt: env.kdf.salt, iterations: env.kdf.iterations };
  await openEnvelope(env, session); // throws on wrong password
  return session;
}

export function assertEnvelope(env) {
  if (!env || env.format !== FORMAT) throw new Error("Not a Totem vault file");
  if (env.version !== VERSION) throw new Error(`Unsupported vault version ${env.version}`);
}

export async function sealEnvelope(data, session, device = "unknown") {
  const iv = randomBytes(12);
  const plain = new TextEncoder().encode(JSON.stringify(data));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: AAD, tagLength: 128 },
    await aesKey(b64.dec(session.key)), plain);
  return {
    format: FORMAT,
    version: VERSION,
    kdf: { alg: "PBKDF2-SHA256", iterations: session.iterations, salt: session.salt },
    cipher: { alg: "AES-256-GCM", iv: b64.enc(iv), data: b64.enc(ct) },
    updatedAt: data.updatedAt || Date.now(),
    device,
  };
}

export async function openEnvelope(env, session) {
  assertEnvelope(env);
  if (env.kdf.salt !== session.salt || env.kdf.iterations !== session.iterations) {
    const e = new Error("This vault was locked with a different password setup");
    e.code = "KDF_MISMATCH";
    throw e;
  }
  try {
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: b64.dec(env.cipher.iv), additionalData: AAD, tagLength: 128 },
      await aesKey(b64.dec(session.key)), b64.dec(env.cipher.data));
    return normalizeData(JSON.parse(new TextDecoder().decode(plain)));
  } catch (e) {
    if (e.code) throw e;
    const err = new Error("Wrong password or damaged vault");
    err.code = "BAD_PASSWORD";
    throw err;
  }
}

// ---------- data model ----------

export function emptyData() {
  return { accounts: [], updatedAt: Date.now() };
}

export function normalizeData(d) {
  return {
    accounts: Array.isArray(d?.accounts) ? d.accounts.map(normalizeAccount) : [],
    updatedAt: d?.updatedAt || 0,
  };
}

export function normalizeAccount(a) {
  const now = Date.now();
  if (a.deleted) {
    return { id: a.id, deleted: true, updatedAt: a.updatedAt || now, createdAt: a.createdAt || now,
      issuer: "", label: "", secret: "", algorithm: "SHA1", digits: 6, period: 30, domains: [], order: 0 };
  }
  const secret = normalizeSecret(a.secret);
  base32Decode(secret);
  return {
    id: a.id || uuid(),
    issuer: String(a.issuer || "").trim(),
    label: String(a.label || "").trim(),
    secret,
    algorithm: normalizeAlgorithm(a.algorithm),
    digits: [6, 7, 8].includes(+a.digits) ? +a.digits : 6,
    period: +a.period > 0 ? +a.period : 30,
    domains: Array.isArray(a.domains) ? a.domains.map((x) => String(x).toLowerCase().trim()).filter(Boolean) : [],
    order: Number.isFinite(+a.order) ? +a.order : 0,
    pinned: !!a.pinned,
    createdAt: a.createdAt || now,
    updatedAt: a.updatedAt || now,
    deleted: false,
  };
}

/** Same secret + issuer + label = the same account (used to skip duplicates on import). */
export function fingerprint(a) {
  return `${a.secret}|${(a.issuer || "").toLowerCase()}|${(a.label || "").toLowerCase()}`;
}

/**
 * Merge two vault datasets. Per account, the newest updatedAt wins; deletions are kept
 * as tombstones so a delete on one device is not undone by the other.
 */
export function mergeData(a, b) {
  const byId = new Map();
  for (const acc of [...(a?.accounts || []), ...(b?.accounts || [])]) {
    const cur = byId.get(acc.id);
    if (!cur || (acc.updatedAt || 0) > (cur.updatedAt || 0)) byId.set(acc.id, acc);
  }
  // collapse live duplicates (same secret/issuer/label added on both sides with different ids)
  const seen = new Map();
  const out = [];
  for (const acc of [...byId.values()].sort((x, y) => (x.createdAt || 0) - (y.createdAt || 0))) {
    if (acc.deleted) { out.push(acc); continue; }
    const fp = fingerprint(acc);
    if (seen.has(fp)) continue;
    seen.set(fp, true);
    out.push(acc);
  }
  return { accounts: out, updatedAt: Math.max(a?.updatedAt || 0, b?.updatedAt || 0) };
}

export function sameData(a, b) {
  const key = (d) => JSON.stringify([...d.accounts].sort((x, y) => (x.id < y.id ? -1 : 1)).map((x) => [x.id, x.updatedAt]));
  return key(a) === key(b);
}

export function liveAccounts(data) {
  return data.accounts.filter((a) => !a.deleted)
    .sort((a, b) => (b.pinned - a.pinned) || (a.order - b.order) || (a.issuer || a.label).localeCompare(b.issuer || b.label));
}

/** Add accounts, skipping ones already present. Returns { data, added, skipped }. */
export function addAccounts(data, incoming) {
  const existing = new Set(data.accounts.filter((a) => !a.deleted).map(fingerprint));
  const now = Date.now();
  let added = 0, skipped = 0;
  const accounts = [...data.accounts];
  for (const raw of incoming) {
    const acc = normalizeAccount({ ...raw, id: uuid(), createdAt: now, updatedAt: now });
    if (existing.has(fingerprint(acc))) { skipped++; continue; }
    existing.add(fingerprint(acc));
    accounts.push(acc);
    added++;
  }
  return { data: { accounts, updatedAt: now }, added, skipped };
}

export function updateAccount(data, id, patch) {
  const now = Date.now();
  return {
    accounts: data.accounts.map((a) => (a.id === id ? normalizeAccount({ ...a, ...patch, id, updatedAt: now }) : a)),
    updatedAt: now,
  };
}

export function deleteAccount(data, id) {
  const now = Date.now();
  return {
    accounts: data.accounts.map((a) => (a.id === id ? normalizeAccount({ id, deleted: true, createdAt: a.createdAt, updatedAt: now }) : a)),
    updatedAt: now,
  };
}

/** Re-encrypt with a new password (new salt). */
export async function changePassword(data, newPassword) {
  return createSession(newPassword);
}
