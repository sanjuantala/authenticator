// Run: node --test tests/   (Node 20+)
import test from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, mkdirSync, existsSync } from "node:fs";
import { hotp, totp, base32Encode, base32Decode, parseOtpAuthUri, toOtpAuthUri } from "../extension/lib/totp.js";
import * as V from "../extension/lib/vault.js";
import { parseImport, parseMigrationUri, exportOtpAuthText } from "../extension/lib/importers.js";

const enc = (s) => base32Encode(new TextEncoder().encode(s));

test("RFC 6238 vectors (SHA1/256/512, 8 digits)", async () => {
  const cases = [
    ["12345678901234567890", "SHA1", 59, "94287082"],
    ["12345678901234567890", "SHA1", 1111111109, "07081804"],
    ["12345678901234567890", "SHA1", 20000000000, "65353130"],
    ["12345678901234567890123456789012", "SHA256", 59, "46119246"],
    ["12345678901234567890123456789012", "SHA256", 1234567890, "91819424"],
    ["1234567890123456789012345678901234567890123456789012345678901234", "SHA512", 59, "90693936"],
    ["1234567890123456789012345678901234567890123456789012345678901234", "SHA512", 2000000000, "38618901"],
  ];
  for (const [seed, algorithm, t, want] of cases) {
    const r = await totp({ secret: enc(seed), algorithm, digits: 8, period: 30 }, t * 1000);
    assert.equal(r.code, want, `${algorithm} @${t}`);
  }
});

test("RFC 4226 HOTP vectors", async () => {
  const want = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"];
  for (let i = 0; i < 10; i++) assert.equal(await hotp(enc("12345678901234567890"), i), want[i]);
});

test("base32 round trip + lenient input", () => {
  const bytes = V.randomBytes(20);
  assert.deepEqual(base32Decode(base32Encode(bytes)), bytes);
  assert.deepEqual(base32Decode("jbsw y3dp-ehpk 3pxp=="), base32Decode("JBSWY3DPEHPK3PXP"));
  assert.throws(() => base32Decode("JBSW1"));
});

test("otpauth parse/build", () => {
  const a = parseOtpAuthUri("otpauth://totp/ACME%20Co:john@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co&algorithm=SHA256&digits=8&period=60");
  assert.deepEqual(a, { issuer: "ACME Co", label: "john@example.com", secret: "JBSWY3DPEHPK3PXP", algorithm: "SHA256", digits: 8, period: 60 });
  assert.deepEqual(parseOtpAuthUri(toOtpAuthUri(a)), a);
  const b = parseOtpAuthUri("otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP");
  assert.equal(b.issuer, "GitHub");
  assert.throws(() => parseOtpAuthUri("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1"));
});

test("vault seal/open, wrong password, merge", async () => {
  const s = await V.createSession("correct horse", 1000);
  let data = V.emptyData();
  ({ data } = V.addAccounts(data, [{ issuer: "GitHub", label: "me", secret: "JBSWY3DPEHPK3PXP" }]));
  const env = await V.sealEnvelope(data, s, "test");
  assert.equal(env.format, "totem-vault");
  const back = await V.openEnvelope(env, s);
  assert.equal(back.accounts[0].issuer, "GitHub");

  await assert.rejects(V.sessionForEnvelope("wrong", env), /Wrong password/);
  const s2 = await V.sessionForEnvelope("correct horse", env);
  assert.equal(s2.key, s.key);

  // merge: device A edits, device B deletes later -> delete wins; new account on B survives
  const id = data.accounts[0].id;
  const A = V.updateAccount(data, id, { label: "renamed" });
  await new Promise((r) => setTimeout(r, 5));
  let B = V.deleteAccount(data, id);
  ({ data: B } = V.addAccounts(B, [{ issuer: "Google", label: "x", secret: "GEZDGNBVGY3TQOJQ" }]));
  const M = V.mergeData(A, B);
  assert.equal(V.liveAccounts(M).length, 1);
  assert.equal(V.liveAccounts(M)[0].issuer, "Google");
  assert.ok(M.accounts.find((a) => a.id === id).deleted);
  assert.ok(V.sameData(V.mergeData(M, A), M));

  // duplicates are skipped on import
  const r = V.addAccounts(M, [{ issuer: "Google", label: "x", secret: "GEZD GNBV GY3T QOJQ" }]);
  assert.equal(r.added, 0);
  assert.equal(r.skipped, 1);
});

// Minimal protobuf writer to build a Google Authenticator migration payload.
function pb(fields) {
  const out = [];
  const varint = (n) => { while (n > 127) { out.push((n & 127) | 128); n = Math.floor(n / 128); } out.push(n); };
  for (const [f, v] of fields) {
    if (typeof v === "number") { varint(f * 8); varint(v); }
    else { const b = typeof v === "string" ? new TextEncoder().encode(v) : v; varint(f * 8 + 2); varint(b.length); out.push(...b); }
  }
  return new Uint8Array(out);
}

test("Google Authenticator migration QR", () => {
  const secret = new TextEncoder().encode("12345678901234567890");
  const p1 = pb([[1, secret], [2, "alice@example.com"], [3, "Example"], [4, 1], [5, 1], [6, 2]]);
  const p2 = pb([[1, secret], [2, "Other:bob"], [4, 2], [5, 2], [6, 2]]);
  const p3 = pb([[1, secret], [2, "hotp"], [6, 1], [7, 5]]);
  const payload = pb([[1, p1], [1, p2], [1, p3], [2, 1], [3, 1], [4, 0], [5, 123]]);
  const uri = "otpauth-migration://offline?data=" + encodeURIComponent(V.b64.enc(payload));
  const r = parseMigrationUri(uri);
  assert.equal(r.accounts.length, 2);
  assert.equal(r.skipped, 1);
  assert.deepEqual(r.accounts[0], { issuer: "Example", label: "alice@example.com", secret: enc("12345678901234567890"), algorithm: "SHA1", digits: 6, period: 30 });
  assert.equal(r.accounts[1].issuer, "Other");
  assert.equal(r.accounts[1].algorithm, "SHA256");
  assert.equal(r.accounts[1].digits, 8);
  // raw '+' in an unescaped link must survive
  const raw = "otpauth-migration://offline?data=" + V.b64.enc(payload);
  assert.equal(parseMigrationUri(raw).accounts.length, 2);
});

test("Aegis / 2FAS / Bitwarden / text imports", () => {
  const aegis = parseImport(JSON.stringify({ version: 1, db: { entries: [
    { type: "totp", name: "me", issuer: "Proton", info: { secret: "JBSWY3DPEHPK3PXP", algo: "SHA1", digits: 6, period: 30 } },
    { type: "hotp", name: "x", issuer: "y", info: { secret: "JBSWY3DPEHPK3PXP" } }] } }));
  assert.equal(aegis.kind, "Aegis"); assert.equal(aegis.accounts.length, 1); assert.equal(aegis.skipped, 1);
  assert.throws(() => parseImport(JSON.stringify({ version: 1, db: "ENCRYPTED" })), /encrypted/);

  const twofas = parseImport(JSON.stringify({ services: [{ name: "Shopify", secret: "JBSWY3DPEHPK3PXP", otp: { account: "dev@shop", tokenType: "TOTP", digits: 6, period: 30, algorithm: "SHA1" } }] }));
  assert.equal(twofas.kind, "2FAS"); assert.equal(twofas.accounts[0].issuer, "Shopify");

  const bw = parseImport(JSON.stringify({ encrypted: false, items: [{ name: "Figma", login: { username: "me", totp: "JBSW Y3DP EHPK 3PXP", uris: [{ uri: "https://www.figma.com/login" }] } }] }));
  assert.equal(bw.accounts[0].domains[0], "figma.com");

  const text = parseImport("some notes\notpauth://totp/A:b?secret=JBSWY3DPEHPK3PXP\notpauth://totp/C:d?secret=GEZDGNBVGY3TQOJQ&issuer=C");
  assert.equal(text.accounts.length, 2);
  const round = parseImport(exportOtpAuthText(text.accounts.map((a) => ({ ...a, algorithm: "SHA1", digits: 6, period: 30 }))));
  assert.equal(round.accounts.length, 2);
  assert.throws(() => parseImport("hello"), /No authenticator/);
});

test("write interop fixture for the Mac app tests (only when missing)", async () => {
  const target = new URL("../mac/Tests/TotemCoreTests/Fixtures/js-vault.json", import.meta.url);
  if (existsSync(target) && !process.env.REGEN_FIXTURE) return;
  const s = await V.sessionForEnvelope("interop-password",
    await V.sealEnvelope(V.emptyData(), await (async () => {
      const salt = new Uint8Array(16).fill(7);
      const key = await V.deriveKeyBytes("interop-password", salt, 1000);
      return { key: V.b64.enc(key), salt: V.b64.enc(salt), iterations: 1000 };
    })()));
  const data = { accounts: [V.normalizeAccount({ id: "fixture-1", issuer: "GitHub", label: "totem", secret: enc("12345678901234567890"),
    algorithm: "SHA1", digits: 8, period: 30, createdAt: 1, updatedAt: 2, domains: ["github.com"] })], updatedAt: 2 };
  const env = await V.sealEnvelope(data, s, "fixture");
  mkdirSync(new URL("../mac/Tests/TotemCoreTests/Fixtures/", import.meta.url), { recursive: true });
  writeFileSync(new URL("../mac/Tests/TotemCoreTests/Fixtures/js-vault.json", import.meta.url), JSON.stringify(env, null, 2));
});
