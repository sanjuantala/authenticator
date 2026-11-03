// Totem — import/export. Supports:
//  • otpauth:// links (one per line, or any text containing them)
//  • Google Authenticator "Transfer accounts" QR (otpauth-migration://offline?data=…)
//  • Aegis (unencrypted JSON export)      • 2FAS (unencrypted .2fas export)
//  • Bitwarden JSON export (login.totp)   • Totem's own encrypted .totem / vault file
import { parseOtpAuthUri, base32Encode, normalizeSecret, toOtpAuthUri } from "./totp.js";
import { b64 } from "./vault.js";

// ---------- Google Authenticator migration (protobuf) ----------

function readVarint(buf, pos) {
  let result = 0, shift = 0, b;
  do {
    b = buf[pos.i++];
    result += (b & 0x7f) * 2 ** shift;
    shift += 7;
  } while (b & 0x80);
  return result;
}

function readFields(buf) {
  const pos = { i: 0 };
  const fields = [];
  while (pos.i < buf.length) {
    const tag = readVarint(buf, pos);
    const field = Math.floor(tag / 8), wire = tag & 7;
    if (wire === 0) fields.push([field, readVarint(buf, pos)]);
    else if (wire === 2) {
      const len = readVarint(buf, pos);
      fields.push([field, buf.subarray(pos.i, pos.i + len)]);
      pos.i += len;
    } else if (wire === 1) pos.i += 8;
    else if (wire === 5) pos.i += 4;
    else throw new Error("Unexpected protobuf wire type");
  }
  return fields;
}

const GA_ALG = { 0: "SHA1", 1: "SHA1", 2: "SHA256", 3: "SHA512" };
const GA_DIGITS = { 0: 6, 1: 6, 2: 8 };

export function parseMigrationUri(uri) {
  const u = new URL(uri.trim());
  const data = u.searchParams.get("data");
  if (!data) throw new Error("Migration link has no data");
  const bytes = b64.dec(data.replace(/ /g, "+").replace(/-/g, "+").replace(/_/g, "/").replace(/\s/g, ""));
  const out = [];
  let hotpSkipped = 0;
  for (const [field, value] of readFields(bytes)) {
    if (field !== 1) continue;
    const p = { secret: null, name: "", issuer: "", algorithm: 1, digits: 1, type: 2 };
    const dec = new TextDecoder();
    for (const [f, v] of readFields(value)) {
      if (f === 1) p.secret = v;
      else if (f === 2) p.name = dec.decode(v);
      else if (f === 3) p.issuer = dec.decode(v);
      else if (f === 4) p.algorithm = v;
      else if (f === 5) p.digits = v;
      else if (f === 6) p.type = v;
    }
    if (p.type === 1) { hotpSkipped++; continue; }
    let label = p.name, issuer = p.issuer;
    const c = label.indexOf(":");
    if (c > -1) { if (!issuer) issuer = label.slice(0, c); label = label.slice(c + 1); }
    out.push({ issuer: issuer.trim(), label: label.trim(), secret: base32Encode(p.secret),
      algorithm: GA_ALG[p.algorithm] || "SHA1", digits: GA_DIGITS[p.digits] || 6, period: 30 });
  }
  return { accounts: out, skipped: hotpSkipped };
}

// ---------- format detection ----------

function fromText(text) {
  const accounts = [];
  let skipped = 0;
  const errors = [];
  const links = text.match(/otpauth(?:-migration)?:\/\/[^\s"'<>]+/g) || [];
  for (const link of links) {
    try {
      if (link.startsWith("otpauth-migration")) {
        const r = parseMigrationUri(link);
        accounts.push(...r.accounts);
        skipped += r.skipped;
      } else accounts.push(parseOtpAuthUri(link));
    } catch (e) {
      skipped++;
      errors.push(e.message);
    }
  }
  return { accounts, skipped, errors };
}

function fromAegis(json) {
  if (typeof json.db === "string") throw new Error("This Aegis export is encrypted. In Aegis, export again with encryption turned off, import, then delete that file.");
  const accounts = [];
  let skipped = 0;
  for (const e of json.db.entries || []) {
    if (e.type !== "totp") { skipped++; continue; }
    accounts.push({ issuer: e.issuer, label: e.name, secret: e.info.secret, algorithm: e.info.algo,
      digits: e.info.digits, period: e.info.period });
  }
  return { accounts, skipped };
}

function from2fas(json) {
  if (json.servicesEncrypted) throw new Error("This 2FAS backup is password-protected. Export it again without a password, import, then delete that file.");
  const accounts = [];
  let skipped = 0;
  for (const s of json.services || []) {
    const otp = s.otp || {};
    if (otp.tokenType && otp.tokenType !== "TOTP") { skipped++; continue; }
    accounts.push({ issuer: otp.issuer || s.name, label: otp.account || otp.label || "", secret: s.secret,
      algorithm: otp.algorithm || "SHA1", digits: otp.digits || 6, period: otp.period || 30 });
  }
  return { accounts, skipped };
}

function fromBitwarden(json) {
  if (json.encrypted) throw new Error("This Bitwarden export is encrypted. Export as unencrypted JSON, import, then delete that file.");
  const accounts = [];
  let skipped = 0;
  for (const item of json.items || []) {
    const t = item.login?.totp;
    if (!t) continue;
    try {
      if (t.startsWith("otpauth://")) accounts.push({ ...parseOtpAuthUri(t), issuer: parseOtpAuthUri(t).issuer || item.name });
      else if (t.startsWith("steam://")) skipped++;
      else accounts.push({ issuer: item.name, label: item.login?.username || "", secret: normalizeSecret(t) });
      const host = (item.login?.uris || [])[0]?.uri;
      if (host) try { accounts[accounts.length - 1].domains = [new URL(host).hostname.replace(/^www\./, "")]; } catch {}
    } catch { skipped++; }
  }
  return { accounts, skipped };
}

/**
 * Detect and parse any supported import.
 * Returns { kind, accounts, skipped } or, for a Totem vault, { kind:"totem", envelope } (needs password).
 */
export function parseImport(text) {
  const trimmed = String(text || "").trim();
  if (!trimmed) throw new Error("Nothing to import");
  if (trimmed.startsWith("{")) {
    let json;
    try { json = JSON.parse(trimmed); } catch { json = null; }
    if (json) {
      if (json.format === "totem-vault") return { kind: "totem", envelope: json };
      if (json.db && json.version !== undefined) return { kind: "Aegis", ...fromAegis(json) };
      if (Array.isArray(json.services) || json.servicesEncrypted) return { kind: "2FAS", ...from2fas(json) };
      if (Array.isArray(json.items) || json.encrypted) return { kind: "Bitwarden", ...fromBitwarden(json) };
    }
  }
  const r = fromText(trimmed);
  if (!r.accounts.length && !r.skipped) {
    // a bare Base32 secret
    try {
      const s = normalizeSecret(trimmed);
      if (/^[A-Z2-7]{16,}$/.test(s)) return { kind: "secret", accounts: [{ issuer: "", label: "New account", secret: s }], skipped: 0 };
    } catch {}
    throw new Error("No authenticator accounts found in that file or text");
  }
  return { kind: "otpauth", ...r };
}

// ---------- export ----------

export function exportOtpAuthText(accounts) {
  return [
    "# Totem plain export — THESE ARE UNENCRYPTED SECRETS. Delete this file after use.",
    ...accounts.map(toOtpAuthUri),
    "",
  ].join("\n");
}
