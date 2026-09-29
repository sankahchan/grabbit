// Grabbit Web Grabber — page-world hook (runs in the page's MAIN world).
//
// Content scripts live in an isolated world and can't see the page's own
// XHR/fetch calls. This script is injected into the page itself and wraps
// XMLHttpRequest and fetch to sniff out media URLs (video/audio/manifests)
// as the page's own players request them — the XDM "page-world interception"
// idea. Matches are reported to the content script via window.postMessage;
// only URLs + page metadata cross the boundary, never page content.
//
// Telegram Web special case: restricted channels play videos through
// MediaSource (MSE) — the decrypted bytes are appended to SourceBuffers and
// a plain blob: URL fetch can't recover them. On web.telegram.org we also
// wrap URL.createObjectURL (to tag blob vs MSE object URLs) and
// SourceBuffer.appendBuffer (to mirror the streamed segments to the content
// script). The grabbit-mse-segment messages carry base64 fMP4/WebM chunks.

(() => {
  'use strict';

  const IS_TELEGRAM = /(^|\.)web\.telegram\.org$/.test(location.hostname);
  const MEDIA_RE = /\.(mp4|m4v|webm|mkv|avi|mov|m3u8|mpd|mp3|m4a|aac|ogg|oga|wav|flac|ts|m2ts)(\?|#|$)/i;
  // Telegram Web A serves playable media from service-worker routes that
  // don't look like file URLs (/a/stream/<encoded-json>, /a/progressive/…).
  const TELEGRAM_MEDIA_RE = IS_TELEGRAM ? /\/a\/(stream|progressive)\// : null;
  const seen = new Set();

  function report(url) {
    if (!url || typeof url !== 'string') return;
    if (url.startsWith('blob:') || url.startsWith('data:')) return;
    if (seen.has(url)) return;
    const isTelegramMedia = TELEGRAM_MEDIA_RE ? TELEGRAM_MEDIA_RE.test(url) : false;
    if (!MEDIA_RE.test(url) && !isTelegramMedia) return;
    seen.add(url);
    window.postMessage(
      {
        source: 'grabbit-page-hook',
        type: 'grabbit-network-media',
        url,
        pageUrl: location.href,
        pageTitle: document.title,
        telegramStream: isTelegramMedia,
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

  // --- Object URL tagging ---------------------------------------------------
  //
  // The content script needs to know whether a blob: URL wraps a real Blob
  // (fetchable) or a MediaSource (only recoverable through appendBuffer).

  try {
    const origCreate = URL.createObjectURL;
    if (typeof origCreate === 'function') {
      URL.createObjectURL = function (obj) {
        const url = origCreate.call(URL, obj);
        try {
          let kind = 'blob';
          let mime = '';
          if (typeof MediaSource !== 'undefined' && obj instanceof MediaSource) {
            kind = 'mse';
          } else if (typeof Blob !== 'undefined' && obj instanceof Blob) {
            mime = obj.type || '';
          }
          window.postMessage(
            { source: 'grabbit-page-hook', type: 'grabbit-object-url', url, kind, mime },
            '*'
          );
        } catch {
          // Tagging is best-effort; the URL is still returned to the page.
        }
        return url;
      };
      const origRevoke = URL.revokeObjectURL;
      if (typeof origRevoke === 'function') {
        URL.revokeObjectURL = function (url) {
          return origRevoke.call(URL, url);
        };
      }
    }
  } catch {
    // URL.createObjectURL unavailable — MSE capture below still works.
  }

  // --- MediaSource / SourceBuffer interception (Telegram only) --------------
  //
  // Gated on Telegram because appendBuffer fires on every video frame batch;
  // mirroring it on every site would be wasted CPU.

  function bytesToBase64(u8) {
    // Slice size must be a multiple of 3 so btoa never emits "=" padding
    // mid-string (padding stops native decoders at the first slice).
    const SLICE = 0xc000; // 48 KB
    let out = '';
    for (let i = 0; i < u8.length; i += SLICE) {
      out += btoa(String.fromCharCode.apply(null, u8.subarray(i, Math.min(i + SLICE, u8.length))));
    }
    return out;
  }

  function boxTypeAt(u8, off) {
    if (off + 8 > u8.length) return '';
    return String.fromCharCode(u8[off + 4], u8[off + 5], u8[off + 6], u8[off + 7]);
  }

  /// fMP4 init segments start with `ftyp`/`moov`; WebM init data starts with
  /// the EBML magic. Media segments start with `styp`/`moof`/`mdat`.
  function detectSegmentKind(u8) {
    if (u8.length >= 4 && u8[0] === 0x1a && u8[1] === 0x45 && u8[2] === 0xdf && u8[3] === 0xa3) {
      return 'init';
    }
    const first = boxTypeAt(u8, 0);
    if (first === 'ftyp' || first === 'moov') return 'init';
    return 'media';
  }

  if (IS_TELEGRAM) {
    try {
      const mediaSourceIds = new WeakMap();
      const streamMeta = new WeakMap(); // SourceBuffer -> {id, mime, msId}
      let msSeq = 0;
      let streamSeq = 0;

      const origAddSourceBuffer = MediaSource.prototype.addSourceBuffer;
      MediaSource.prototype.addSourceBuffer = function (mime) {
        const sourceBuffer = origAddSourceBuffer.apply(this, arguments);
        try {
          let msId = mediaSourceIds.get(this);
          if (!msId) {
            msId = 'ms' + ++msSeq;
            mediaSourceIds.set(this, msId);
          }
          streamMeta.set(sourceBuffer, {
            id: 'st' + ++streamSeq,
            mime: String(mime || ''),
            msId,
          });
        } catch {
          // Tracking is best-effort; playback must never break.
        }
        return sourceBuffer;
      };

      const origChangeType = SourceBuffer.prototype.changeType;
      if (typeof origChangeType === 'function') {
        SourceBuffer.prototype.changeType = function (mime) {
          try {
            const meta = streamMeta.get(this);
            if (meta) meta.mime = String(mime || '');
          } catch {
            // ignore
          }
          return origChangeType.apply(this, arguments);
        };
      }

      const origAppendBuffer = SourceBuffer.prototype.appendBuffer;
      SourceBuffer.prototype.appendBuffer = function (data) {
        // MSE's appendBuffer DETACHES ArrayBuffers, so snapshot the bytes
        // before calling it — encoding afterwards would read a zero-length
        // buffer. The snapshot copy is cheap; the base64 encode runs in a
        // microtask so playback is never delayed.
        let snapshot = null;
        try {
          const meta = streamMeta.get(this);
          if (meta && data && data.byteLength > 0) {
            const u8 =
              data instanceof ArrayBuffer
                ? new Uint8Array(data)
                : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            const copy = new Uint8Array(u8.byteLength);
            copy.set(u8);
            snapshot = {
              msId: meta.msId,
              streamId: meta.id,
              mime: meta.mime,
              kind: detectSegmentKind(copy),
              byteLength: copy.byteLength,
              copy,
            };
          }
        } catch {
          snapshot = null;
        }
        const result = origAppendBuffer.apply(this, arguments);
        if (snapshot) {
          queueMicrotask(() => {
            try {
              window.postMessage(
                {
                  source: 'grabbit-page-hook',
                  type: 'grabbit-mse-segment',
                  msId: snapshot.msId,
                  streamId: snapshot.streamId,
                  mime: snapshot.mime,
                  kind: snapshot.kind,
                  byteLength: snapshot.byteLength,
                  data: bytesToBase64(snapshot.copy),
                },
                '*'
              );
            } catch {
              // Encoding must never break the page's player.
            }
          });
        }
        return result;
      };
    } catch {
      // MediaSource hooks unavailable — blob URL capture still works.
    }
  }
})();
