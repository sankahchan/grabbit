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
    const div = document.createElement('div');
    div.className = 'item';
    const via = item.via === 'network' ? ' · via network' : '';
    div.innerHTML =
      `<div class="url"></div><div class="meta"></div><div class="actions"></div>`;
    div.querySelector('.url').textContent = shortUrl(item.url);
    div.querySelector('.meta').textContent = (item.site || '') + via;
    const actions = div.querySelector('.actions');
    if (item.isBlob) {
      const note = document.createElement('span');
      note.className = 'blob-note';
      note.textContent = 'In-page stream — use the in-page player download if available.';
      actions.appendChild(note);
    } else {
      const btn = document.createElement('button');
      btn.textContent = 'Download with Grabbit';
      btn.addEventListener('click', async () => {
        btn.disabled = true;
        btn.textContent = 'Sent ✓';
        try {
          await chrome.runtime.sendMessage({
            type: 'grabbit-send-media',
            tabId: tab.id,
            url: item.url,
          });
        } catch {
          btn.textContent = 'Failed — retry';
          btn.disabled = false;
        }
      });
      actions.appendChild(btn);
    }
    list.appendChild(div);
  }
}

main().catch(() => {});
