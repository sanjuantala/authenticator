// Totem — TOTP/HOTP (RFC 4226 / RFC 6238) using WebCrypto.
// Works in the browser extension and in Node 20+ (globalThis.crypto.subtle).

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function normalizeSecret(s) {
  return String(s || "").toUpperCase().replace(/[\s-]/g, "").replace(/=+$/, "");
}

export function base32Decode(input) {
  const s = normalizeSecret(input);
  if (!s.length) throw new Error("Secret is empty");
  let bits = 0, value = 0;
  const out = [];
  for (const ch of s) {
    const idx = B32.indexOf(ch);
    if (idx === -1) throw new Error(`Invalid Base32 character "${ch}"`);
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

export function base32Encode(bytes) {
  let bits = 0, value = 0, out = "";
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

const HASH = { SHA1: "SHA-1", SHA256: "SHA-256", SHA512: "SHA-512" };

export function normalizeAlgorithm(a) {
  const k = String(a || "SHA1").toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (!HASH[k]) throw new Error(`Unsupported algorithm ${a}`);
  return k;
}

const keyCache = new Map();
async function hmacKey(secret, algorithm) {
  const id = algorithm + ":" + secret;
  if (keyCache.has(id)) return keyCache.get(id);
  const key = await crypto.subtle.importKey(
    "raw", base32Decode(secret), { name: "HMAC", hash: HASH[algorithm] }, false, ["sign"]
  );
  if (keyCache.size > 500) keyCache.clear();
  keyCache.set(id, key);
  return key;
}

export async function hotp(secret, counter, { algorithm = "SHA1", digits = 6 } = {}) {
  const alg = normalizeAlgorithm(algorithm);
  const msg = new ArrayBuffer(8);
  const view = new DataView(msg);
  view.setUint32(0, Math.floor(counter / 2 ** 32));
  view.setUint32(4, counter >>> 0);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(secret, alg), msg));
  const off = sig[sig.length - 1] & 0x0f;
  const bin = ((sig[off] & 0x7f) << 24) | (sig[off + 1] << 16) | (sig[off + 2] << 8) | sig[off + 3];
  return String(bin % 10 ** digits).padStart(digits, "0");
}

/** Returns { code, next, remaining, period } for an account at time `now` (ms). */
export async function totp(account, now = Date.now()) {
  const period = account.period || 30;
  const digits = account.digits || 6;
  const step = Math.floor(now / 1000 / period);
  const opts = { algorithm: account.algorithm || "SHA1", digits };
  const [code, next] = await Promise.all([hotp(account.secret, step, opts), hotp(account.secret, step + 1, opts)]);
  const remaining = period - (Math.floor(now / 1000) % period);
  return { code, next, remaining, period };
}

/** Parse otpauth://totp/Issuer:label?secret=...&issuer=...  */
export function parseOtpAuthUri(uri) {
  const u = new URL(String(uri).trim());
  if (u.protocol !== "otpauth:") throw new Error("Not an otpauth:// link");
  const type = u.hostname || u.host || u.pathname.split("/")[2];
  if (String(type).toLowerCase() !== "totp") throw new Error("Only time-based (TOTP) codes are supported");
  let path = decodeURIComponent(u.pathname.replace(/^\/+/, ""));
  if (path.toLowerCase().startsWith("totp/")) path = path.slice(5); // some URL parsers keep the host in the path
  let issuer = u.searchParams.get("issuer") || "";
  let label = path;
  const colon = path.indexOf(":");
  if (colon > -1) {
    if (!issuer) issuer = path.slice(0, colon);
    label = path.slice(colon + 1);
  }
  const secret = normalizeSecret(u.searchParams.get("secret"));
  base32Decode(secret); // validate
  return {
    issuer: issuer.trim(),
    label: label.trim(),
    secret,
    algorithm: normalizeAlgorithm(u.searchParams.get("algorithm") || "SHA1"),
    digits: parseInt(u.searchParams.get("digits") || "6", 10),
    period: parseInt(u.searchParams.get("period") || "30", 10),
  };
}

export function toOtpAuthUri(a) {
  const name = encodeURIComponent(a.issuer ? `${a.issuer}:${a.label}` : a.label);
  const p = new URLSearchParams({ secret: a.secret });
  if (a.issuer) p.set("issuer", a.issuer);
  p.set("algorithm", a.algorithm || "SHA1");
  p.set("digits", String(a.digits || 6));
  p.set("period", String(a.period || 30));
  return `otpauth://totp/${name}?${p.toString()}`;
}
