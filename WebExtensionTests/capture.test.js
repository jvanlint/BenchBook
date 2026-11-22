// Tests for WebExtension/capture.js. Run with: node --test WebExtensionTests
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const capture = require("../WebExtension/capture.js");

test("names downloads from the server, then the address", () => {
  assert.equal(capture.filenameFor("https://x.com/a/gear.jpg", null, "image/jpeg"), "gear.jpg");
  assert.equal(capture.filenameFor("https://x.com/a/gear", null, "image/png"), "gear.png");
  assert.equal(capture.filenameFor("https://x.com/dl?id=4", 'attachment; filename="Instructions.pdf"', "application/pdf"), "Instructions.pdf");
  assert.equal(capture.filenameFor("https://x.com/dl", "attachment; filename*=UTF-8''F-16%20Gear.pdf", "application/pdf"), "F-16 Gear.pdf");
  assert.equal(capture.filenameFor("data:image/png;base64,AAAA", null, "image/png"), "Image.png");
  assert.equal(capture.filenameFor("https://x.com/", null, ""), "Download");
  assert.equal(capture.filenameFor("https://x.com/a/..%2F..%2Fsecret.png", null, "image/png"), "secret.png");
});

test("recognises PDF addresses", () => {
  assert.equal(capture.hasPDFPath("https://x.com/manual.PDF?x=1"), true);
  assert.equal(capture.hasPDFPath("https://x.com/manual.html"), false);
  assert.equal(capture.hasPDFPath("not a url"), false);
});

test("base64 matches Node's", () => {
  const bytes = new Uint8Array(100000).map((_, i) => i % 256);
  assert.equal(capture.base64(bytes), Buffer.from(bytes).toString("base64"));
});

function fakeBenchBook() {
  const sent = [];
  const send = async (message) => {
    sent.push(message);
    switch (message.action) {
      case "begin": return { ok: true, upload: "U1" };
      case "chunk": return { ok: true };
      case "save": return { ok: true, status: "saved", projectName: "F-16CJ", referenceIDs: ["R1"] };
      default: return { ok: true };
    }
  };
  return { sent, send };
}

test("uploads an image in chunks, then saves it", async () => {
  const size = 5 * 1024 * 1024;
  globalThis.fetch = async () => new Response(new Uint8Array(size), { headers: { "content-type": "image/jpeg" } });
  const benchBook = fakeBenchBook();
  const result = await capture.create(benchBook.send).save(
    { kind: "image", url: "https://cdn.x.com/gear.jpg", pageURL: "https://x.com/f16" },
    { tags: ["Gear"] }
  );
  assert.equal(result.status, "saved");
  const actions = benchBook.sent.map((m) => m.action);
  assert.deepEqual(actions, ["begin", "chunk", "chunk", "chunk", "save"]);
  const save = benchBook.sent.at(-1);
  assert.equal(save.upload, "U1");
  assert.deepEqual(save.item, { kind: "file", filename: "gear.jpg", url: "https://cdn.x.com/gear.jpg", pageURL: "https://x.com/f16" });
  assert.deepEqual(save.tags, ["Gear"]);
});

test("a page that serves a PDF is saved as the file", async () => {
  globalThis.fetch = async (url, options = {}) =>
    new Response(options.method === "HEAD" ? null : new Uint8Array([37, 80, 68, 70]), { headers: { "content-type": "application/pdf" } });
  const benchBook = fakeBenchBook();
  await capture.create(benchBook.send).save({ kind: "page", url: "https://x.com/view?doc=7", title: "Manual" });
  const save = benchBook.sent.at(-1);
  assert.equal(save.item.kind, "file");
  assert.equal(save.item.filename, "view.pdf");
  assert.equal(save.item.pageURL, "https://x.com/view?doc=7");
});

test("explains a refused download and doesn't contact BenchBook", async () => {
  globalThis.fetch = async () => new Response("no", { status: 403 });
  const benchBook = fakeBenchBook();
  const result = await capture.create(benchBook.send).save({ kind: "image", url: "https://cdn.x.com/a.jpg", pageURL: "https://x.com" });
  assert.equal(result.status, "failed");
  assert.match(result.message, /error 403/);
  assert.deepEqual(benchBook.sent, []);
});

test("passes on BenchBook's error, and copes when it can't be reached", async () => {
  globalThis.fetch = async () => new Response(null, { headers: { "content-type": "text/html" } });
  const refusing = capture.create(async () => ({ ok: false, error: "There are no projects yet." }));
  assert.deepEqual(await refusing.save({ kind: "page", url: "https://x.com/" }), { status: "failed", message: "There are no projects yet." });

  const missing = capture.create(async () => { throw new Error("no host"); });
  const result = await missing.save({ kind: "page", url: "https://x.com/" });
  assert.equal(result.status, "failed");
  assert.match(result.message, /couldn't reach BenchBook/);
});
