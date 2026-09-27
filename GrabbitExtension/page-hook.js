// Grabbit Web Grabber — page-world hook (runs in the page's MAIN world).
//
// Content scripts live in an isolated world and can't see the page's own
// XHR/fetch calls. This script is injected into the page itself and wraps
// XMLHttpRequest and fetch to sniff out media URLs (video/audio/manifests)
// as the page's own players request them — the XDM "page-world interception"
// idea. Matches are reported to the content script via window.postMessage;
// only URLs + page metadata cross the boundary, never page content.

(() => {
  'use strict';

  const MEDIA_RE = /\.(mp4|m4v|webm|mkv|avi|mov|m3u8|mpd|mp3|m4a|aac|ogg|oga|wav|flac|ts|m2ts)(\?|#|$)/i;
  const seen = new Set();

  function report(url) {
    if (!url || typeof url !== 'string') return;
    if (url.startsWith('blob:') || url.startsWith('data:')) return;
    if (seen.has(url)) return;
    if (!MEDIA_RE.test(url)) return;
    seen.add(url);
    window.postMessage(
      {
        source: 'grabbit-page-hook',
        type: 'grabbit-network-media',
        url,
        pageUrl: location.href,
        pageTitle: document.title,
      },
      '*'
    );
  }

  function absolutize(u) {
    try {
      return new URL(u, location.href).href;
    } catch {
      return null;
    }
  }

  // --- fetch ---
  const origFetch = window.fetch;
  if (typeof origFetch === 'function') {
    window.fetch = function (input, init) {
      try {
        const url = typeof input === 'string' ? input : input?.url;
        const abs = url ? absolutize(url) : null;
        if (abs) report(abs);
      } catch {
        // Never break the page's own networking.
      }
      return origFetch.apply(this, arguments);
    };
  }

  // --- XMLHttpRequest ---
  const origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    try {
      const abs = typeof url === 'string' ? absolutize(url) : null;
      if (abs) report(abs);
    } catch {
      // Never break the page's own networking.
    }
    return origOpen.apply(this, arguments);
  };

  // --- HTMLMediaElement src setters (catches player.src = '...' swaps) ---
  try {
    for (const tag of ['HTMLVideoElement', 'HTMLAudioElement']) {
      const proto = window[tag]?.prototype;
      if (!proto) continue;
      const desc = Object.getOwnPropertyDescriptor(proto, 'src');
      if (!desc || !desc.set) continue;
      Object.defineProperty(proto, 'src', {
        configurable: true,
        enumerable: desc.enumerable,
        get: desc.get,
        set(v) {
          try {
            const abs = typeof v === 'string' ? absolutize(v) : null;
            if (abs) report(abs);
          } catch {
            // ignore
          }
          return desc.set.call(this, v);
        },
      });
    }
  } catch {
    // Non-fatal: MutationObserver in the content script still catches <video> tags.
  }
})();
