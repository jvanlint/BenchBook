// Right-click menus, the notice in the page, and messages from the toolbar
// panel and the notice's Change… panel.
"use strict";

const browserAPI = globalThis.browser || globalThis.chrome;
const capture = BenchBookCapture.create((message) =>
  browserAPI.runtime.sendNativeMessage("com.jasonvanlint.BenchBook", message)
);

const MENUS = [
  { id: "benchbook-save-page", title: "Save Page to BenchBook", contexts: ["page"] },
  { id: "benchbook-save-image", title: "Save Image to BenchBook", contexts: ["image"] },
  { id: "benchbook-save-selection", title: "Save Selection to BenchBook", contexts: ["selection"] },
];

async function createMenus() {
  await browserAPI.contextMenus.removeAll();
  for (const menu of MENUS) browserAPI.contextMenus.create(menu);
}
browserAPI.runtime.onInstalled.addListener(createMenus);
browserAPI.runtime.onStartup.addListener(createMenus);

browserAPI.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!tab || tab.id === undefined) return;
  let item;
  switch (info.menuItemId) {
    case "benchbook-save-image":
      item = { kind: "image", url: info.srcUrl, pageURL: info.pageUrl || tab.url };
      break;
    case "benchbook-save-selection":
      item = { kind: "text", text: (await selectedText(tab.id)) || info.selectionText, pageURL: info.pageUrl || tab.url, title: tab.title };
      break;
    case "benchbook-save-page":
      item = { kind: "page", url: info.pageUrl || tab.url, title: tab.title };
      break;
    default:
      return;
  }
  await saveAndShow(tab.id, item, {});
});

// The selection with its line breaks; the menu's own copy loses them.
async function selectedText(tabId) {
  try {
    const [result] = await browserAPI.scripting.executeScript({
      target: { tabId },
      func: () => String(getSelection() || ""),
    });
    return result && typeof result.result === "string" && result.result.trim() ? result.result : null;
  } catch {
    return null;
  }
}

async function saveAndShow(tabId, item, options) {
  await showNotice(tabId, { status: "saving", item });
  const result = await capture.save(item, options);
  await showNotice(tabId, { ...result, item });
  return result;
}

// Shows the notice in the page. Where Safari doesn't allow that (its own
// pages, PDFs, or websites BenchBook isn't allowed on), the toolbar button's
// badge shows the outcome instead.
async function showNotice(tabId, notice) {
  try {
    await browserAPI.scripting.executeScript({ target: { tabId }, files: ["form.js", "notice.js"] });
    await browserAPI.tabs.sendMessage(tabId, { type: "benchbook-notice", notice });
  } catch {
    showBadge(tabId, notice);
  }
}

const BADGES = { saving: "…", saved: "✓", sent: "✓", duplicate: "=", failed: "!" };
const BADGE_TITLES = {
  saving: "Saving to BenchBook…",
  saved: "Saved to BenchBook",
  sent: "Sent to BenchBook",
  duplicate: "Already in this project",
  failed: "Couldn't save to BenchBook",
};
let badgeTimer;

function showBadge(tabId, notice) {
  const title = notice.status === "failed" && notice.message ? `${BADGE_TITLES.failed}: ${notice.message}` : BADGE_TITLES[notice.status];
  browserAPI.action.setBadgeText({ tabId, text: BADGES[notice.status] || "" }).catch(() => {});
  browserAPI.action.setTitle({ tabId, title: title || "Save to BenchBook" }).catch(() => {});
  clearTimeout(badgeTimer);
  if (notice.status !== "saving") {
    badgeTimer = setTimeout(() => {
      browserAPI.action.setBadgeText({ tabId, text: "" }).catch(() => {});
      browserAPI.action.setTitle({ tabId, title: "Save to BenchBook" }).catch(() => {});
    }, notice.status === "failed" ? 15000 : 5000);
  }
}

// Messages from the toolbar panel (popup.js) and the notice (notice.js).
browserAPI.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handle(message, sender).then(sendResponse, (error) => sendResponse({ ok: false, error: error.message }));
  return true;
});

async function handle(message, sender) {
  const tabId = (sender.tab && sender.tab.id) ?? message.tabId;
  switch (message && message.type) {
    case "state":
      return capture.state();
    case "kind":
      return { pdf: await capture.looksLikePDF(message.url) };
    case "save":
      return saveAndShow(tabId, message.item, message.options || {});
    case "amend": {
      await showNotice(tabId, { status: "saving", item: message.item });
      const result = await capture.amend(message.referenceIDs, message.options || {});
      await showNotice(tabId, { ...result, item: message.item });
      return result;
    }
    default:
      return { ok: false, error: "Unknown request." };
  }
}
