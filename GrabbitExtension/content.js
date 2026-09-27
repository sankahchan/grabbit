// Grabbit Web Grabber — content script.
// Detects playable media (<video> elements incl. blob: streams like web.telegram.org)
// and reports media URLs + page metadata to the background worker.
// Privacy: only media URLs and page metadata are sent; cookies/headers stay in the
// browser. blob: URLs are not fetchable from the native host, so for those we fetch
// the blob in-page and stream the bytes to the native host via chunked messages
// (the "Telegram-web path").

(() => {
  'use strict';

  const SEEN = new Set();
  const SITE = location.hostname.replace(/^www\./, '');
  const IS_TELEGRAM = /(^|\.)web\.telegram\.org$/.test(location.hostname);
  const CHUNK_SIZE = 256 * 1024; // 256 KB per chunk to native host

  function videoSource(video) {
    const src = video.currentSrc || video.src;
    if (src) return src;
    const source = video.querySelector('source[src]');
    return source ? source.src : '';
  }

  function collect() {
    const items = [];
    for (const video of document.querySelectorAll('video')) {
      const url = videoSource(video);
      if (!url || SEEN.has(url)) continue;
      SEEN.add(url);
      items.push({
        url,
        title: document.title,
        pageUrl: location.href,
        site: SITE,
        isBlob: url.startsWith('blob:'),
        duration: Number.isFinite(video.duration) ? Math.round(video.duration) : 0,
      });
    }
    return items;
  }

  function publish() {
    const items = collect();
    if (items.length === 0) return;
    chrome.runtime.sendMessage({ type: 'grabbit-media', items }).catch(() => {
      // Background worker not ready yet; keep the SEEN set so we retry on next change.
      for (const i of items) SEEN.delete(i.url);
    });
  }

  // Initial scan.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', publish, { once: true });
  } else {
    publish();
  }

  // Watch for dynamically added videos.
  const observer = new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const node of m.addedNodes) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        if (node.tagName === 'VIDEO' || node.querySelector?.('video')) {
          publish();
          return;
        }
      }
    }
  });

  function startObserving() {
    if (!document.body) {
      setTimeout(startObserving, 250);
      return;
    }
    observer.observe(document.body, { childList: true, subtree: true });
    // Special-case web.telegram.org: also watch its player container for source swaps.
    if (IS_TELEGRAM) {
      const player = document.querySelector('.media-viewer-video, .video-player, .webk-media-player');
      if (player) observer.observe(player, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
    }
  }
  startObserving();

  // Secondary signal: network resource timing for video/audio file URLs.
  try {
    if ('PerformanceObserver' in window) {
      const po = new PerformanceObserver((list) => {
        let changed = false;
        for (const entry of list.getEntries()) {
          if (entry.entryType !== 'resource') continue;
          const url = entry.name;
          if (SEEN.has(url)) continue;
          if (/\.(mp4|m4v|webm|mkv|avi|mov|mp3|m4a|ogg|wav|flac)(\?|#|$)/i.test(url)) {
            SEEN.add(url);
            changed = true;
          }
        }
        if (changed) publish();
      });
      po.observe({ type: 'resource', buffered: true });
    }
  } catch {
    // PerformanceObserver unavailable (e.g. restricted page) — primary video scan still works.
  }

  // Telegram-web path: fetch a blob: URL in-page and stream bytes to the native
  // host in chunks, since the native host cannot resolve blob: URLs.
  async function streamBlobToHost(blobUrl, requestId) {
    try {
      const res = await fetch(blobUrl);
      const buffer = await res.arrayBuffer();
      const bytes = new Uint8Array(buffer);
      const totalChunks = Math.ceil(bytes.length / CHUNK_SIZE);
      for (let i = 0; i < totalChunks; i++) {
        const slice = bytes.subarray(i * CHUNK_SIZE, (i + 1) * CHUNK_SIZE);
        await chrome.runtime.sendMessage({
          type: 'grabbit-blob-chunk',
          requestId,
          index: i,
          total: totalChunks,
          // btoa on a binary string; native host reassembles and base64-decodes.
          data: btoa(String.fromCharCode(...slice)),
        });
      }
      chrome.runtime.sendMessage({ type: 'grabbit-blob-done', requestId, byteLength: bytes.length });
    } catch (err) {
      chrome.runtime.sendMessage({ type: 'grabbit-blob-error', requestId, error: String(err) });
    }
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type === 'grabbit-fetch-blob' && typeof msg.url === 'string') {
      streamBlobToHost(msg.url, msg.requestId);
    }
  });
})();
