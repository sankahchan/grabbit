// Grabbit Web Grabber — background service worker.
// Tracks media detected by content scripts, shows a badge count, offers a
// context-menu entry, and forwards chosen URLs to the Grabbit macOS app via
// native messaging (host id: com.sankahchan.grabbit).

'use strict';

const detectedTabs = new Map(); // tabId -> Array<{url, title, pageUrl, site, ...}>

function itemKey(item) {
  return item.url;
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (!sender.tab) return;
  const tabId = sender.tab.id;

  if (msg?.type === 'grabbit-media') {
    const prev = detectedTabs.get(tabId) || [];
    const merged = new Map(prev.map((i) => [itemKey(i), i]));
    for (const item of msg.items) merged.set(itemKey(item), item);
    const items = [...merged.values()];
    detectedTabs.set(tabId, items);
    updateBadge(tabId, items.length);
  } else if (msg?.type === 'grabbit-blob-chunk' || msg?.type === 'grabbit-blob-done' || msg?.type === 'grabbit-blob-error') {
    // Forward blob-stream messages straight to the native host.
    forwardBlobMessage(msg);
  }
});

function updateBadge(tabId, count) {
  chrome.action.setBadgeText({ tabId, text: count > 0 ? String(count) : '' }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ color: '#E94F37' }).catch(() => {});
}

chrome.tabs.onRemoved.addListener((tabId) => {
  detectedTabs.delete(tabId);
});

// --- Context menu ---------------------------------------------------------

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: 'grabbit-download',
    title: 'Download with Grabbit',
    contexts: ['video', 'audio', 'link'],
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== 'grabbit-download') return;
  const url = info.srcUrl || info.linkUrl;
  if (!url) return;
  sendToApp({ url, source: 'context-menu', title: tab?.title || '' });
});

// --- Action click ----------------------------------------------------------

chrome.action.onClicked.addListener(async (tab) => {
  // No popup: send the current tab URL for analysis ("grab whatever's here").
  if (tab?.url) {
    sendToApp({ url: tab.url, source: 'action-click', title: tab.title || '' });
  }
});

// --- Native messaging ------------------------------------------------------

let nativePort = null;
let blobPort = null;

function ensurePort() {
  if (nativePort) return nativePort;
  nativePort = chrome.runtime.connectNative('com.sankahchan.grabbit');
  nativePort.onDisconnect.addListener(() => {
    nativePort = null;
  });
  return nativePort;
}

function sendToApp(payload) {
  try {
    const port = ensurePort();
    port.postMessage(payload);
    // Probe the connection; if the host is missing, disconnect fires async.
    setTimeout(() => {
      if (!nativePort) notifyHostMissing();
    }, 750);
  } catch {
    notifyHostMissing();
  }
}

// A second long-lived port for blob streaming (keeps chunks off the main port).
function forwardBlobMessage(msg) {
  try {
    if (!blobPort) {
      blobPort = chrome.runtime.connectNative('com.sankahchan.grabbit');
      blobPort.onDisconnect.addListener(() => {
        blobPort = null;
      });
    }
    blobPort.postMessage(msg);
  } catch {
    // Native host unavailable; content script will get a blob-error from timeout.
  }
}

chrome.runtime.onConnect.addListener(() => {});

function notifyHostMissing() {
  chrome.notifications.create('grabbit-host-missing', {
    type: 'basic',
    iconUrl: 'icons/icon128.png',
    title: 'Grabbit is not running',
    message: 'Install and open Grabbit at least once, then try again.',
  }).catch(() => {});
}
