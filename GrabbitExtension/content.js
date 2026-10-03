// Grabbit Web Grabber — content script.
// Detects playable media (<video>/<audio> elements incl. blob: streams like
// web.telegram.org) and reports media URLs + page metadata to the background
// worker. Privacy: only media URLs, capture bytes and page metadata are sent;
// page content is never forwarded.
//
// Two in-page capture paths exist because the native host can't resolve
// browser-only resources:
//   - Blob-backed URLs: fetched in-page and streamed as chunks.
//   - MediaSource (MSE) streams — Telegram restricted channels: the page-hook
//     mirrors SourceBuffer.appendBuffer calls, and this script auto-captures
//     them per Telegram player session.

(() => {
  'use strict';

  const SEEN = new Set();
  const SITE = location.hostname.replace(/^www\./, '');
  const IS_TELEGRAM = /(^|\.)web\.telegram\.org$/.test(location.hostname);

  // Web Store compliance: the packaged store build disables capture on
  // YouTube and its CDN. scripts/package-extension.sh flips this flag to true
  // in the store ZIP; the GitHub build keeps every site enabled.
  const GRABBIT_STORE_BUILD = false;
  const YOUTUBE_HOST_RE =
    /(^|\.)(youtube\.com|youtu\.be|youtube-nocookie\.com|googlevideo\.com)$/i;
  const storeRestricted = () =>
    GRABBIT_STORE_BUILD && YOUTUBE_HOST_RE.test(location.hostname);
  const CHUNK_SIZE = 256 * 1024; // 256 KB per chunk to the native host
  const MAX_QUEUED_BYTES = 512 * 1024 * 1024; // per-stream in-memory cap

  const objectUrlKinds = new Map(); // blob: URL -> 'blob' | 'mse'

  // ---------- helpers -------------------------------------------------------

  function videoSource(el) {
    const src = el.currentSrc || el.src;
    if (src) return src;
    const source = el.querySelector('source[src]');
    return source ? source.src : '';
  }

  function bytesToBase64(u8) {
    // The slice size MUST be a multiple of 3: btoa pads each call
    // independently, and "=" padding mid-string makes decoders stop at the
    // first slice. 48 KB → 64 KB base64, no padding.
    const SLICE = 0xc000;
    let out = '';
    for (let i = 0; i < u8.length; i += SLICE) {
      out += btoa(String.fromCharCode.apply(null, u8.subarray(i, Math.min(i + SLICE, u8.length))));
    }
    return out;
  }

  function extFromMime(mime) {
    const m = (mime || '').toLowerCase();
    const isAudio = m.startsWith('audio');
    if (m.includes('mp4')) return isAudio ? 'm4a' : 'mp4';
    if (m.includes('webm')) return isAudio ? 'weba' : 'webm';
    if (m.includes('mpeg') || m.includes('mp3')) return 'mp3';
    if (m.includes('aac')) return 'aac';
    if (m.includes('ogg') || m.includes('opus')) return 'ogg';
    if (m.includes('wav')) return 'wav';
    if (m.includes('quicktime')) return 'mov';
    if (m.startsWith('video/')) return 'mp4';
    if (m.startsWith('audio/')) return 'm4a';
    return 'bin';
  }

  function timestampName(ext) {
    const d = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    return (
      'telegram-' +
      d.getFullYear() +
      pad(d.getMonth() + 1) +
      pad(d.getDate()) +
      '-' +
      pad(d.getHours()) +
      pad(d.getMinutes()) +
      pad(d.getSeconds()) +
      '.' +
      ext
    );
  }

  /// Best-effort filename for the currently open Telegram media. Falls back
  /// to a timestamped MIME-derived name.
  function telegramFilename(mime) {
    const ext = extFromMime(mime);
    if (IS_TELEGRAM) {
      const selectors = [
        '.media-viewer .MediaViewerFileName',
        '.media-viewer-filename',
        '.MediaViewerContent .title',
        '[class*="FileTitle"]',
        '[class*="media-viewer"] [class*="name"]',
        // WebK exposes the file name via generic title/name nodes inside
        // the viewer rather than a dedicated class.
        '[class*="media-viewer"] [class*="title"]',
        '[class*="MediaViewer"] [class*="title"]',
        '[class*="DocumentName"]',
        '[class*="document-name"]',
      ];
      for (const selector of selectors) {
        try {
          const el = document.querySelector(selector);
          const text = (el?.textContent || '').trim();
          if (text && text.length > 0 && text.length <= 200) {
            return text.includes('.') ? text : text + '.' + ext;
          }
        } catch {
          // Selector/dom access failure — keep trying the next one.
        }
      }
    }
    return timestampName(ext);
  }

  /// Telegram Web A media URLs: the player streams from service-worker routes
  /// (`/a/stream/<encoded-json>` and `/a/progressive/<document…>`) that only
  /// the page context can fetch — exactly like blob: URLs. Returns metadata
  /// (filename / mime) when it can be recovered from the URL itself.
  function isTelegramMediaURL(url) {
    return IS_TELEGRAM && /\/a\/(stream|progressive)\//.test(url);
  }

  function telegramStreamInfo(url) {
    try {
      const marker = url.indexOf('/stream/');
      if (marker === -1) return null;
      const encoded = url.slice(marker + '/stream/'.length).split('/preview')[0].split('?')[0];
      const payload = JSON.parse(decodeURIComponent(encoded));
      return {
        filename: typeof payload.fileName === 'string' ? payload.fileName : '',
        mime: typeof payload.mimeType === 'string' ? payload.mimeType : '',
        size: typeof payload.size === 'number' ? payload.size : 0,
      };
    } catch {
      return null;
    }
  }

  function trackFromMime(mime) {
    const m = (mime || '').toLowerCase();
    if (m.startsWith('audio/')) return 'audio';
    if (m.startsWith('video/')) return 'video';
    return 'other';
  }

  // ---------- background pipe (with backpressure) ---------------------------

  /// Sends a stream message and resolves true when the background confirms the
  /// native host wrote it. The 20s timeout covers a slow helper ack; a broken
  /// port resolves false and the caller stops the capture.
  async function sendStreamMessage(message, timeoutMs = 20000) {
    let timer = null;
    try {
      const timeout = new Promise((resolve) => {
        timer = setTimeout(() => resolve(null), timeoutMs);
      });
      const response = await Promise.race([
        chrome.runtime.sendMessage(message).catch(() => null),
        timeout,
      ]);
      return response?.ok === true;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  function notifyBackground(title, message) {
    chrome.runtime.sendMessage({ type: 'grabbit-notify', title, message }).catch(() => {});
  }

  /// Low-volume diagnostic channel → native helper appends to
  /// Inbox/telegram-debug.log. Telegram-only events (media-item / mse-*) stay
  /// gated to keep the log quiet; blob and stream handoffs are rare and
  /// useful on any site, so they always log.
  function sendDebug(event, details) {
    const alwaysLog =
      event.startsWith('fetch-blob') ||
      event.startsWith('blob-') ||
      event.startsWith('page-fetch');
    if (!IS_TELEGRAM && !alwaysLog) return;
    try {
      chrome.runtime
        .sendMessage({ type: 'grabbit-debug', event, details: details || {} })
        .catch(() => {});
    } catch {
      // Diagnostics must never break the page.
    }
  }

  // ---------- media discovery ----------------------------------------------

  function collect() {
    if (storeRestricted()) return [];
    const items = [];
    for (const el of document.querySelectorAll('video, audio')) {
      const url = videoSource(el);
      if (!url || SEEN.has(url)) continue;
      SEEN.add(url);
      const isBlob = url.startsWith('blob:');
      const item = {
        url,
        title: document.title,
        pageUrl: location.href,
        site: SITE,
        isBlob,
        isMse: isBlob && objectUrlKinds.get(url) === 'mse',
        telegramStream: isTelegramMediaURL(url),
        kind: el.tagName === 'AUDIO' ? 'audio' : 'video',
        duration: Number.isFinite(el.duration) ? Math.round(el.duration) : 0,
      };
      items.push(item);
      sendDebug('media-item', {
        url: url.slice(0, 400),
        isBlob: item.isBlob,
        isMse: item.isMse,
        telegramStream: item.telegramStream,
        tag: item.kind,
        duration: item.duration,
      });
    }
    // Telegram photos / story images: <img> elements only inside the media
    // viewer or the stories overlay, so chat thumbnails and avatars never
    // flood the list. GIFs are muted <video> elements (covered above).
    // Both webapps are matched via the "media-viewer" class substring
    // (WebA `.media-viewer`, WebK `.media-viewer-whole`).
    if (IS_TELEGRAM) {
      const selectors = [
        '[class*="media-viewer"] img',
        '[class*="MediaViewer"] img',
        '[class*="stories"] img',
        '[class*="Stories"] img',
        '[class*="story"] img',
        '[class*="Story"] img',
      ];
      const images = new Set();
      for (const selector of selectors) {
        try {
          for (const el of document.querySelectorAll(selector)) images.add(el);
        } catch {
          // Selector unsupported on this webapp version — skip it.
        }
      }
      for (const el of images) {
        const url = el.currentSrc || el.src;
        if (!url || SEEN.has(url)) continue;
        // Skip small inline images (emoji, icons, avatars).
        const width = el.naturalWidth || el.width || 0;
        const height = el.naturalHeight || el.height || 0;
        if (width > 0 && height > 0 && width < 200 && height < 200) continue;
        SEEN.add(url);
        const item = {
          url,
          title: document.title,
          pageUrl: location.href,
          site: SITE,
          isBlob: url.startsWith('blob:'),
          isMse: false,
          telegramStream: false,
          kind: 'image',
          duration: 0,
        };
        items.push(item);
        sendDebug('media-item', {
          url: url.slice(0, 400),
          isBlob: item.isBlob,
          isMse: false,
          telegramStream: false,
          tag: 'image',
          duration: 0,
        });
      }
    }
    return items;
  }

  function publish() {
    const items = collect();
    if (items.length === 0) return;
    chrome.runtime.sendMessage({ type: 'grabbit-media', items }).catch(() => {
      // Background worker not ready yet; retry on the next DOM change.
      for (const i of items) SEEN.delete(i.url);
    });
  }

  // ---------- page hook -----------------------------------------------------

  function injectPageHook() {
    try {
      const el = document.createElement('script');
      el.src = chrome.runtime.getURL('page-hook.js');
      el.onload = () => el.remove();
      (document.head || document.documentElement).appendChild(el);
    } catch {
      // Restricted page (e.g. chrome://) — DOM scan still works.
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', injectPageHook, { once: true });
  } else {
    injectPageHook();
  }

  // ---------- MSE auto-capture (Telegram restricted videos) -----------------
  //
  // captureId keys one player session (one MediaSource). Each SourceBuffer
  // stream is written to its own file by the native helper; finalize lets the
  // app mux video+audio back together.

  const mseCaptures = new Map(); // captureId -> { streams: Map, pageUrl, createdAt }
  const streamQueues = new Map(); // `${captureId}/${streamId}` -> { chain, pendingBytes, dead }

  function enqueueStreamMessage(key, message, bytes) {
    let queue = streamQueues.get(key);
    if (!queue) {
      queue = { chain: Promise.resolve(), pendingBytes: 0, dead: false };
      streamQueues.set(key, queue);
    }
    if (queue.dead) return;
    queue.pendingBytes += bytes || 0;
    if (queue.pendingBytes > MAX_QUEUED_BYTES) {
      queue.dead = true;
      sendStreamMessage({ type: 'grabbit-stream-cancel', captureId: message.captureId });
      notifyBackground('Grabbit', 'Capture is falling behind playback and was stopped.');
      streamQueues.delete(key);
      return;
    }
    queue.chain = queue.chain.then(async () => {
      if (queue.dead) return;
      const ok = await sendStreamMessage(message);
      queue.pendingBytes = Math.max(0, queue.pendingBytes - (bytes || 0));
      if (!ok) {
        queue.dead = true;
        notifyBackground('Grabbit', 'Native host disconnected — capture stopped.');
      }
    });
  }

  function handleMseSegment(msg) {
    if (!msg || !msg.data) return;
    const captureId = 'mse-' + msg.msId;
    let capture = mseCaptures.get(captureId);
    if (!capture) {
      capture = { streams: new Map(), pageUrl: location.href, createdAt: Date.now() };
      mseCaptures.set(captureId, capture);
    }
    const mime = msg.mime || '';
    const now = Date.now();
    let stream = capture.streams.get(msg.streamId);
    const key = captureId + '/' + msg.streamId;
    const gap = stream ? now - (stream.lastChunkAt || 0) : Infinity;
    // Some players re-append a container header for every chunk (WebM chunk
    // streams); only treat an init as a restart when the stream is new, empty
    // or has been quiet long enough to be a genuine reopen/seek.
    const isRestart = msg.kind === 'init' && (!stream || stream.bytes === 0 || gap > 3000);

    if (isRestart || !stream) {
      // New init segment (or first sight of this stream): restart the file so
      // the helper always has the container header at offset 0.
      stream = {
        mime,
        track: trackFromMime(mime),
        bytes: 0,
        filename: telegramFilename(mime),
        startedAt: now,
        lastChunkAt: now,
      };
      capture.streams.set(msg.streamId, stream);
      const previous = streamQueues.get(key);
      if (previous) previous.dead = true;
      streamQueues.delete(key);
      sendDebug('mse-restart', {
        streamId: msg.streamId,
        mime,
        kind: msg.kind,
        gapMs: gap === Infinity ? null : gap,
        byteLength: msg.byteLength || 0,
      });
      enqueueStreamMessage(
        key,
        {
          type: 'grabbit-stream-init',
          captureId,
          streamId: msg.streamId,
          mime,
          track: stream.track,
          filename: stream.filename,
          pageUrl: location.href,
        },
        0
      );
    } else {
      stream.lastChunkAt = now;
    }

    stream.bytes += msg.byteLength || 0;
    enqueueStreamMessage(
      key,
      {
        type: 'grabbit-stream-chunk',
        captureId,
        streamId: msg.streamId,
        mime,
        data: msg.data,
      },
      msg.byteLength || 0
    );
  }

  function captureState() {
    const out = [];
    for (const [captureId, capture] of mseCaptures) {
      let bytes = 0;
      let filename = '';
      let videoBytes = -1;
      for (const stream of capture.streams.values()) {
        bytes += stream.bytes;
        if (stream.track === 'video' && stream.bytes >= videoBytes) {
          videoBytes = stream.bytes;
          filename = stream.filename;
        }
      }
      if (!filename) {
        for (const stream of capture.streams.values()) {
          filename = stream.filename;
          break;
        }
      }
      out.push({ captureId, bytes, filename, pageUrl: capture.pageUrl, finalizable: bytes > 0 });
    }
    return out;
  }

  async function finalizeCapture(captureId) {
    const capture = mseCaptures.get(captureId);
    if (!capture) return;
    const chains = [];
    for (const streamId of capture.streams.keys()) {
      const queue = streamQueues.get(captureId + '/' + streamId);
      if (queue) chains.push(queue.chain);
    }
    await Promise.allSettled(chains);

    let filename = '';
    let videoBytes = -1;
    for (const stream of capture.streams.values()) {
      if (stream.track === 'video' && stream.bytes >= videoBytes) {
        videoBytes = stream.bytes;
        filename = stream.filename;
      }
    }
    if (!filename) {
      for (const stream of capture.streams.values()) {
        filename = stream.filename;
        break;
      }
    }
    const ok = await sendStreamMessage(
      { type: 'grabbit-stream-finalize', captureId, filename },
      60000
    );
    if (ok) {
      mseCaptures.delete(captureId);
      for (const streamId of capture.streams.keys()) {
        streamQueues.delete(captureId + '/' + streamId);
      }
    }
    return ok;
  }

  async function cancelCapture(captureId) {
    mseCaptures.delete(captureId);
    for (const key of [...streamQueues.keys()]) {
      if (key.startsWith(captureId + '/')) streamQueues.delete(key);
    }
    await sendStreamMessage({ type: 'grabbit-stream-cancel', captureId });
  }

  /// Forces the open video to play through to the end (muted, high speed) so
  /// Telegram fetches every byte — MSE only buffers what playback needs, so a
  /// short capture would otherwise be a fragment. Finalizes when done.
  async function captureFullPlayback(captureId) {
    const videos = [...document.querySelectorAll('video')];
    const video = videos.sort((a, b) => (b.duration || 0) - (a.duration || 0))[0];
    if (!video || !mseCaptures.has(captureId)) return false;

    const previousMuted = video.muted;
    const previousRate = video.playbackRate;
    let lastProgressAt = Date.now();
    let lastTime = video.currentTime;
    const onProgress = () => {
      if (video.currentTime !== lastTime) {
        lastTime = video.currentTime;
        lastProgressAt = Date.now();
      }
    };
    video.addEventListener('timeupdate', onProgress);
    try {
      video.muted = true;
      video.currentTime = 0;
      video.playbackRate = 16;
      await video.play();
    } catch {
      // Playback requires a gesture in some cases; the popup button usually
      // counts as one. The monitor loop keeps nudging anyway.
    }
    sendDebug('capture-full-start', { captureId, duration: video.duration || 0 });

    await new Promise((resolve) => {
      const check = setInterval(() => {
        const durationKnown = Number.isFinite(video.duration) && video.duration > 0;
        const done = video.ended || (durationKnown && video.currentTime >= video.duration - 0.75);
        const stalled = Date.now() - lastProgressAt > 25000;
        if (video.paused && !done && !stalled) video.play().catch(() => {});
        if (done || stalled) {
          clearInterval(check);
          sendDebug('capture-full-end', { captureId, done, stalled });
          resolve();
        }
      }, 1000);
    });

    video.removeEventListener('timeupdate', onProgress);
    video.playbackRate = previousRate;
    video.muted = previousMuted;
    return (await finalizeCapture(captureId)) === true;
  }

  window.addEventListener('beforeunload', () => {
    for (const captureId of mseCaptures.keys()) {
      try {
        chrome.runtime.sendMessage({ type: 'grabbit-stream-cancel', captureId });
      } catch {
        // Page is going away — nothing to do.
      }
    }
  });

  // Keep the MV3 service worker (and with it the native-messaging port)
  // alive while a capture session exists. A recycled worker would close the
  // port; the helper preserves partial files, but avoiding the recycle keeps
  // the transfer seamless through long pauses in playback.
  setInterval(() => {
    if (mseCaptures.size > 0) {
      chrome.runtime.sendMessage({ type: 'grabbit-stream-ping' }).catch(() => {});
    }
  }, 20000);

  // ---------- in-page message bridge ---------------------------------------

  window.addEventListener('message', (event) => {
    if (event.source !== window) return;
    const msg = event.data;
    if (!msg || msg.source !== 'grabbit-page-hook') return;
    if (storeRestricted()) return;

    if (msg.type === 'grabbit-network-media') {
      if (!msg.url || SEEN.has(msg.url)) return;
      SEEN.add(msg.url);
      chrome.runtime
        .sendMessage({
          type: 'grabbit-media',
          items: [{
            url: msg.url,
            title: msg.pageTitle || document.title,
            pageUrl: msg.pageUrl || location.href,
            site: SITE,
            isBlob: false,
            telegramStream: msg.telegramStream === true || isTelegramMediaURL(msg.url),
            via: 'network',
          }],
        })
        .catch(() => {
          SEEN.delete(msg.url);
        });
      return;
    }

    if (msg.type === 'grabbit-object-url' && msg.url) {
      objectUrlKinds.set(msg.url, msg.kind === 'mse' ? 'mse' : 'blob');
      return;
    }

    if (msg.type === 'grabbit-mse-segment') {
      handleMseSegment(msg);
      return;
    }

    if (
      msg.type === 'grabbit-page-fetch-start' ||
      msg.type === 'grabbit-page-fetch-chunk' ||
      msg.type === 'grabbit-page-fetch-end' ||
      msg.type === 'grabbit-page-fetch-error'
    ) {
      handlePageFetchMessage(msg);
    }
  });

  // ---------- page-context fetch (Telegram service-worker URLs) -------------
  //
  // Content-script fetches bypass the page's service worker, so Telegram's
  // /a/stream//a/progressive routes answer with the app HTML (302) instead of
  // the file. The background injects a MAIN-world function (scripting API,
  // CSP-immune, always current code) that performs the fetch and streams the
  // bytes back; we relay them to the native host with per-chunk ACKs.

  const pageFetches = new Map(); // requestId -> state

  function ackPageChunk(requestId, index) {
    window.postMessage(
      { source: 'grabbit-content', type: 'grabbit-page-fetch-ack', requestId, index },
      '*'
    );
  }


  const MAX_INFLIGHT = 6;

  function acquireSlot(state) {
    if (state.inFlight < MAX_INFLIGHT) {
      state.inFlight += 1;
      return Promise.resolve();
    }
    return new Promise((resolve) => state.waiters.push(resolve));
  }

  function releaseSlot(state) {
    state.inFlight -= 1;
    const next = state.waiters.shift();
    if (next) {
      state.inFlight += 1;
      next();
    }
  }

  async function streamViaPageFetch(url, requestId, filenameHint) {
    const state = {
      url,
      captureId: requestId,
      filenameHint,
      mime: '',
      filename: '',
      started: false,
      failed: false,
      error: '',
      pending: Promise.resolve(),
      resolveDone: null,
      initPromise: null,
      inFlight: 0,
      waiters: [],
      outstanding: new Set(),
      sentBytes: 0,
      totalBytes: 0,
      lastProgressAt: 0,
    };
    pageFetches.set(requestId, state);

    try {
      const completion = new Promise((resolve) => {
        state.resolveDone = resolve;
      });
      const execResult = await chrome.runtime
        .sendMessage({ type: 'grabbit-page-fetch-exec', url, requestId })
        .catch(() => null);
      if (!execResult?.ok) throw new Error('could not start the in-page fetch');
      // A MAIN-world fetch must start streaming (or fail) in a reasonable
      // time; otherwise surface it instead of hanging forever.
      state.timeout = setTimeout(() => {
        if (!state.started && !state.failed) {
          state.failed = true;
          state.error = 'in-page fetch timed out';
          state.resolveDone?.();
        }
      }, 30000);

      await completion;
      clearTimeout(state.timeout);
      await Promise.allSettled([...state.outstanding]); // drain in-flight chunks
      await state.pending; // drain the last chunk's native ACK
      if (!state.started) throw new Error(state.error || 'page fetch failed');
      if (state.failed) throw new Error(state.error || 'native host disconnected');
      const ok = await sendStreamMessage(
        { type: 'grabbit-stream-finalize', captureId: requestId, filename: state.filename },
        60000
      );
      if (!ok) throw new Error('finalize failed');
      chrome.runtime
        .sendMessage({ type: 'grabbit-blob-result', requestId, ok: true, filename: state.filename })
        .catch(() => {});
    } catch (error) {
      clearTimeout(state.timeout);
      sendStreamMessage({ type: 'grabbit-stream-cancel', captureId: requestId });
      chrome.runtime
        .sendMessage({ type: 'grabbit-blob-result', requestId, ok: false, error: String(error) })
        .catch(() => {});
    } finally {
      pageFetches.delete(requestId);
    }
  }

  function handlePageFetchMessage(msg) {
    const state = pageFetches.get(msg.requestId);
    if (!state) {
      if (msg.type === 'grabbit-page-fetch-chunk') ackPageChunk(msg.requestId, msg.index);
      return;
    }
    if (msg.type === 'grabbit-page-fetch-start') {
      if (!msg.ok || msg.status >= 400 || (msg.mime || '').includes('text/html')) {
        state.error = `HTTP ${msg.status} ${msg.mime || ''}`.trim();
        sendDebug('page-fetch-rejected', {
          url: state.url.slice(0, 300),
          status: msg.status,
          mime: msg.mime || '',
        });
        state.resolveDone?.();
        return;
      }
      const info = telegramStreamInfo(state.url) || {};
      const mime = msg.mime || info.mime || '';
      state.mime = mime;
      state.totalBytes = msg.total || 0;
      state.filename = state.filenameHint || info.filename || telegramFilename(mime);
      sendDebug('page-fetch-start', {
        url: state.url.slice(0, 400),
        status: msg.status,
        mime,
        filename: state.filename,
        total: msg.total || 0,
      });
      state.initPromise = sendStreamMessage({
        type: 'grabbit-stream-init',
        captureId: state.captureId,
        streamId: 'blob',
        mime,
        track: trackFromMime(mime),
        filename: state.filename,
        pageUrl: location.href,
      });
      state.initPromise.then((ok) => {
        state.started = ok;
        if (!ok) {
          state.failed = true;
          state.error = 'native host unavailable';
          state.resolveDone?.();
        }
      });
      return;
    }
    if (msg.type === 'grabbit-page-fetch-chunk') {
      const bytes = new Uint8Array(msg.data);
      const encoded = bytesToBase64(bytes);
      if (msg.index < 3) {
        sendDebug('page-fetch-chunk', {
          index: msg.index,
          received: bytes.length,
          encodedLength: encoded.length,
        });
      }
      state.sentBytes += bytes.length;
      if (state.sentBytes - state.lastProgressAt >= 5 * 1024 * 1024) {
        state.lastProgressAt = state.sentBytes;
        chrome.runtime
          .sendMessage({
            type: 'grabbit-stream-progress',
            captureId: state.captureId,
            bytes: state.sentBytes,
            total: state.totalBytes,
          })
          .catch(() => {});
      }
      state.pending = state.pending.then(async () => {
        if (state.initPromise) await state.initPromise;
        if (!state.started || state.failed) {
          ackPageChunk(msg.requestId, msg.index);
          return;
        }
        // Keep up to MAX_INFLIGHT chunks in flight instead of one-at-a-time
        // round trips — roughly quadruples capture throughput.
        await acquireSlot(state);
        const sendTask = sendStreamMessage({
          type: 'grabbit-stream-chunk',
          captureId: state.captureId,
          streamId: 'blob',
          mime: state.mime,
          data: encoded,
        }).then((ok) => {
          if (!ok) {
            state.failed = true;
            state.error = 'native host disconnected';
          }
          releaseSlot(state);
          ackPageChunk(msg.requestId, msg.index);
        });
        state.outstanding.add(sendTask);
        sendTask.finally(() => state.outstanding.delete(sendTask));
      });
      return;
    }
    if (msg.type === 'grabbit-page-fetch-end') {
      state.resolveDone?.();
      return;
    }
    if (msg.type === 'grabbit-page-fetch-error') {
      state.failed = true;
      state.error = msg.error || 'page fetch error';
      sendDebug('page-fetch-error', {
        url: state.url.slice(0, 300),
        error: state.error,
      });
      state.resolveDone?.();
    }
  }

  // ---------- blob streaming ------------------------------------------------
  //
  // Blob-backed URLs are fetchable in-page; stream them instead of buffering
  // the whole blob (large Telegram files would OOM the tab otherwise).

  async function streamBlobToHost(blobUrl, requestId, filenameHint) {
    // Telegram service-worker routes must be fetched from the page's main
    // world (see streamViaPageFetch).
    if (isTelegramMediaURL(blobUrl)) {
      return streamViaPageFetch(blobUrl, requestId, filenameHint);
    }
    try {
      const response = await fetch(blobUrl);
      const mimeHeader = response.headers.get('content-type') || '';
      if (response.status >= 400 || mimeHeader.includes('text/html')) {
        throw new Error(`HTTP ${response.status} ${mimeHeader}`.trim());
      }
      const streamInfo = telegramStreamInfo(blobUrl);
      const mime = mimeHeader || streamInfo?.mime || '';
      const filename = filenameHint || streamInfo?.filename || telegramFilename(mime);
      sendDebug('blob-start', {
        url: blobUrl.slice(0, 400),
        mime,
        filename,
        status: response.status,
      });

      const started = await sendStreamMessage({
        type: 'grabbit-stream-init',
        captureId: requestId,
        streamId: 'blob',
        mime,
        track: trackFromMime(mime),
        filename,
        pageUrl: location.href,
      });
      if (!started) throw new Error('native host unavailable');

      if (response.body) {
        const reader = response.body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          if (!value || value.length === 0) continue;
          for (let offset = 0; offset < value.length; offset += CHUNK_SIZE) {
            const slice = value.subarray(offset, Math.min(offset + CHUNK_SIZE, value.length));
            const ok = await sendStreamMessage({
              type: 'grabbit-stream-chunk',
              captureId: requestId,
              streamId: 'blob',
              mime,
              data: bytesToBase64(slice),
            });
            if (!ok) throw new Error('native host disconnected');
          }
        }
      } else {
        const buffer = await response.arrayBuffer();
        const bytes = new Uint8Array(buffer);
        for (let offset = 0; offset < bytes.length; offset += CHUNK_SIZE) {
          const slice = bytes.subarray(offset, Math.min(offset + CHUNK_SIZE, bytes.length));
          const ok = await sendStreamMessage({
            type: 'grabbit-stream-chunk',
            captureId: requestId,
            streamId: 'blob',
            mime,
            data: bytesToBase64(slice),
          });
          if (!ok) throw new Error('native host disconnected');
        }
      }

      await sendStreamMessage({ type: 'grabbit-stream-finalize', captureId: requestId, filename }, 60000);
      chrome.runtime.sendMessage({ type: 'grabbit-blob-result', requestId, ok: true, filename }).catch(() => {});
    } catch (error) {
      sendDebug('blob-error', { url: blobUrl.slice(0, 300), error: String(error) });
      await sendStreamMessage({ type: 'grabbit-stream-cancel', captureId: requestId });
      chrome.runtime
        .sendMessage({ type: 'grabbit-blob-result', requestId, ok: false, error: String(error) })
        .catch(() => {});
    }
  }

  // ---------- extension messaging ------------------------------------------

  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg?.type === 'grabbit-content-version') {
      sendResponse({ version: chrome.runtime.getManifest().version });
      return true;
    }
    if (msg?.type === 'grabbit-fetch-blob' && typeof msg.url === 'string') {
      if (storeRestricted()) {
        sendResponse({ ok: false });
        return true;
      }
      sendDebug('fetch-blob-request', {
        url: msg.url.slice(0, 300),
        requestId: msg.requestId,
      });
      streamBlobToHost(msg.url, msg.requestId, msg.filename);
      sendResponse({ ok: true, version: chrome.runtime.getManifest().version });
      return true;
    }
    if (msg?.type === 'grabbit-get-capture-state') {
      sendResponse({ captures: captureState() });
      return true;
    }
    if (msg?.type === 'grabbit-finalize-capture' && typeof msg.captureId === 'string') {
      finalizeCapture(msg.captureId).then((ok) => sendResponse({ ok: ok === true }));
      return true;
    }
    if (msg?.type === 'grabbit-capture-full' && typeof msg.captureId === 'string') {
      captureFullPlayback(msg.captureId);
      sendResponse({ ok: true, started: true });
      return true;
    }
    if (msg?.type === 'grabbit-cancel-capture' && typeof msg.captureId === 'string') {
      cancelCapture(msg.captureId).then(() => sendResponse({ ok: true }));
      return true;
    }
    return undefined;
  });

  // ---------- DOM observation ----------------------------------------------

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', publish, { once: true });
  } else {
    publish();
  }

  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        if (node.tagName === 'VIDEO' || node.tagName === 'AUDIO' || node.querySelector?.('video, audio')) {
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
})();
