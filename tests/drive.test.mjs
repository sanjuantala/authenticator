// Google Drive module against an in-memory fake of the Drive v3 REST API.
import test from "node:test";
import assert from "node:assert/strict";

// --- fake chrome.storage.session + Drive API ---
const session = {};
globalThis.chrome = {
  storage: { session: {
    async get(k) { return { [k]: session[k] }; },
    async set(o) { Object.assign(session, o); },
    async remove(k) { for (const x of [].concat(k)) delete session[x]; },
  } },
};
session.driveToken = { value: "tok", expires: Date.now() + 3600_000 };

const files = new Map();
let nextId = 1, clock = 0;
function match(q, f) {
  return q.split(" and ").every((c) => {
    let m;
    if ((m = c.match(/^name='(.*)'$/))) return f.name === m[1];
    if (c === "trashed=false") return true;
    if ((m = c.match(/^'(.*)' in parents$/))) return f.parents.includes(m[1]);
    if (c === "mimeType='application/vnd.google-apps.folder'") return f.mimeType === c.split("'")[1];
    throw new Error("unhandled q " + c);
  });
}
globalThis.fetch = async (url, opts = {}) => {
  assert.equal(opts.headers.Authorization, "Bearer tok");
  const u = new URL(url);
  const ok = (body) => ({ ok: true, status: 200, json: async () => body, text: async () => (typeof body === "string" ? body : JSON.stringify(body)) });
  const idm = u.pathname.match(/\/files\/([^/]+)$/);
  if (opts.method === "DELETE") { files.delete(idm[1]); return { ok: true, status: 204 }; }
  if (u.pathname.endsWith("/files") && (opts.method || "GET") === "GET") {
    let list = [...files.values()].filter((f) => match(u.searchParams.get("q"), f));
    if (u.searchParams.get("orderBy") === "createdTime desc") list.sort((a, b) => b.created - a.created);
    return ok({ files: list.map((f) => ({ id: f.id, name: f.name, createdTime: new Date(f.created).toISOString() })) });
  }
  if (u.pathname === "/drive/v3/files" && opts.method === "POST") {
    const meta = JSON.parse(opts.body); const id = "f" + nextId++;
    files.set(id, { id, ...meta, parents: meta.parents || [], created: ++clock, content: "" });
    return ok({ id });
  }
  if (u.pathname === "/upload/drive/v3/files" && opts.method === "POST") {
    const boundary = opts.headers["Content-Type"].split("boundary=")[1];
    const parts = opts.body.split(`--${boundary}`).filter((p) => p.includes("\r\n\r\n"));
    const meta = JSON.parse(parts[0].split("\r\n\r\n")[1]);
    const content = parts[1].split("\r\n\r\n")[1].replace(/\r\n$/, "");
    const id = "f" + nextId++;
    files.set(id, { id, ...meta, created: ++clock, content });
    return ok({ id });
  }
  if (idm && opts.method === "PATCH") { files.get(idm[1]).content = opts.body; return ok({}); }
  if (idm && u.searchParams.get("alt") === "media") return ok(files.get(idm[1]).content);
  throw new Error(`unhandled ${opts.method} ${url}`);
};

const Drive = await import("../extension/lib/drive.js");

test("first pull is empty, push creates folder + live file + daily backup", async () => {
  assert.equal(await Drive.pullVault("tok"), null);
  await Drive.pushVault("tok", { format: "totem-vault", n: 1 });
  const names = [...files.values()].map((f) => f.name).sort();
  assert.ok(names.includes("Totem Authenticator") && names.includes("backups") && names.includes("totem-vault.json"));
  assert.equal(names.filter((n) => n.startsWith("totem-backup-")).length, 1);
  assert.deepEqual(await Drive.pullVault("tok"), { format: "totem-vault", n: 1 });
});

test("second push updates in place (no duplicate files) and same-day backup is overwritten", async () => {
  await Drive.pushVault("tok", { format: "totem-vault", n: 2 });
  const live = [...files.values()].filter((f) => f.name === "totem-vault.json");
  assert.equal(live.length, 1);
  assert.equal([...files.values()].filter((f) => f.name.startsWith("totem-backup-")).length, 1);
  assert.equal((await Drive.pullVault("tok")).n, 2);
  assert.equal([...files.values()].filter((f) => f.name === "Totem Authenticator").length, 1);
});

test("manual backups are kept separately and pruned to the newest 30", async () => {
  for (let i = 0; i < 35; i++) {
    files.set("old" + i, { id: "old" + i, name: `totem-backup-x${i}.json`, parents: [[...files.values()].find((f) => f.name === "backups").id], created: ++clock, content: "{}" });
  }
  await Drive.pushVault("tok", { format: "totem-vault", n: 3 }, { forceBackup: true });
  const backups = await Drive.listBackups("tok");
  assert.equal(backups.length, 30);
  const restored = await Drive.downloadFile("tok", backups[0].id);
  assert.equal(restored.n, 3);
});
