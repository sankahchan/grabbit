// Grabbit Web Grabber — background service worker.
// Tracks media detected by content scripts, shows a badge count, offers a
// context-menu entry, and forwards chosen URLs to the Grabbit macOS app via
// native messaging (host id: com.sankahchan.grabbit).

'use strict';

const detectedTabs = new Map(); // tabId -> Array<{url, title, pageUrl, site, ...}>

function itemKey(item) {
  return item.url;
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg?.type === 'grabbit-get-media' && typeof msg.tabId === 'number') {
    sendResponse({ items: detectedTabs.get(msg.tabId) || [] });
    return true;
  }
  if (msg?.type === 'grabbit-send-media' && typeof msg.url === 'string') {
    const items = detectedTabs.get(msg.tabId) || [];
    const item = items.find((i) => i.url === msg.url) || { url: msg.url };
    sendToApp({
      url: item.url,
      source: 'popup',
      title: item.title || '',
      pageUrl: item.pageUrl || '',
      filename: filenameFromUrl(item.url),
    });
    sendResponse({ ok: true });
    return true;
  }
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
  sendToApp({
    url,
    source: 'context-menu',
    title: tab?.title || '',
    pageUrl: tab?.url || '',
    filename: filenameFromUrl(url),
  });
});

// --- Action popup ----------------------------------------------------------
// The toolbar button now opens popup.html (manifest action.default_popup),
// which lists detected media for the current tab. No onClicked handler.

// --- Request-context capture (XDM idea) ------------------------------------
//
// A bare URL is often useless: the download only works with the browser's
// Cookie / Referer / User-Agent / Authorization. We capture those per URL:
// headers via webRequest.onSendHeaders, cookies via the cookies API, and
// forward everything to the app so its connections behave like the browser.

const headerCache = new Map(); // url -> {Referer, User-Agent, Authorization, Origin}
const HEADER_CACHE_MAX = 500;

function cacheHeaders(url, headers) {
  const picked = {};
  for (const h of headers || []) {
    const name = (h.name || '').toLowerCase();
    if (['referer', 'user-agent', 'authorization', 'origin'].includes(name)) {
      picked[h.name] = h.value;
    }
  }
  if (Object.keys(picked).length === 0) return;
  headerCache.set(url, picked);
  if (headerCache.size > HEADER_CACHE_MAX) {
    // FIFO eviction: Map iterates in insertion order.
    headerCache.delete(headerCache.keys().next().value);
  }
}

try {
  chrome.webRequest.onSendHeaders.addListener(
    (details) => cacheHeaders(details.url, details.requestHeaders),
    { urls: ['<all_urls>'] },
    ['requestHeaders', 'extraHeaders']
  );
} catch {
  // webRequest unavailable — cookie capture below still works.
}

async function captureContext(url) {
  const headers = { ...(headerCache.get(url) || {}) };
  try {
    // Cookie is not reliably visible via webRequest; read it directly.
    const cookies = await chrome.cookies.getAll({ url });
    if (cookies.length > 0) {
      headers['Cookie'] = cookies.map((c) => `${c.name}=${c.value}`).join('; ');
    }
  } catch {
    // cookies permission denied or unparsable URL — headers still useful.
  }
  return headers;
}

function filenameFromUrl(url) {
  try {
    const path = new URL(url).pathname.split('/').pop() || '';
    const decoded = decodeURIComponent(path);
    return decoded || undefined;
  } catch {
    return undefined;
  }
}

/// Builds a grabbit://download URL — the fallback transport when the native
/// messaging host isn't installed. The app is registered for the scheme, so
/// this still lands the download (with headers) in Grabbit.
function schemeUrl(payload) {
  const params = new URLSearchParams();
  params.set('url', payload.url);
  if (payload.filename) params.set('filename', payload.filename);
  const headers = payload.headers || {};
  if (headers['Cookie']) params.set('cookie', headers['Cookie']);
  if (headers['Referer']) params.set('referer', headers['Referer']);
  if (headers['User-Agent']) params.set('userAgent', headers['User-Agent']);
  if (headers['Authorization']) params.set('authorization', headers['Authorization']);
  if (headers['Origin']) params.set('origin', headers['Origin']);
  return 'grabbit://download?' + params.toString();
}

async function openViaScheme(payload) {
  try {
    const tab = await chrome.tabs.create({ url: schemeUrl(payload), active: false });
    // The scheme hands off to the OS; the leftover tab is just a launcher.
    setTimeout(() => chrome.tabs.remove(tab.id).catch(() => {}), 1500);
    return true;
  } catch {
    return false;
  }
}

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
  // Capture request context first (async), then deliver.
  captureContext(payload.url).then((headers) => {
    payload.headers = headers;
    try {
      const port = ensurePort();
      port.postMessage(payload);
      // Probe the connection; if the host is missing, disconnect fires async.
      setTimeout(async () => {
        if (!nativePort) {
          // Fallback: the grabbit:// scheme needs no host installation.
          const ok = await openViaScheme(payload);
          if (!ok) notifyHostMissing();
        }
      }, 750);
    } catch {
      openViaScheme(payload).then((ok) => {
        if (!ok) notifyHostMissing();
      });
    }
  });
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
