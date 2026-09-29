// Grabbit Web Grabber — popup: lists media detected on the current tab and
// media captures (Telegram restricted videos) streaming into Grabbit.
'use strict';

function shortUrl(url) {
  try {
    const u = new URL(url);
    const path = u.pathname.split('/').pop() || u.host;
    return (u.host + '/' + path).slice(0, 60);
  } catch {
    return url.slice(0, 60);
  }
}

function formatBytes(bytes) {
  if (!bytes) return '0 MB';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(0) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

async function main() {
  await initControls();
  loadHostStatus();
  const list = document.getElementById('list');
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) {
    list.innerHTML = '<p class="empty">No active tab.</p>';
    return;
  }
  if (/^https?:/i.test(tab.url || '')) {
    renderTabVersion(tab.id).catch(() => {});
  }

  let items = [];
  try {
    const res = await chrome.runtime.sendMessage({ type: 'grabbit-get-media', tabId: tab.id });
    items = res?.items || [];
  } catch {
    items = [];
  }

  if (items.length === 0) {
    list.innerHTML = '<p class="empty">No media detected on this page yet. Play a video or right-click a link and choose “Download with Grabbit”.</p>';
  } else {
    // Telegram Web A: the real media entries are the service-worker
    // "stream/progressive" URLs; blob entries can be tiny preview fragments.
    // Surface the full-file entries first.
    items.sort(
      (a, b) => Number(b.telegramStream === true) - Number(a.telegramStream === true)
    );
    list.innerHTML = '';
    for (const item of items) {
      list.appendChild(mediaRow(item, tab.id));
    }
  }

  // Live capture state refreshes while the popup is open.
  const refresh = () => loadCaptures(tab.id).catch(() => {});
  refresh();
  setInterval(refresh, 1500);
}

async function loadHostStatus() {
  const el = document.getElementById('hostStatus');
  const version = chrome.runtime.getManifest().version;
  let status = 'native host: unavailable — run native-messaging/install-host.sh';
  try {
    const res = await chrome.runtime.sendMessage({ type: 'grabbit-host-status' });
    if (res?.ok) status = 'native host: connected';
  } catch {
    // Keep the unavailable message.
  }
  el.textContent = `v${version} · ${status}`;
}

/// After an extension reload, already-open tabs keep the OLD content script;
/// its runtime calls fail silently, so grabs look "Sent" but nothing happens.
/// Surface that and offer a one-click tab reload.
async function renderTabVersion(tabId) {
  const banner = document.getElementById('tabWarning');
  banner.style.display = 'none';
  banner.innerHTML = '';
  const expected = chrome.runtime.getManifest().version;
  let version = null;
  try {
    const res = await chrome.tabs.sendMessage(tabId, { type: 'grabbit-content-version' }, { frameId: 0 });
    version = res?.version || null;
  } catch {
    version = null;
  }
  if (version === expected) return true;

  banner.style.display = '';
  const text = document.createElement('span');
  text.textContent = version
    ? `This tab runs Grabbit v${version}; reload it to use v${expected}.`
    : 'This tab is not running the current Grabbit script — reload it.';
  const reload = document.createElement('button');
  reload.textContent = 'Reload tab';
  reload.addEventListener('click', () => chrome.tabs.reload(tabId));
  banner.append(text, reload);
  return false;
}

async function loadCaptures(tabId) {
  const section = document.getElementById('captures');
  const listEl = document.getElementById('captureList');
  let captures = [];
  try {
    const res = await chrome.tabs.sendMessage(tabId, { type: 'grabbit-get-capture-state' }, { frameId: 0 });
    captures = res?.captures || [];
  } catch {
    captures = [];
  }
  if (captures.length === 0) {
    section.style.display = 'none';
    listEl.innerHTML = '';
    return;
  }
  section.style.display = '';
  listEl.innerHTML = '';
  for (const capture of captures) {
    listEl.appendChild(captureRow(capture, tabId));
  }
}

function captureRow(capture, tabId) {
  const div = document.createElement('div');
  div.className = 'item';
  div.innerHTML = `<div class="url"></div><div class="meta"></div><div class="actions"></div>`;
  div.querySelector('.url').textContent = capture.filename || 'Media capture';
  div.querySelector('.meta').textContent = formatBytes(capture.bytes) + ' captured — save to Grabbit';
  const actions = div.querySelector('.actions');

  const full = document.createElement('button');
  full.textContent = 'Auto-play & capture full';
  full.title =
    'Plays the video (muted, fast) so Telegram fetches every byte, then saves automatically.';
  full.addEventListener('click', async () => {
    full.disabled = true;
    full.textContent = 'Capturing full…';
    try {
      const res = await chrome.tabs.sendMessage(
        tabId,
        {
          type: 'grabbit-capture-full',
          captureId: capture.captureId,
        },
        { frameId: 0 }
      );
      if (!res?.ok) {
        full.textContent = 'Failed — retry';
        full.disabled = false;
      }
    } catch {
      full.textContent = 'Failed — retry';
      full.disabled = false;
    }
  });

  const save = document.createElement('button');
  save.textContent = 'Save to Grabbit';
  save.disabled = !capture.finalizable;
  save.addEventListener('click', async () => {
    save.disabled = true;
    save.textContent = 'Saving…';
    try {
      const res = await chrome.tabs.sendMessage(
        tabId,
        {
          type: 'grabbit-finalize-capture',
          captureId: capture.captureId,
        },
        { frameId: 0 }
      );
      save.textContent = res?.ok ? 'Saved ✓' : 'Failed — retry';
      save.disabled = res?.ok === true;
    } catch {
      save.textContent = 'Failed — retry';
      save.disabled = false;
    }
  });

  const discard = document.createElement('button');
  discard.className = 'secondary';
  discard.textContent = 'Discard';
  discard.addEventListener('click', async () => {
    discard.disabled = true;
    try {
      await chrome.tabs.sendMessage(
        tabId,
        {
          type: 'grabbit-cancel-capture',
          captureId: capture.captureId,
        },
        { frameId: 0 }
      );
      discard.textContent = 'Discarded';
    } catch {
      discard.disabled = false;
    }
  });

  actions.append(full, save, discard);
  return div;
}

function mediaRow(item, tabId) {
  const div = document.createElement('div');
  div.className = 'item';
  const via = item.via === 'network' ? ' · via network' : '';
  div.innerHTML = `<div class="url"></div><div class="meta"></div><div class="actions"></div>`;
  div.querySelector('.url').textContent = shortUrl(item.url);
  div.querySelector('.meta').textContent = (item.site || '') + via + (item.kind === 'audio' ? ' · audio' : '');
  const actions = div.querySelector('.actions');
  // Telegram document URLs (web.telegram.org/document...) are not directly
  // downloadable via HTTP — they require Telegram's internal API.
  const isTelegramDoc = /web\.telegram\.org\/document/i.test(item.url);
  // Telegram Web A serves player media from service-worker routes; like
  // blob: URLs they are only fetchable in-page.
  const isTelegramStream =
    item.telegramStream === true || /web\.telegram\.org\/a\/(stream|progressive)\//i.test(item.url);
  if (item.isMse) {
    const note = document.createElement('span');
    note.className = 'blob-note';
    note.textContent = 'Live stream — use “Save to Grabbit” above once it plays.';
    actions.appendChild(note);
  } else if (item.isBlob || isTelegramStream) {
    const isTelegramBlob = item.isBlob && item.site === 'web.telegram.org';
    actions.appendChild(
      blobButton(
        item.url,
        tabId,
        isTelegramBlob ? 'Grab blob (may be partial)' : 'Download with Grabbit',
        item.kind || ''
      )
    );
  } else if (isTelegramDoc) {
    const note = document.createElement('span');
    note.className = 'blob-note';
    note.textContent = 'Telegram file — use Telegram\u2019s own download button; Grabbit picks it up.';
    actions.appendChild(note);
  } else {
    actions.appendChild(downloadButton(item.url, tabId));
  }
  return div;
}

function downloadButton(url, tabId, label = 'Download with Grabbit') {
  const btn = document.createElement('button');
  btn.textContent = label;
  btn.addEventListener('click', async () => {
    btn.disabled = true;
    btn.textContent = 'Sent ✓';
    try {
      await chrome.runtime.sendMessage({ type: 'grabbit-send-media', tabId, url });
    } catch {
      btn.textContent = 'Failed — retry';
      btn.disabled = false;
    }
  });
  return btn;
}

function blobButton(url, tabId, label = 'Download with Grabbit', kind = '') {
  const btn = document.createElement('button');
  btn.textContent = label;
  btn.addEventListener('click', async () => {
    btn.disabled = true;
    btn.textContent = 'Capturing…';
    try {
      const res = await chrome.runtime.sendMessage({ type: 'grabbit-start-blob', tabId, url, kind });
      const expected = chrome.runtime.getManifest().version;
      if (res?.ok && res.version && res.version !== expected) {
        // Stale content script: the grab would fail silently.
        btn.textContent = 'Reload tab first';
        btn.disabled = false;
        renderTabVersion(tabId).catch(() => {});
        return;
      }
      if (res?.ok) {
        btn.textContent = 'Sent ✓';
      } else {
        btn.textContent = 'Failed — retry';
        btn.disabled = false;
      }
    } catch {
      btn.textContent = 'Failed — retry';
      btn.disabled = false;
    }
  });
  return btn;
}

async function initControls() {
  // Auto-intercept toggle (persisted).
  const toggle = document.getElementById('autoIntercept');
  try {
    const stored = await chrome.storage.sync.get('autoIntercept');
    toggle.checked = stored.autoIntercept !== false;
  } catch { /* default checked */ }
  toggle.addEventListener('change', () => {
    chrome.storage.sync.set({ autoIntercept: toggle.checked }).catch(() => {});
  });

  // Manual URL entry.
  const input = document.getElementById('manualUrl');
  const go = document.getElementById('manualGo');
  go.addEventListener('click', async () => {
    const url = (input.value || '').trim();
    if (!/^https?:\/\//i.test(url)) return;
    go.disabled = true;
    try {
      await chrome.runtime.sendMessage({ type: 'grabbit-send-url', url });
      input.value = '';
    } catch { /* ignore */ }
    go.disabled = false;
  });

  // Clipboard monitor (QDM idea). MV3 service workers are ephemeral and have
  // no clipboard access, so the poll lives here: while the popup is open we
  // check once for a URL on the clipboard and offer it (deduped per open).
  try {
    const text = await navigator.clipboard.readText();
    const url = (text || '').trim();
    if (/^https?:\/\/\S+$/i.test(url)) {
      const row = document.getElementById('clipboardRow');
      const div = document.createElement('div');
      div.className = 'item';
      div.innerHTML = `<div class="meta">Clipboard</div><div class="url"></div><div class="actions"></div>`;
      div.querySelector('.url').textContent = shortUrl(url);
      div.querySelector('.actions').appendChild(downloadButton(url, 0, 'Grab clipboard URL'));
      row.appendChild(div);
    }
  } catch {
    // Clipboard unreadable (permissions/focus) — manual entry still works.
  }
}

main().catch(() => {});
