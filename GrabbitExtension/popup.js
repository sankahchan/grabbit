// Grabbit Web Grabber — popup: lists media detected on the current tab.
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

async function main() {
  await initControls();
  const list = document.getElementById('list');
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) {
    list.innerHTML = '<p class="empty">No active tab.</p>';
    return;
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
    return;
  }
  list.innerHTML = '';
  for (const item of items) {
    list.appendChild(mediaRow(item, tab.id));
  }
}

function mediaRow(item, tabId) {
  const div = document.createElement('div');
  div.className = 'item';
  const via = item.via === 'network' ? ' · via network' : '';
  div.innerHTML = `<div class="url"></div><div class="meta"></div><div class="actions"></div>`;
  div.querySelector('.url').textContent = shortUrl(item.url);
  div.querySelector('.meta').textContent = (item.site || '') + via;
  const actions = div.querySelector('.actions');
  // Telegram document URLs (web.telegram.org/document...) are not directly
  // downloadable via HTTP — they require Telegram's internal API. Don't show
  // a broken download button; direct users to Telegram's own download.
  const isTelegramDoc = /web\.telegram\.org\/document/i.test(item.url);
  if (item.isBlob) {
    const note = document.createElement('span');
    note.className = 'blob-note';
    note.textContent = 'In-page stream — use the in-page player download if available.';
    actions.appendChild(note);
  } else if (isTelegramDoc) {
    const note = document.createElement('span');
    note.className = 'blob-note';
    note.textContent = 'Telegram file — use Telegram\u2019s download button.';
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
