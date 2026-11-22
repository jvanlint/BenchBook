// Saving to BenchBook: downloads files, sends them to the native extension in
// chunks, and turns replies into results. Kept free of Safari specifics, so
// the Chromium extension can reuse it with its own way of reaching BenchBook.
"use strict";

(function () {
  const MAX_FILE_BYTES = 200 * 1024 * 1024;
  // Each chunk is sent as base64, which is a third larger.
  const CHUNK_BYTES = 2 * 1024 * 1024;

  const EXTENSIONS = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
    "image/heic": "heic",
    "image/heif": "heic",
    "image/gif": "gif",
    "image/svg+xml": "svg",
    "application/pdf": "pdf",
  };

  class CaptureError extends Error {}

  function isWebURL(text) {
    try {
      const url = new URL(text);
      return url.protocol === "http:" || url.protocol === "https:";
    } catch {
      return false;
    }
  }

  function hasPDFPath(text) {
    try {
      return /\.pdf$/i.test(new URL(text).pathname);
    } catch {
      return false;
    }
  }

  // The name to save a download under: the server's suggested name, then the
  // address's last part, with an extension that matches the file's type.
  function filenameFor(address, disposition, type) {
    let name = "";
    const encoded = /filename\*\s*=\s*[^']*''([^;]+)/i.exec(disposition || "");
    const plain = /filename\s*=\s*"?([^";]+)"?/i.exec(disposition || "");
    try {
      if (encoded) name = decodeURIComponent(encoded[1].trim());
      else if (plain) name = plain[1].trim();
    } catch {
      name = "";
    }
    if (!name) {
      try {
        const url = new URL(address);
        if (url.protocol !== "data:" && url.protocol !== "blob:") {
          name = decodeURIComponent(url.pathname.split("/").pop() || "");
        }
      } catch {
        name = "";
      }
    }
    name = name.replace(/[/\\:\u0000-\u001f]/g, "").replace(/^\.+/, "").trim();
    const mime = (type || "").split(";")[0].trim().toLowerCase();
    const extension = EXTENSIONS[mime];
    if (!name) name = mime.startsWith("image/") ? "Image" : "Download";
    if (extension && !/\.[a-z0-9]{2,5}$/i.test(name)) name += "." + extension;
    return name.slice(0, 200);
  }

  function base64(bytes) {
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(binary);
  }

  // `send` delivers one message to BenchBook and resolves with its reply.
  function create(send) {
    async function native(message) {
      let reply;
      try {
        reply = await send(message);
      } catch {
        throw new CaptureError("Safari couldn't reach BenchBook. Check that BenchBook is in your Applications folder, then try again.");
      }
      if (!reply || reply.ok !== true) {
        throw new CaptureError((reply && reply.error) || "BenchBook didn't answer. Try again.");
      }
      return reply;
    }

    async function looksLikePDF(address) {
      if (!isWebURL(address)) return false;
      if (hasPDFPath(address)) return true;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 3000);
      try {
        const response = await fetch(address, { method: "HEAD", credentials: "include", signal: controller.signal });
        return (response.headers.get("content-type") || "").toLowerCase().startsWith("application/pdf");
      } catch {
        return false;
      } finally {
        clearTimeout(timer);
      }
    }

    // Downloads with the browser's own cookies, so pages you're signed in to
    // work, then sends the file to BenchBook in chunks.
    async function upload(address) {
      let response;
      try {
        response = await fetch(address, { credentials: "include" });
      } catch {
        throw new CaptureError("The file couldn't be downloaded. If this keeps happening, check that BenchBook is allowed on this website in Safari › Settings › Extensions.");
      }
      if (!response.ok) {
        throw new CaptureError(`The website didn't allow the file to be downloaded (error ${response.status}).`);
      }
      const declared = Number(response.headers.get("content-length") || 0);
      if (declared > MAX_FILE_BYTES) throw new CaptureError("The file is too large to save. Files can be up to 200 MB.");
      const blob = await response.blob();
      if (blob.size === 0) throw new CaptureError("The file was empty.");
      if (blob.size > MAX_FILE_BYTES) throw new CaptureError("The file is too large to save. Files can be up to 200 MB.");

      const filename = filenameFor(address, response.headers.get("content-disposition"), blob.type || response.headers.get("content-type"));
      const { upload: id } = await native({ action: "begin" });
      try {
        for (let offset = 0; offset < blob.size; offset += CHUNK_BYTES) {
          const bytes = new Uint8Array(await blob.slice(offset, offset + CHUNK_BYTES).arrayBuffer());
          await native({ action: "chunk", upload: id, data: base64(bytes) });
        }
      } catch (error) {
        send({ action: "cancel", upload: id }).catch(() => {});
        throw error;
      }
      return { id, filename };
    }

    // Saves `item` and resolves with a result; it never rejects.
    //   item: { kind: "page", url, title }
    //       | { kind: "image", url, pageURL }
    //       | { kind: "text", text, pageURL, title }
    //   options: { projectID, tags, note }, each optional
    // The result's status is saved, duplicate, failed, or sent (BenchBook
    // hasn't answered yet and will report the outcome itself).
    async function save(item, options = {}) {
      try {
        const message = { action: "save", tags: options.tags || [] };
        if (options.projectID) message.projectID = options.projectID;
        if (options.note) message.note = options.note;

        let kind = item.kind;
        if (kind === "page" && (await looksLikePDF(item.url))) kind = "pdf";

        if (kind === "image" || kind === "pdf") {
          const file = await upload(item.url);
          message.upload = file.id;
          message.item = {
            kind: "file",
            filename: file.filename,
            url: isWebURL(item.url) ? item.url : undefined,
            pageURL: kind === "pdf" ? item.url : item.pageURL,
          };
        } else if (kind === "page") {
          if (!isWebURL(item.url)) throw new CaptureError("Only web pages can be saved.");
          message.item = { kind: "page", url: item.url, title: item.title };
        } else if (kind === "text") {
          message.item = { kind: "text", text: item.text, pageURL: item.pageURL, title: item.title };
        } else {
          throw new CaptureError("BenchBook can't save this.");
        }
        return await native(message);
      } catch (error) {
        return { status: "failed", message: error instanceof CaptureError ? error.message : "Something went wrong. Try again." };
      }
    }

    // Change… after a save: moves what was saved and adds tags and a note.
    async function amend(referenceIDs, options) {
      try {
        return await native({
          action: "amend",
          referenceIDs,
          projectID: options.projectID,
          tags: options.tags || [],
          note: options.note || undefined,
        });
      } catch (error) {
        return { status: "failed", message: error.message };
      }
    }

    async function state() {
      return native({ action: "state" });
    }

    return { save, amend, state, looksLikePDF };
  }

  const api = { create, filenameFor, hasPDFPath, isWebURL, base64, MAX_FILE_BYTES };
  if (typeof module === "object" && module.exports) module.exports = api;
  else globalThis.BenchBookCapture = api;
})();
