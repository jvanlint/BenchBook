// The toolbar button's panel: saves the current page, or the PDF it shows,
// to a chosen project with optional tags and a note.
"use strict";

const browserAPI = globalThis.browser || globalThis.chrome;
const { el } = BenchBookForm;
const app = document.getElementById("app");
document.head.append(el("style", { text: BenchBookForm.css }));

function show(...children) {
  app.replaceChildren(...children);
}

function message(text) {
  show(el("h1", { text: "Save to BenchBook" }), el("p", { className: "message", text }));
}

function isWebPage(address) {
  try {
    return ["http:", "https:"].includes(new URL(address).protocol);
  } catch {
    return false;
  }
}

async function start() {
  const [tab] = await browserAPI.tabs.query({ active: true, currentWindow: true });
  if (!tab || !isWebPage(tab.url)) {
    message("Open a web page to save it to BenchBook.");
    return;
  }

  let state;
  try {
    state = await browserAPI.runtime.sendMessage({ type: "state" });
  } catch {
    state = null;
  }
  if (!state || state.ok !== true) {
    message((state && state.error) || "Safari couldn't reach BenchBook. Check that BenchBook is in your Applications folder, then try again.");
    return;
  }
  if (!state.projects.length) {
    message("There are no projects yet. Open BenchBook, make a project, then try again.");
    return;
  }

  const kind = await browserAPI.runtime.sendMessage({ type: "kind", url: tab.url }).catch(() => ({ pdf: false }));
  const host = new URL(tab.url).hostname;
  const form = BenchBookForm.build(state);
  const status = el("div", { className: "status", role: "status" });
  const save = el("button", { className: "bb-button bb-primary", type: "submit", text: "Save" });

  const page = el("form", {}, [
    el("div", { className: "preview" }, [
      el("div", { className: "title", text: tab.title || host, title: tab.url }),
      el("div", { className: "where", text: kind && kind.pdf ? `PDF · ${host}` : `Web page · ${host}` }),
    ]),
    form.element,
    el("div", { className: "footer" }, [status, save]),
  ]);
  page.style.cssText = "display: grid; gap: 12px;";

  page.addEventListener("submit", async (event) => {
    event.preventDefault();
    save.disabled = true;
    status.className = "status";
    status.textContent = "Saving…";
    const result = await browserAPI.runtime.sendMessage({
      type: "save",
      tabId: tab.id,
      item: { kind: "page", url: tab.url, title: tab.title },
      options: form.values(),
    }).catch(() => ({ status: "failed", message: "Something went wrong. Try again." }));

    switch (result.status) {
      case "saved":
        status.textContent = `Saved to ${result.projectName || "BenchBook"}.`;
        setTimeout(() => window.close(), 900);
        break;
      case "sent":
        status.textContent = "Sent to BenchBook.";
        setTimeout(() => window.close(), 1200);
        break;
      case "duplicate":
        status.textContent = `Already in ${result.projectName || "this project"}.`;
        save.disabled = false;
        break;
      default:
        status.className = "status failed";
        status.textContent = result.message || "Couldn't save. Try again.";
        save.disabled = false;
    }
  });
  page.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && event.metaKey) page.requestSubmit();
  });

  show(el("h1", { text: "Save to BenchBook" }), page);
  form.focus();
}

start().catch(() => message("Something went wrong. Close this and try again."));
