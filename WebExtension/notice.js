// The notice in the page's corner after a save, and its Change… panel.
// It sits in a closed shadow root, so the page's styles can't reach it and
// the page's scripts can't read it.
"use strict";

(function () {
  if (globalThis.BenchBookNotice) return;

  const browserAPI = globalThis.browser || globalThis.chrome;
  const { el } = BenchBookForm;

  const SYMBOLS = { saving: "…", saved: "✓", sent: "✓", duplicate: "=", failed: "!" };

  let host, root, card, hideTimer, form;
  let current = null;
  let hovering = false;

  function ensureCard() {
    if (host && host.isConnected) return;
    host = el("div");
    host.style.cssText = "all: initial; position: fixed; top: 0; right: 0; z-index: 2147483647;";
    root = host.attachShadow({ mode: "closed" });
    root.append(el("style", { text: style() }));
    card = el("div", { className: "card", role: "status" });
    card.setAttribute("aria-live", "polite");
    card.addEventListener("mouseenter", () => { hovering = true; clearTimeout(hideTimer); });
    card.addEventListener("mouseleave", () => { hovering = false; scheduleHide(); });
    card.addEventListener("keydown", (event) => {
      if (event.key === "Escape") hide();
    });
    root.append(card);
    document.documentElement.append(host);
  }

  function summary(item) {
    if (!item) return "";
    const hostname = (address) => {
      try { return new URL(address).hostname; } catch { return ""; }
    };
    switch (item.kind) {
      case "image": return `Image from ${hostname(item.pageURL || item.url)}`;
      case "text": return `“${item.text.trim().slice(0, 80)}${item.text.trim().length > 80 ? "…" : ""}”`;
      default: return item.title || hostname(item.url);
    }
  }

  function headline(notice) {
    switch (notice.status) {
      case "saving": return "Saving to BenchBook…";
      case "saved": return notice.projectName ? `Saved to ${notice.projectName}` : "Saved to BenchBook";
      case "duplicate": return notice.projectName ? `Already in ${notice.projectName}` : "Already in this project";
      case "sent": return "Sent to BenchBook";
      default: return "Couldn't save";
    }
  }

  function detail(notice) {
    switch (notice.status) {
      case "sent": return "BenchBook will show what happened when it has saved it.";
      case "failed": return notice.message || "Something went wrong. Try again.";
      default: return summary(notice.item);
    }
  }

  function render(notice) {
    ensureCard();
    current = notice;
    form = null;
    clearTimeout(hideTimer);

    const canChange = (notice.status === "saved" && (notice.referenceIDs || []).length > 0) || notice.status === "duplicate";
    const close = el("button", { className: "close", type: "button", text: "×", title: "Close" });
    close.setAttribute("aria-label", "Close");
    close.addEventListener("click", hide);

    const text = el("div", { className: "text" }, [
      el("div", { className: "headline", text: headline(notice) }),
      el("div", { className: "detail", text: detail(notice) }),
    ]);
    const row = el("div", { className: "row" }, [
      el("div", { className: `symbol ${notice.status}`, text: SYMBOLS[notice.status] || "!", ariaHidden: "true" }),
      text,
      canChange ? changeButton() : null,
      close,
    ]);
    card.replaceChildren(row);
    scheduleHide();
  }

  function changeButton() {
    const button = el("button", { className: "bb-button", type: "button", text: "Change…" });
    button.addEventListener("click", openPanel);
    return button;
  }

  async function openPanel() {
    clearTimeout(hideTimer);
    const notice = current;
    let state;
    try {
      state = await browserAPI.runtime.sendMessage({ type: "state" });
    } catch {
      state = null;
    }
    if (!state || state.ok !== true) {
      render({ status: "failed", message: (state && state.error) || "BenchBook couldn't be reached. Try again.", item: notice.item });
      return;
    }
    form = BenchBookForm.build(state);
    const cancel = el("button", { className: "bb-button", type: "button", text: "Cancel" });
    const save = el("button", { className: "bb-button bb-primary", type: "submit", text: "Save" });
    cancel.addEventListener("click", () => render(notice));

    const panel = el("form", { className: "panel" }, [
      el("div", { className: "headline", text: notice.status === "saved" ? "Change where it's saved" : "Save to another project" }),
      el("div", { className: "detail", text: summary(notice.item) }),
      form.element,
      el("div", { className: "buttons" }, [cancel, save]),
    ]);
    panel.addEventListener("submit", (event) => {
      event.preventDefault();
      submit(notice, form.values());
      save.disabled = true;
    });
    panel.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && event.metaKey) panel.requestSubmit();
    });
    card.replaceChildren(panel);
    form.focus();
  }

  // Background updates the notice with the outcome.
  function submit(notice, options) {
    const message = notice.status === "saved"
      ? { type: "amend", referenceIDs: notice.referenceIDs, options, item: notice.item }
      : { type: "save", item: notice.item, options };
    browserAPI.runtime.sendMessage(message).catch(() => {
      render({ status: "failed", message: "BenchBook couldn't be reached. Try again.", item: notice.item });
    });
  }

  function scheduleHide() {
    clearTimeout(hideTimer);
    if (!current || current.status === "saving" || form || hovering) return;
    hideTimer = setTimeout(hide, current.status === "failed" ? 12000 : 5000);
  }

  function hide() {
    clearTimeout(hideTimer);
    current = null;
    form = null;
    if (host) host.remove();
  }

  function style() {
    return `
      :host { all: initial; }
      .card {
        ${BenchBookForm.colors}
        position: fixed; top: 16px; right: 16px; width: 340px; box-sizing: border-box;
        padding: 12px; border-radius: 12px; border: 1px solid var(--bb-border);
        background: var(--bb-surface); color: var(--bb-text);
        box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2);
        font: 13px/1.35 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px);
      }
      @media (prefers-color-scheme: dark) { .card { ${BenchBookForm.darkColors} } }
      .row { display: flex; align-items: center; gap: 10px; }
      .text { flex: 1; min-width: 0; }
      .headline { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .detail { color: var(--bb-secondary); overflow-wrap: anywhere; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
      .symbol {
        flex: none; width: 26px; height: 26px; border-radius: 50%; display: grid; place-items: center;
        color: #fff; font-weight: 700; background: #8e8e93;
      }
      .symbol.saved, .symbol.sent { background: #30a14e; }
      .symbol.failed { background: #d70015; }
      .symbol.saving { background: var(--bb-accent); }
      .close {
        flex: none; font: 18px/1 inherit; width: 24px; height: 24px; border: 0; border-radius: 6px;
        background: transparent; color: var(--bb-secondary); cursor: default;
      }
      .close:hover { background: var(--bb-border); }
      .close:focus-visible { outline: 3px solid var(--bb-focus); }
      .panel { display: grid; gap: 10px; }
      .buttons { display: flex; justify-content: flex-end; gap: 8px; }
      ${BenchBookForm.css}
    `;
  }

  browserAPI.runtime.onMessage.addListener((message) => {
    if (message && message.type === "benchbook-notice") render(message.notice);
  });

  globalThis.BenchBookNotice = true;
})();
