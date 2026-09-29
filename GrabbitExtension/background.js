// Grabbit Web Grabber — background service worker.
// Tracks media detected by content scripts, shows a badge count, offers a
// context-menu entry, and forwards chosen URLs to the Grabbit macOS app.
//
// Transport: Chrome Native Messaging (host id: com.sankahchan.grabbit). The
// installed host is a tiny Python helper that hands work to the running
// Grabbit app through the grabbit:// URL scheme, so no second GUI instance
// is ever launched. When the host isn't installed, a URL-scheme tab fallback
// still delivers plain downloads (headers truncated to stay under OS URL
// length limits) and the user gets told to run install-host.sh.

'use strict';

const NATIVE_HOST = 'com.sankahchan.grabbit';
const detectedTabs = new Map(); // tabId -> Array<{url, title, pageUrl, site, ...}>

function itemKey(item) {
  return item.url;
}

// --- Notifications ----------------------------------------------------------

function notify(title, message, id) {
  chrome.notifications
    .create(id || 'grabbit-' + Date.now() + '-' + Math.random().toString(36).slice(2, 6), {
      type: 'basic',
      iconUrl: 'icons/icon128.png',
      title: title || 'Grabbit',
      message: message || '',
    })
    .catch(() => {});
}

/// Low-volume diagnostics to the native helper's telegram-debug.log.
function debugLog(event, details) {
  try {
    postNative({
      type: 'debug',
      line: JSON.stringify({
        at: new Date().toISOString(),
        event,
        details: details || {},
      }),
    });
  } catch {
    // Diagnostics must never break the flow.
  }
}

// --- Native messaging port --------------------------------------------------

let nativePort = null;
let portGeneration = 0;
const pendingAcks = new Map(); // id -> { resolve, timer }
let ackSeq = 0;

function connectNative() {
  if (nativePort) return nativePort;
  const generation = ++portGeneration;
  let port;
  try {
    port = chrome.runtime.connectNative(NATIVE_HOST);
  } catch {
    return null;
  }
  port.onMessage.addListener((msg) => {
    if (!msg || typeof msg !== 'object') return;
    if (msg.type === 'ack' && msg.id != null) {
      const pending = pendingAcks.get(msg.id);
      if (pending) {
        clearTimeout(pending.timer);
        pendingAcks.delete(msg.id);
        // The helper answers ok:false for messages it could not apply
        // (e.g. a chunk for a capture that no longer exists).
        pending.resolve(msg.ok !== false);
      }
    } else if (msg.type === 'error') {
      notify('Grabbit', msg.error || 'Native host error');
    }
  });
  port.onDisconnect.addListener(() => {
    if (generation !== portGeneration) return;
    nativePort = null;
    for (const [id, pending] of pendingAcks) {
      clearTimeout(pending.timer);
      pendingAcks.delete(id);
      pending.resolve(false);
    }
  });
  nativePort = port;
  return port;
}

/// Posts a message to the native helper. With `expectAck`, resolves true only
/// after the helper confirms it processed the message; false on timeout or a
/// disconnected port (used for delivery-critical and flow-control messages).
function postNative(message, { expectAck = false, timeoutMs = 3000 } = {}) {
  const port = connectNative();
  if (!port) return Promise.resolve(false);
  const id = 'm' + ++ackSeq + '-' + Date.now();
  message.id = id;
  if (!expectAck) {
    try {
      port.postMessage(message);
      return Promise.resolve(true);
    } catch {
      return Promise.resolve(false);
    }
  }
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pendingAcks.delete(id);
      resolve(false);
    }, timeoutMs);
    pendingAcks.set(id, {
      resolve: (ok) => {
        clearTimeout(timer);
        resolve(ok);
      },
      timer,
    });
    try {
      port.postMessage(message);
    } catch {
      clearTimeout(timer);
      pendingAcks.delete(id);
      resolve(false);
    }
  });
}

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

// --- Redirect-chain capture (QDM idea) --------------------------------------
//
// When a download URL is the tail of a redirect chain, the earliest URL is
// the natural Referer. redirectSource maps a redirect TARGET url -> the
// first url in its chain (60s TTL). captureContext falls back to it when no
// Referer header was observed.

const redirectSource = new Map(); // targetUrl -> firstUrl
const redirectChainStart = new Map(); // requestId -> firstUrl

function ttlDelete(map, key, ms = 60000) {
  setTimeout(() => map.delete(key), ms);
}

try {
  chrome.webRequest.onBeforeRedirect.addListener(
    (details) => {
      let first = redirectChainStart.get(details.requestId);
      if (!first) {
        first = details.url;
        redirectChainStart.set(details.requestId, first);
        ttlDelete(redirectChainStart, details.requestId);
      }
      redirectSource.set(details.redirectUrl, first);
      ttlDelete(redirectSource, details.redirectUrl);
    },
    { urls: ['<all_urls>'] }
  );
} catch {
  // webRequest unavailable — direct header capture still works.
}

async function captureContext(url) {
  const headers = { ...(headerCache.get(url) || {}) };
  if (!headers['Referer']) {
    const first = redirectSource.get(url);
    if (first) headers['Referer'] = first;
  }
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

// --- App handoff ------------------------------------------------------------

/// Sends a grab to the app. Native messaging is primary (it carries full
/// headers through a payload file); the grabbit:// scheme is the fallback.
async function sendToApp(payload) {
  // Prefer the pre-redirect URL: it carries the real filename
  // (e.g. github.com/.../Grabbit-v1.0.2.dmg) while the redirect target
  // is often a UUID (release-assets...). The app follows redirects itself.
  const original = redirectSource.get(payload.url);
  if (original) {
    payload.url = original;
    if (payload.filename) payload.filename = filenameFromUrl(original);
  }
  const headers = await captureContext(payload.url);
  const delivered = await postNative(
    {
      type: 'grab',
      url: payload.url,
      filename: payload.filename || '',
      title: payload.title || '',
      pageUrl: payload.pageUrl || '',
      source: payload.source || 'extension',
      headers,
    },
    { expectAck: true, timeoutMs: 3000 }
  );
  if (delivered) return true;

  const usedFallback = await openViaScheme({ ...payload, headers });
  notify(
    'Grabbit',
    usedFallback
      ? 'Native host unavailable — used the URL-scheme fallback. If nothing appears in Grabbit, run install-host.sh for this extension ID.'
      : 'Could not reach Grabbit. Open the Grabbit app and run install-host.sh for this extension ID.'
  );
  return usedFallback;
}

/// Builds a grabbit://download URL for the fallback transport. Headers are
/// included when they fit; long cookie headers are dropped first because an
/// oversized URL fails silently in LaunchServices.
function schemeUrl(payload) {
  const params = new URLSearchParams();
  params.set('url', payload.url);
  if (payload.filename) params.set('filename', payload.filename);
  const headers = payload.headers || {};
  const mapping = {
    Referer: 'referer',
    'User-Agent': 'userAgent',
    Authorization: 'authorization',
    Origin: 'origin',
    Cookie: 'cookie',
  };
  for (const [name, param] of Object.entries(mapping)) {
    if (headers[name]) params.set(param, headers[name]);
  }
  let url = 'grabbit://download?' + params.toString();
  if (url.length > 7000 && params.has('cookie')) {
    params.delete('cookie');
    url = 'grabbit://download?' + params.toString();
  }
  return url;
}

async function openViaScheme(payload) {
  try {
    await chrome.tabs.create({ url: schemeUrl(payload), active: true });
    return true;
  } catch {
    return false;
  }
}

// --- Page-context fetch (service-worker-served URLs) ------------------------
//
// Content-script fetches bypass the page's service worker, so Telegram's
// /a/stream and /a/progressive routes answer with the app HTML (302). The
// scripting API injects this function into the page's MAIN world instead —
// CSP-immune and always the current code (no resource-cache staleness) — and
// it streams the response back to the content script with per-chunk acks.

async function runPageFetch(tabId, frameId, url, requestId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId, frameIds: [frameId] },
      world: 'MAIN',
      func: (fetchUrl, fetchId) => {
        (async () => {
          const acks = new Map();
          const onMessage = (event) => {
            const m = event.data;
            if (!m || m.source !== 'grabbit-content' || m.type !== 'grabbit-page-fetch-ack') return;
            const resolve = acks.get(m.requestId + ':' + m.index);
            if (resolve) {
              acks.delete(m.requestId + ':' + m.index);
              resolve();
            }
          };
          window.addEventListener('message', onMessage);
          const post = (obj, transfer) => {
            try {
              if (transfer) window.postMessage(obj, '*', transfer);
              else window.postMessage(obj, '*');
            } catch {
              // ignore
            }
          };
          // Telegram's service worker caps each ranged response (512 KB) and
          // rejects unprefixed fetches ("Failed to fetch"), so request the
          // file in successive ranges until Content-Range says we are done.
          const PIECE = 196608; // 192 KB per message (base64 ≈ 256 KB)
          let started = false;
          let position = 0;
          let overallTotal = 0;
          try {
            for (let round = 0; round < 200000; round++) {
              const response = await fetch(fetchUrl, {
                credentials: 'include',
                // Ask for an explicit 8 MB range: open-ended ranges make the
                // service worker hand back small (512 KB) chunks, and every
                // extra round trip costs seconds.
                headers: { Range: 'bytes=' + position + '-' + (position + 8388607) },
              });
              const mime = response.headers.get('content-type') || '';
              const contentRange = response.headers.get('content-range') || '';
              const cr = /bytes\s+(\d+)-(\d+)\/(\d+|\*)/i.exec(contentRange);
              if (!started) {
                started = true;
                overallTotal =
                  cr && cr[3] !== '*'
                    ? parseInt(cr[3], 10)
                    : Number(response.headers.get('content-length') || 0) || 0;
                post({
                  source: 'grabbit-page-hook',
                  type: 'grabbit-page-fetch-start',
                  requestId: fetchId,
                  ok: response.ok,
                  status: response.status,
                  mime,
                  total: overallTotal,
                  finalUrl: response.url,
                });
              }
              if (!response.body) throw new Error('no response body');
              const reader = response.body.getReader();
              let pieceIndex = position;
              let roundBytes = 0;
              for (;;) {
                const { done, value } = await reader.read();
                if (done) break;
                if (!value || value.length === 0) continue;
                for (let offset = 0; offset < value.length; offset += PIECE) {
                  const piece = value.subarray(offset, Math.min(offset + PIECE, value.length));
                  const copy = piece.slice();
                  const index = pieceIndex++;
                  const byteLength = copy.byteLength;
                  await new Promise((resolve) => {
                    acks.set(fetchId + ':' + index, resolve);
                    post(
                      {
                        source: 'grabbit-page-hook',
                        type: 'grabbit-page-fetch-chunk',
                        requestId: fetchId,
                        index,
                        byteLength,
                        data: copy.buffer,
                      },
                      [copy.buffer]
                    );
                    setTimeout(() => {
                      if (acks.delete(fetchId + ':' + index)) resolve();
                    }, 15000);
                  });
                  position += byteLength;
                  roundBytes += byteLength;
                }
              }
              // A plain 200 response carried the whole body — nothing more to do.
              if (!cr) break;
              const rangeEnd = parseInt(cr[2], 10);
              const rangeTotal = cr[3] === '*' ? null : parseInt(cr[3], 10);
              if (roundBytes === 0) break;
              if (rangeTotal !== null && position >= rangeTotal) break;
              if (position > rangeEnd) continue;
              if (position > 3000000000) break;
            }
            post({
              source: 'grabbit-page-hook',
              type: 'grabbit-page-fetch-end',
              requestId: fetchId,
            });
          } catch (error) {
            post({
              source: 'grabbit-page-hook',
              type: 'grabbit-page-fetch-error',
              requestId: fetchId,
              error: String(error),
            });
          } finally {
            window.removeEventListener('message', onMessage);
          }
        })();
      },
      args: [url, requestId],
    });
    debugLog('page-fetch-injected', { url: url.slice(0, 200) });
    return true;
  } catch (error) {
    debugLog('page-fetch-inject-error', { error: String(error) });
    return false;
  }
}

// --- Page-context download trigger (service-worker-served URLs) -------------
//
// Telegram Web only lets the page itself fetch these routes. Instead of
// re-implementing its pipeline, we drive Telegram's own downloader from the
// MAIN world:
//   1. WebA media viewer: click its Download button with a full synthetic
//      mouse-event sequence (plain .click() is ignored by the Vue handlers) —
//      the same technique popular Telegram downloader extensions use.
//   2. Otherwise: dispatch Telegram's internal `media_download_event` with
//      the viewer's video URL + message id.
// The resulting browser download (blob or https) is picked up by
// pendingImports and imported into Grabbit when complete.

async function runPageMediaDownload(tabId, frameId, url, fileType, title) {
  try {
    const [injection] = await chrome.scripting.executeScript({
      target: { tabId, frameIds: [frameId] },
      world: 'MAIN',
      // Runs async: it may open the full media viewer first (message-list
      // video previews have no viewer action bar until clicked), then click
      // the viewer's Download button or dispatch the internal event.
      func: async (videoUrl, kind, name) => {
        const report = {
          dispatched: false,
          button: false,
          buttons: [],
          mid: '',
          openedViewer: false,
        };
        const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        const simulateClick = (el) => {
          for (const type of ['mouseover', 'mousedown', 'mouseup', 'click']) {
            el.dispatchEvent(
              new MouseEvent(type, { bubbles: true, cancelable: true, view: window, button: 0 })
            );
          }
        };
        const findMedia = () =>
          [...document.querySelectorAll('video, img')].find((m) => {
            const src = m.getAttribute('src') || m.src || '';
            return src === videoUrl;
          }) || null;
        const listActionButtons = () => {
          const actions = document.getElementsByClassName('MediaViewerActions')[0];
          if (!actions) return [];
          return [...actions.querySelectorAll('.Button, button, [role="button"], a')].map(
            (el) => ({
              el,
              aria: el.getAttribute('aria-label') || '',
              title: el.getAttribute('title') || '',
              className: String(el.className || '').slice(0, 80),
              text: (el.textContent || '').trim().slice(0, 20),
            })
          );
        };
        // The viewer's action-bar order varies between Telegram versions
        // (Close used to be last, now it is not), so identify the Download
        // action by its label instead of its position.
        const findDownloadButton = (buttons) => {
          const exact = buttons.find(
            (b) => /^download$/i.test(b.aria.trim()) || /^download$/i.test(b.title.trim())
          );
          if (exact) return exact;
          return (
            buttons.find((b) => {
              const hay = (b.aria + ' ' + b.title + ' ' + b.className + ' ' + b.text).toLowerCase();
              if (/close|forward|more|reply|share|delete/.test(hay)) return false;
              return hay.includes('download') || hay.includes('save');
            }) || null
          );
        };

        const media = findMedia();
        if (media) {
          let node = media.parentElement;
          while (node && !report.mid) {
            report.mid =
              (node.getAttribute &&
                (node.getAttribute('data-mid') || node.getAttribute('data-message-id'))) ||
              '';
            node = node.parentElement;
          }
        }

        let buttons = listActionButtons();
        if (buttons.length === 0 && media) {
          // Open the full viewer first — message previews hide the actions.
          try {
            simulateClick(media);
          } catch {
            // ignore
          }
          report.openedViewer = true;
          await wait(1200);
          buttons = listActionButtons();
        }
        report.buttons = buttons.map(({ el, ...meta }) => meta);

        // 1) Telegram's internal download event (WebA needs the message id).
        try {
          const detail = report.mid
            ? {
                video_src: {
                  video_url: videoUrl,
                  video_id: report.mid,
                  page: 'content',
                  download_id: 'tgALL',
                },
                type: 'single',
              }
            : { video_src: videoUrl, type: 'single' };
          if (kind) detail.fileType = kind;
          if (name) detail.title = name;
          document.dispatchEvent(new CustomEvent('media_download_event', { detail }));
          report.dispatched = true;
        } catch {
          // Nothing else to try.
        }

        // 2) Click the actual Download button, identified by its label.
        const downloadButton = findDownloadButton(buttons);
        if (downloadButton) {
          try {
            simulateClick(downloadButton.el);
            report.button = true;
            report.buttonInfo = {
              aria: downloadButton.aria,
              title: downloadButton.title,
              className: downloadButton.className,
              text: downloadButton.text,
            };
          } catch {
            // ignore
          }
        }
        return report;
      },
      args: [url, fileType || '', title || ''],
    });
    return injection?.result || null;
  } catch (error) {
    debugLog('media-download-injection-error', { error: String(error) });
    return null;
  }
}

/// Delegates a blob/stream URL to the content script's in-page capture.
function startBlobStream(tabId, url, filename) {
  const requestId = 'blob-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
  return chrome.tabs
    .sendMessage(
      tabId,
      { type: 'grabbit-fetch-blob', url, requestId, filename: filename || '' },
      { frameId: 0 }
    )
    .then((res) => ({ ok: res?.ok !== false, version: res?.version, requestId }))
    .catch(() => ({ ok: false }));
}

// --- Extension message router ----------------------------------------------

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg?.type === 'grabbit-get-media' && typeof msg.tabId === 'number') {
    sendResponse({ items: detectedTabs.get(msg.tabId) || [] });
    return true;
  }

  if (msg?.type === 'grabbit-send-url' && typeof msg.url === 'string') {
    if (!/^https?:\/\//i.test(msg.url)) {
      sendResponse({ ok: false });
      return true;
    }
    sendToApp({
      url: msg.url,
      source: 'popup-manual',
      title: '',
      pageUrl: '',
      filename: filenameFromUrl(msg.url),
    });
    sendResponse({ ok: true });
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

  if (
    msg?.type === 'grabbit-start-blob' &&
    typeof msg.url === 'string' &&
    typeof msg.tabId === 'number'
  ) {
    debugLog('blob-request', { url: msg.url.slice(0, 300), kind: msg.kind || '' });
    const isTelegramMedia = /web\.telegram\.org\/a\/(stream|progressive)\//i.test(msg.url);
    if (isTelegramMedia) {
      const startedAt = Date.now();
      runPageMediaDownload(
        msg.tabId,
        0,
        msg.url,
        msg.kind === 'audio' ? 'audio' : '',
        msg.filename || ''
      ).then(async (report) => {
        debugLog('media-download-trigger', { report, url: msg.url.slice(0, 300) });
        if (!report) {
          notify('Grabbit', 'Telegram could not be driven directly — capturing in-page instead…');
          const res = await startBlobStream(msg.tabId, msg.url, msg.filename);
          debugLog('stream-fallback', { ok: res.ok, reason: 'injection-failed' });
          sendResponse(res);
          return;
        }
        // Telegram prepares the file (MTProto fetch with progress) before the
        // browser download appears — poll for it instead of assuming 3s.
        notify(
          'Grabbit',
          'Telegram is preparing the download — it will be imported into Grabbit automatically.'
        );
        const deadline = Date.now() + 45000;
        let started = false;
        while (Date.now() < deadline) {
          await new Promise((resolve) => setTimeout(resolve, 2000));
          try {
            const recent = await chrome.downloads.search({ limit: 10, orderBy: ['-startTime'] });
            started = recent.some((d) => {
              const candidate = d.finalUrl || d.url || '';
              if (!isTelegramHost(candidate) && !isTelegramBlobURL(candidate)) return false;
              const time = d.startTime ? Date.parse(d.startTime) : 0;
              return !time || time >= startedAt - 2000;
            });
          } catch {
            // downloads API unavailable — assume it worked.
            started = true;
          }
          if (started) break;
          const pendingThisRun = [...pendingImports.values()].some(
            (entry) => (entry.addedAt || 0) >= startedAt - 2000
          );
          if (pendingThisRun) {
            started = true;
            break;
          }
        }
        debugLog('media-download-started', { started, report });
        if (started) {
          notify(
            'Grabbit',
            'Telegram is downloading — Grabbit will import the file when it finishes.'
          );
          sendResponse({ ok: true, version: chrome.runtime.getManifest().version });
        } else {
          notify('Grabbit', 'Telegram did not start a download — capturing in-page instead…');
          const res = await startBlobStream(msg.tabId, msg.url, msg.filename);
          debugLog('stream-fallback', { ok: res.ok, reason: 'telegram-did-not-download' });
          sendResponse(res);
        }
      });
      return true;
    }
    startBlobStream(msg.tabId, msg.url, msg.filename).then((res) => {
      debugLog('stream-request', { ok: res.ok, version: res.version });
      sendResponse(res);
    });
    return true;
  }

  if (msg?.type === 'grabbit-host-status') {
    // Popup diagnostic: is the native helper reachable right now?
    postNative({ type: 'ping' }, { expectAck: true, timeoutMs: 1500 }).then((ok) =>
      sendResponse({ ok })
    );
    return true;
  }

  if (!sender.tab) return;

  const tabId = sender.tab.id;

  if (msg?.type === 'grabbit-page-fetch-exec' && typeof msg.url === 'string' && msg.requestId) {
    // Content scripts can't run main-world code; do it from here so the
    // service worker owns the injection.
    runPageFetch(tabId, sender.frameId ?? 0, msg.url, msg.requestId).then((ok) =>
      sendResponse({ ok })
    );
    return true;
  }

  if (msg?.type === 'grabbit-media') {
    const prev = detectedTabs.get(tabId) || [];
    const merged = new Map(prev.map((i) => [itemKey(i), i]));
    for (const item of msg.items) merged.set(itemKey(item), item);
    const items = [...merged.values()];
    detectedTabs.set(tabId, items);
    updateBadge(tabId, items.length);
    return;
  }

  // In-page stream lifecycle: stream-init / -chunk / -finalize / -cancel.
  // The type prefix is stripped for the helper's protocol.
  if (
    msg?.type === 'grabbit-stream-init' ||
    msg?.type === 'grabbit-stream-chunk' ||
    msg?.type === 'grabbit-stream-finalize' ||
    msg?.type === 'grabbit-stream-cancel'
  ) {
    const isFinalize = msg.type === 'grabbit-stream-finalize';
    postNative(
      { ...msg, type: msg.type.replace(/^grabbit-/, ''), tabId, pageUrl: msg.pageUrl || sender.tab.url || '' },
      { expectAck: true, timeoutMs: isFinalize ? 60000 : 20000 }
    ).then((ok) => {
      sendResponse({ ok });
      if (isFinalize && ok) {
        notify('Grabbit', 'Saving capture to Grabbit…');
      }
    });
    return true;
  }

  if (msg?.type === 'grabbit-stream-progress' && msg.captureId) {
    // Live progress notification (stable id ⇒ the same bubble updates).
    const received = Number(msg.bytes || 0);
    const total = Number(msg.total || 0);
    const mb = (n) => (n / 1048576).toFixed(1);
    chrome.notifications
      .create('grabbit-capture-' + msg.captureId, {
        type: 'basic',
        iconUrl: 'icons/icon128.png',
        title: 'Grabbit is capturing Telegram media',
        message:
          total > 0
            ? `${mb(received)} MB of ${mb(total)} MB`
            : `${mb(received)} MB captured`,
        silent: true,
      })
      .catch(() => {});
    return;
  }

  if (msg?.type === 'grabbit-blob-result') {
    if (msg.requestId) {
      chrome.notifications.clear('grabbit-capture-' + msg.requestId).catch(() => {});
    }
    if (msg.ok) {
      notify('Grabbit', 'Saved to Grabbit: ' + (msg.filename || 'download'));
    } else {
      notify('Grabbit', 'Capture failed: ' + (msg.error || 'the blob link expired — reopen the media and retry'));
    }
    return;
  }

  if (msg?.type === 'grabbit-debug') {
    postNative({
      type: 'debug',
      line: JSON.stringify({
        at: new Date().toISOString(),
        tab: tabId,
        event: msg.event,
        details: msg.details || {},
      }),
    });
    return;
  }

  if (msg?.type === 'grabbit-stream-ping') {
    // Keepalive from the content script while a capture is open: touching the
    // worker resets its idle timer so the native port survives long pauses.
    sendResponse({ ok: true });
    return true;
  }

  if (msg?.type === 'grabbit-notify') {
    notify(msg.title, msg.message);
    return;
  }

  return;
});

function updateBadge(tabId, count) {
  chrome.action.setBadgeText({ tabId, text: count > 0 ? String(count) : '' }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ color: '#E94F37' }).catch(() => {});
}

chrome.tabs.onRemoved.addListener((tabId) => {
  detectedTabs.delete(tabId);
});

// --- Context menu -----------------------------------------------------------

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
  if (url.startsWith('blob:') && tab?.id != null) {
    // blob: URLs are page-scoped; recover them in-page instead of handing a
    // dead URL to the app.
    const requestId = 'blob-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
    chrome.tabs
      .sendMessage(
        tab.id,
        { type: 'grabbit-fetch-blob', url, requestId, filename: '' },
        { frameId: 0 }
      )
      .catch(() => notify('Grabbit', 'Blob link expired before capture — reopen the media and try again.'));
    return;
  }
  sendToApp({
    url,
    source: 'context-menu',
    title: tab?.title || '',
    pageUrl: tab?.url || '',
    filename: filenameFromUrl(url),
  });
});

// --- Action popup -----------------------------------------------------------
// The toolbar button opens popup.html (manifest action.default_popup), which
// lists detected media for the current tab. No onClicked handler.

// --- IDM-style auto-intercept (QDM idea) ------------------------------------
//
// When the browser itself starts a download, cancel it and reroute it into
// Grabbit with full request context. Blob-backed downloads (Telegram Web
// documents/videos) are recovered in-page instead, because the native host
// can't resolve blob: URLs. Toggleable from the popup; on by default.

async function autoInterceptEnabled() {
  try {
    const stored = await chrome.storage.sync.get('autoIntercept');
    return stored.autoIntercept !== false;
  } catch {
    return true;
  }
}

function basename(path) {
  return (path || '').split(/[\\/]/).pop() || undefined;
}

try {
  chrome.downloads.onCreated.addListener(async (item) => {
    try {
      const url = item.finalUrl || item.url;
      if (!url) return;

      // Telegram service-worker downloads (anchor clicks or the page's own
      // download button) are imported on completion regardless of the
      // auto-grab toggle — that toggle only reroutes normal browser
      // downloads.
      if (url.startsWith('http') && isTelegramHost(url)) {
        pendingImports.set(item.id, {
          filename: basename(item.filename) || '',
          pageUrl: item.referrer || '',
          addedAt: Date.now(),
        });
        persistPendingImports();
        debugLog('download-created', {
          url: url.slice(0, 300),
          filename: basename(item.filename) || '',
        });
        return;
      }
      if (url.startsWith('blob:') && isTelegramBlobURL(url)) {
        // Telegram's own downloader produced this blob; let the browser
        // finish it and import the file (large videos must not be re-fetched).
        pendingImports.set(item.id, {
          filename: basename(item.filename) || '',
          pageUrl: item.referrer || '',
          addedAt: Date.now(),
        });
        persistPendingImports();
        debugLog('blob-download-created', {
          url: url.slice(0, 120),
          filename: basename(item.filename) || '',
        });
        return;
      }

      if (!(await autoInterceptEnabled())) return;

      if (url.startsWith('blob:')) {
        await chrome.downloads.cancel(item.id).catch(() => {});
        await chrome.downloads.erase({ id: item.id }).catch(() => {});
        const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
        if (tab?.id == null) {
          notify('Grabbit', 'Blob download detected but no tab is available to capture it.');
          return;
        }
        const requestId = 'blob-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
        try {
          await chrome.tabs.sendMessage(
            tab.id,
            {
              type: 'grabbit-fetch-blob',
              url,
              requestId,
              filename: basename(item.filename) || '',
            },
            { frameId: 0 }
          );
        } catch {
          notify('Grabbit', 'Blob link expired before capture — reopen the media and try again.');
        }
        return;
      }

      if (!url.startsWith('http://') && !url.startsWith('https://')) return;

      await chrome.downloads.cancel(item.id).catch(() => {});
      await chrome.downloads.erase({ id: item.id }).catch(() => {});
      sendToApp({
        url,
        source: 'auto-intercept',
        title: '',
        pageUrl: item.referrer || '',
        filename: basename(item.filename) || filenameFromUrl(url),
      });
    } catch {
      // Never break the browser's own download UI.
    }
  });
} catch {
  // downloads permission unavailable — context menu + popup still work.
}

// --- Telegram service-worker downloads: import on completion ----------------
//
// web.telegram.org (/a/progressive/…) downloads are produced by the page's
// service worker; only the browser can fetch them. Those downloads are left
// to finish and then handed to Grabbit as finished files.

const pendingImports = new Map(); // downloadId -> {filename, pageUrl}

function isTelegramHost(url) {
  try {
    const host = new URL(url).hostname;
    return host === 'web.telegram.org' || host.endsWith('.web.telegram.org');
  } catch {
    return false;
  }
}

/// blob:https://web.telegram.org/uuid → true (blob URL host is empty, so the
/// inner origin has to be parsed).
function isTelegramBlobURL(url) {
  const match = /^blob:(https?:\/\/[^/]+)/i.exec(url);
  if (!match) return false;
  try {
    const host = new URL(match[1]).hostname;
    return host === 'web.telegram.org' || host.endsWith('.web.telegram.org');
  } catch {
    return false;
  }
}

// The service worker can be recycled while a slow download is running —
// mirror the pending map into session storage so onChanged still imports it.
async function persistPendingImports() {
  try {
    await chrome.storage.session.set({ pendingImports: Object.fromEntries(pendingImports) });
  } catch {
    // Session storage unavailable — the in-memory map still covers quick downloads.
  }
}

async function restorePendingImports() {
  try {
    const stored = await chrome.storage.session.get('pendingImports');
    for (const [id, info] of Object.entries(stored.pendingImports || {})) {
      pendingImports.set(Number(id), info);
    }
  } catch {
    // Ignore — nothing to restore.
  }
}

restorePendingImports().catch(() => {});

try {
  chrome.downloads.onChanged.addListener(async (delta) => {
    let pending = pendingImports.get(delta.id);
    if (!pending) {
      await restorePendingImports();
      pending = pendingImports.get(delta.id);
    }
    if (!pending) return;
    const state = delta.state?.current;
    if (state === 'interrupted') {
      pendingImports.delete(delta.id);
      persistPendingImports();
      return;
    }
    if (state !== 'complete') return;
    pendingImports.delete(delta.id);
    persistPendingImports();
    try {
      const [item] = await chrome.downloads.search({ id: delta.id });
      if (!item?.filename) {
        notify('Grabbit', 'Browser download finished but its file path is unknown.');
        return;
      }
      const delivered = await postNative(
        {
          type: 'import',
          path: item.filename,
          filename: basename(item.filename) || '',
          pageUrl: item.referrer || pending.pageUrl || '',
          source: 'telegram-progressive',
        },
        { expectAck: true, timeoutMs: 20000 }
      );
      if (delivered) {
        notify('Grabbit', 'Importing into Grabbit: ' + (basename(item.filename) || 'file'));
        await chrome.downloads.erase({ id: delta.id }).catch(() => {});
      } else {
        notify('Grabbit', 'Could not reach Grabbit to import the finished download.');
      }
    } catch {
      // Import is best-effort; the file stays in the browser's Downloads.
    }
  });
} catch {
  // downloads permission unavailable — import-on-complete disabled.
}
