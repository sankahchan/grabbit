# Ghost Downloader 3 — Deep Review and Grabbit Adoption Plan

**Reviewed:** Ghost Downloader 3 (`XiaoYouChR/Ghost-Downloader-3`) at `e8cfeb1`, v4.4.5, 2026-10-23.  
**Baseline:** Grabbit v1.9.0 at `16cad3a`.  
**Scope:** HTTP engine, HLS/DASH + yt-dlp media, browser extension, aria2 RPC, Feature Packs.  
**Method:** static source review of GD3's `app/`, `features/`, and `browser_extension/` (about 25k lines) against Grabbit's Swift engines, extension, and native-messaging host. No runtime benchmarks were run.  
**License:** GD3 is GPL-3.0; Grabbit is MIT. This document records ideas and architecture only. No GD3 source was copied. Code sketches below are original.

> Line references are from the commits above and may drift. Paths beginning with `features/` or `app/` refer to the GD3 checkout; all other paths refer to Grabbit.

---

## TL;DR

| Area | GD3 does better | Grabbit does better | Verdict |
|---|---|---|---|
| **HTTP engine** | HTTP status retry taxonomy, mid-flight segment splitting, `bytes=1-1` probe with 416 handling, 1-second sidecar resume records | ETag/Last-Modified resume validation, 429/503 host learning + single-stream collapse, durable finalize journal, named queues, speed limiter | Adopt the retry/probe/split ideas; keep Grabbit's safety model. |
| **Streaming** | QuickJS-NG instead of Deno (~2 MB vs ~124 MB), clip ranges, live recording, audio-language selection, actionable error hints | Telegram/MSE capture, post-processing, a much simpler single-binary media path | Adopt QuickJS and the missing media features; do not add N_m3u8DL-RE. |
| **Browser extension** | Direct loopback WebSocket, pairing, protocol v2, live task snapshots/actions, draft mode, app-bundled CRX updates (dev installs) | Offline Inbox handoff, allow-listed native messaging, unique Telegram MSE capture | Add a loopback bridge for live control, keep native messaging for offline/stream capture. |
| **aria2 RPC** | Exposes a small aria2-compatible server so other apps can add downloads | Runs the real aria2-next daemon for torrents with ownership/session persistence | Low priority; a small HTTP-only facade is enough if users ask. |
| **Feature Packs** | Dynamic parsers, runtimes, settings, file types, URI schemes, per-pack UI | Native Swift type safety, notarization, no in-process arbitrary code | Adopt a provider registry and declarative site rules; do not port Python packs. |

### The five changes worth doing first

1. **Fix HTTP status handling (P0).** Today Grabbit fails immediately on `500/502/504/408/425`; only `429/503` get special treatment. Add a disposition table, a retry budget, `Retry-After`, `cf-mitigated`, and 416 re-probing.
2. **Harden the probe (P0).** Use a ranged `GET` (`bytes=1-1`, fallback `0-0`), trust `Content-Range` over `Content-Length`, handle `416 Content-Range: bytes */N`, and detect Cloudflare challenges during discovery.
3. **Replace Deno with QuickJS-NG (P0).** The vendored Deno 2.4.5 binary is **124 MB**; `qjs-darwin-arm64` v0.17.0 is **1.32 MB**. yt-dlp already supports `--js-runtimes quickjs:<path>`.
4. **Make media failures understandable (P1).** Map common yt-dlp stderr patterns to localized, actionable messages instead of showing the last stderr line.
5. **Close the media feature gap (P1).** Add clip ranges (`--download-sections`), live recording, audio-language selection, structured progress, and playlist handling.

### Do not copy

- **In-place writes into the final filename + binary `.ghd` record.** Grabbit's `.grabbit-part` + finalize journal is safer: an interrupted download never looks like a complete file, and a crash between move and persistence is recoverable.
- **Infinite 5-second retries.** GD3 retries every non-permanent error forever, including `500`, with the same concurrency. Use a bounded budget and backoff.
- **Uncapped reassign-on-completion.** GD3's `_reassignSubworker()` is not capped by `subworkerCount`; only `maxReassignSize` (512 KB) stops it. On a large file this can spawn far more connections than configured.
- **Python Feature Packs.** GPL, in-process arbitrary code, a Python runtime, and Qt UI coupling are all wrong for a notarized Swift app.
- **A full aria2 clone.** GD3's shim is only `getVersion`, `getGlobalOption`, `addUri`, and `system.multicall`; it returns a fake GID and cannot report status. A useful Grabbit facade needs more, and the demand is niche.

---

## 1. Scorecard

| Capability | GD3 | Grabbit | Gap for Grabbit |
|---|---|---|---|
| Direct HTTP downloads | Strong | Strong | Small |
| Range/resume correctness | Medium (total size only) | Strong (ETag/Last-Modified) | None |
| Transient-error recovery | Strong for 5xx, weak for 429 | Strong for 429/503, weak for 5xx | **P0** |
| Parallelism adaptation | Aggressive, uncapped | Capped, conservative | **P1** |
| Crash safety | Medium (direct file + `.ghd`) | Strong (partial + journal) | None |
| HLS/DASH VOD | Strong (N_m3u8DL-RE) | Good (yt-dlp) | Small |
| Live streams | Strong (N_m3u8DL-RE) | Basic (yt-dlp default) | **P1** |
| Clip downloads | Strong (byte-range header parser) | None | **P1** |
| Audio tracks | All languages | Best audio only | **P1** |
| Media runtime size | ~7 MB | ~154 MB (Deno + yt-dlp) | **P0** |
| Media error UX | Pattern-based hints | Last stderr line | **P1** |
| Browser live control | Strong | None | **P1** |
| Offline browser handoff | Weak (app must run) | Strong (Inbox + URL scheme) | None |
| Telegram/MSE capture | Partial (Cat Catch bridge) | Strong (native) | None |
| aria2 server compatibility | Limited | None (client only) | P2 |
| Extensibility | Very high, unsafe | Low, safe | P1/P2 |

---

## 2. HTTP Engine

### 2.1 How GD3 works

GD3 models every download as a `Task` with one or more `TaskStep`s. The HTTP pack (`features/http_pack/task.py`) is the core engine.

**Discovery.** The add path probes with `GET Range: bytes=1-1` (`features/http_pack/pack.py:97`). If the server answers `200` with a missing or 1-byte length, it falls back to `bytes=0-0` (`pack.py:115`). It accepts `200`, `206`, and `416` (`pack.py:86`), extracts the total from `Content-Range`, and treats `206 + Content-Range` as proof that ranges work (`pack.py:99-100`). The task itself probes again with `bytes=0-0` before starting (`task.py:381`).

**Segmentation and writes.** A ranged download is split into `subworkerCount` equal pieces (default 8, `task.py:66`). Each worker opens its own HTTP request and writes with `pwrite` at an absolute offset into the **final output file** (`task.py:261`, `342`). The file is preallocated with `ftruncate` (`task.py:418-422`). There is no merge step.

**Resume record.** A `<output>.ghd` sidecar stores 24-byte triples `(start, position, end)` for every worker (`task.py:93`, `96-118`). The supervisor rewrites it every second (`task.py:209-240`). On resume, the record is loaded and workers continue from `position`. There is no ETag/Last-Modified validation — only the total size is checked, and a changed size deletes the record (`pack.py:392-394`).

**Growth and splitting.** On every worker completion, `_reassignSubworker()` splits the worker with the largest remaining byte count, as long as at least `maxReassignSize` (default 512 KB) remains (`task.py:158-166`, `cfg.py:254-256`). Separately, `_autoSpeedUp()` watches five one-second speed samples; when the deviation is at most 15%, it adds four workers, waits five seconds, and compares the speed gain against the worker increase. If `speedRatio < 0.8 * workerRatio`, it disables further acceleration (`task.py:168-207`). This is a genuinely good idea: it stops opening connections that do not pay for themselves.

**Retries.** `PERMANENT_STATUS` is `{400, 401, 403, 404, 405, 410, 451}` plus any response with a `cf-mitigated` header (`task.py:19-20`, `252`, `289`, `330`). Everything else — including `500`, `502`, `504`, `408`, and `429` — is logged and retried after a flat five seconds, forever (`task.py:275-276`, `311-312`, `361-362`). A `200` to a ranged request downgrades the whole task to a single stream (`task.py:439-449`).

**Strengths:** simple, resumable without a merge, very tolerant of transient 5xx, and the auto-speedup benefit check is smarter than unconditional growth.  
**Weaknesses:** unbounded retries, no `Retry-After`, no ETag validation, and uncapped worker growth.

### 2.2 How Grabbit works

`DownloadEngine` (`Grabbit/Engine/DownloadEngine.swift`) is the direct HTTP engine.

- **Probe:** `HEAD` first; if it returns a plausible size (`> 1`), use it. Otherwise `GET Range: bytes=0-0` and require `206` (`DownloadEngine.swift:139-173`). It captures `ETag`, `Last-Modified`, `Content-Disposition`, and content type.
- **Segmentation:** equal split across `initialConnections = 8`, capped by `maxConnections` and a 1 MiB minimum piece (`DownloadEngine.swift:572-612`). It deliberately segments optimistically even when `Accept-Ranges` is absent, because many CDNs omit it on `HEAD` but honor ranges on `GET` (`DownloadEngine.swift:535-538`).
- **Transport:** one real HTTP/1.1 connection per segment (`SegmentTransport.swift`), not URLSession/HTTP/2, so parallel segments actually get separate TCP connections. Bytes are written at absolute offsets into `<destination>.grabbit-part`.
- **Resume integrity:** on resume, stored `ETag`/`Last-Modified` and the `Content-Range` total must still match, otherwise the download fails with "file changed on the server" (`DownloadEngine.swift:1380-1406`). Segment offsets are clamped to what is actually on disk (`DownloadItem.reconciledSegments`).
- **Throttling:** `429/503` with multiple segments collapses to one stream and remembers the host (`DownloadEngine.swift:1284-1292`); a single-stream `429/503` retries with exponential backoff up to four times (`1298-1324`). Many simultaneous segment errors halve the connection count (`1408-1442`, `1474-1535`); sustained low speed with multiple connections also halves it (`1576-1600`).
- **Growth:** on segment completion, split the largest **untouched** segment if at least 8 MiB remain and the count is below `maxConnections` (`DownloadEngine.swift:1333-1378`, `DownloadItem.growthSplitPoint`).
- **Retries:** five attempts per segment, exponential backoff for connect-phase failures, fast reconnect for mid-stream truncation (`DownloadEngine.swift:1408-1442`).
- **Crash safety:** a finalize journal is written before moving the partial file into place; `reconcileFinalizeJournals()` completes or retries the move after a crash (`DownloadEngine.swift:1085-1154`, `1681+`; `FinalizeJournal.swift`).
- **Queues and limits:** global active-task cap, named queues, per-host profiles, global + per-task token buckets.

### 2.3 Comparison

| Concern | GD3 | Grabbit |
|---|---|---|
| Probe | `GET bytes=1-1`, fallback `0-0`; accepts 200/206/416 | `HEAD`, then `GET bytes=0-0`; only 206 confirms |
| Total size source | `Content-Range` preferred | `Content-Length` from HEAD, then `Content-Range` |
| Resume validators | Total size only | ETag / Last-Modified + total |
| Write target | Final filename, `pwrite` | `.grabbit-part`, `pwrite` |
| Resume record | Binary `.ghd`, every 1 s | JSON state, every 5 s |
| Finalize | Delete `.ghd` | Journal + atomic move + launch reconciliation |
| Transient 5xx | Retry every 5 s forever | **Fail immediately** |
| 429/503 | Retry every 5 s at same concurrency | Collapse to one stream, learn host, backoff |
| Mid-flight split | Yes, largest remaining | **No**, only untouched segments |
| Growth cap | Not enforced | `maxConnections` |
| Speed-gain guard | Yes (80% rule) | No |
| Slowness downshift | No | Yes |
| Speed limit | Global | Global + per task + yt-dlp |

### 2.4 Findings and recommendations

#### H1 — HTTP status taxonomy and retry budget (P0)

**Problem.** `handleHTTPError` treats every status other than `429/503` as fatal (`DownloadEngine.swift:1259-1296`). A single `500`, `502`, `504`, `408`, or `425` kills the whole download even when the server would recover on the next attempt. Conversely, GD3's infinite retry is too aggressive.

**Proposed disposition table:**

| Status | Current Grabbit | Proposed |
|---|---|---|
| `400`, `401`, `404`, `405`, `451` | Fail | Permanent, actionable message |
| `403`, `410` on a signed URL | Expired-link hint | Keep; otherwise permanent |
| `403`, `410` otherwise | Fail | Permanent, suggest browser/cookies |
| `408`, `425` | Fail | Retry with backoff |
| `429` | Collapse + backoff | Collapse + honor `Retry-After` |
| `500`, `502`, `504` | Fail | Retry with budget |
| `503` | Collapse + backoff | Collapse + honor `Retry-After` |
| `416` | Fail | Re-probe total; restart if changed |
| `200` to a ranged request | Collapse | Keep |
| `cf-mitigated` present | Generic failure | Fail with a Cloudflare-challenge hint |
| Other `4xx` | Fail | Permanent |
| Other `5xx` | Fail | Retry with budget |

**Retry budget.** Prefer a per-download budget over a per-segment count: for example, 8 retryable failures or 5 minutes of retrying, whichever comes first, then move the task to `.failed` with a visible **Retry** action. This avoids both Grabbit's one-shot failure and GD3's infinite loop. Honor `Retry-After` (seconds or HTTP-date), cap it at 60 s, and add jitter.

**Sketch:**

```swift
enum HTTPDisposition {
    case retry(after: TimeInterval?)
    case collapse
    case revalidate
    case failPermanent(String)
    case failSignedURL
}

static func disposition(
    status: Int,
    headers: [String: String],
    isSignedURL: Bool
) -> HTTPDisposition {
    if headers["cf-mitigated"] != nil {
        return .failPermanent(NSLocalizedString("download.error.cloudflare", comment: ""))
    }
    // Only called for non-2xx responses; 200/206 are handled as success
    // or range-ignored before this point.
    switch status {
    case 416:              return .revalidate
    case 403, 410:         return isSignedURL ? .failSignedURL : .failPermanent("HTTP \(status)")
    case 400, 401, 404, 405, 451:
        return .failPermanent("HTTP \(status)")
    case 408, 425, 429, 500, 502, 503, 504:
        return .retry(after: retryAfter(headers["retry-after"]))
    default:
        return (400...499).contains(status)
            ? .failPermanent("HTTP \(status)")
            : .retry(after: nil)
    }
}
```

Wire this into `handleHTTPError`; keep the existing `throttledHosts.learn` and collapse path for `429/503`, but pass the `Retry-After` delay into `retryThrottled`.

**Tests:** local HTTP server endpoints that return `500` twice then `206`; `429` with `Retry-After: 2`; `416` with `Content-Range: bytes */N`; `200` to a range; `cf-mitigated: challenge`; signed URL `403`. Assert state transitions, retry counts, and elapsed delays with an injectable clock.

**Effort:** 1–2 days. **Risk:** low.

#### H2 — Probe hardening (P0)

**Problem.** Grabbit's probe only accepts `206` for the ranged fallback and ignores `416` (`DownloadEngine.swift:159-171`). It also never checks `cf-mitigated` during discovery, so a Cloudflare challenge looks like an ordinary failed download. GD3's `bytes=1-1` probe is a useful complement: it proves mid-file range support, not just byte 0, and avoids servers that special-case the first byte.

**Proposed order:**

1. `HEAD` (fast path). Accept a plausible `Content-Length > 1`; capture validators and `Accept-Ranges`.
2. `GET Range: bytes=1-1`. Require `206`; parse `Content-Range: bytes 1-1/N`. If `416`, parse `Content-Range: bytes */N` and treat the file as zero-length or revalidate.
3. `GET Range: bytes=0-0` as a fallback when `1-1` returns `200` with an unknown or 1-byte length.
4. If `HEAD` and ranged totals disagree, trust the ranged total.
5. Always send `Accept-Encoding: identity` (already done in `fetchHeaders`, `DownloadEngine.swift:294-300`).
6. Record `accept-ranges`, `content-range`, `content-type`, `content-disposition`, `etag`, `last-modified`.

**Why `1-1` first?** Some servers return a full `200` for `0-0` but honor `1-1`; others return a one-byte body that is indistinguishable from a probe artifact. `1-1` also catches servers that only support ranges above byte 0 (rare, but real).

**Sketch:**

```swift
enum ProbeOutcome {
    case success(ProbeResult)
    case rangeIgnored
    case cloudflare
    case none
}

private func rangedProbe(
    _ url: URL, range: String, ...
) async -> ProbeOutcome {
    guard let (status, fields) = await fetchHeaders(
        url, method: "GET", range: range, ...) else { return .none }
    if fields["cf-mitigated"] != nil { return .cloudflare }

    switch status {
    case 206:
        var r = ProbeResult()
        applyProbeHeaders(&r, headers: fields)
        r.totalBytes = r.totalBytes
            ?? fields["content-range"].flatMap(DownloadItem.totalFromContentRange)
        return .success(r)
    case 416:
        var r = ProbeResult()
        applyProbeHeaders(&r, headers: fields)
        r.totalBytes = fields["content-range"].flatMap(DownloadItem.totalFromContentRange)
        return .success(r)
    case 200:
        return .rangeIgnored
    default:
        return .none
    }
}
```

**Tests:** `206` with total; `416` with `*/123`; `200` to `1-1` then `206` to `0-0`; `cf-mitigated`; zero-length file; `Content-Length` vs `Content-Range` mismatch.

**Effort:** 0.5–1 day. **Risk:** low.

#### H3 — Mid-flight split and growth benefit guard (P1)

**Problem.** Grabbit only splits **untouched** segments when another segment completes (`growthSplitPoint`). If the last unfinished segment is slow, the download can sit at one connection for minutes while the other connections are idle. GD3 splits the largest remaining segment, including an in-flight one.

**Proposed:**

- Every 10 s, if `segments.count < maxConnections`, find the incomplete segment with the largest remaining bytes. If it has at least 8 MiB left, split it at the midpoint.
- Stop the old transport at the new end and restart it from its current offset; start a new segment at the midpoint.
- Add a hard cap at `maxConnections` (do not copy GD3's uncapped reassign).
- Add a growth benefit guard: when growth first starts, record `(connectionCount, 5 s average speed)`. After 5 s, compute `workerRatio` and `speedRatio`; if `speedRatio < 0.5 * workerRatio`, disable further growth for this download. GD3 uses `0.8`; `0.5` is deliberately more conservative.
- Put the mid-flight split behind a setting (`Adaptive segment splitting`, default off for one release) and log split/gain metrics.

**Sketch:**

```swift
private func splitLargestRemaining(id: UUID, generation: Int) {
    guard isCurrentGeneration(id: id, generation: generation),
          let i = items.firstIndex(where: { $0.id == id }),
          items[i].state == .downloading,
          let transport = transports[id],
          items[i].segments.count < maxConnections
    else { return }

    let candidates = items[i].segments.filter {
        !$0.isComplete && $0.endByte != .max && $0.byteCount - $0.receivedBytes >= Self.growthMinSplitBytes
    }
    guard let target = candidates.max(by: { ($0.byteCount - $0.receivedBytes) < ($1.byteCount - $1.receivedBytes) })
    else { return }

    let oldEnd = target.endByte
    let remaining = oldEnd - (target.startByte + target.receivedBytes) + 1
    let mid = target.startByte + target.receivedBytes + remaining / 2
    guard mid > target.startByte + target.receivedBytes, mid <= oldEnd else { return }

    transport.cancelSegment(index: target.index)
    items[i].segments[target.index].endByte = mid - 1
    let newIndex = (items[i].segments.map(\.index).max() ?? -1) + 1
    items[i].segments.append(Segment(index: newIndex, startByte: mid, endByte: oldEnd))
    pendingSegments[id, default: 0] += 1
    // restart the original segment at its current position, and start the new one
    restartSegment(id: id, index: target.index)
    startSegment(id: id, index: newIndex, start: mid, end: oldEnd)
    persistItem(id: id)
}
```

`SegmentTransport` needs `cancelSegment(index:)` and a restart helper. The existing `writeCount` clamping already prevents the old transport from writing past the new end, but cancelling avoids wasting bandwidth.

**Risk:** a reconnect costs a TCP/TLS handshake; on high-latency or rate-limited servers, splitting can reduce total speed. The benefit guard and the feature flag are the mitigation. Do not enable it by default until it has been measured on at least a dozen hosts.

**Tests:** a local server that delays one segment by 5 s; assert the tail is split and total time improves; a server that throttles per connection; assert growth stops when the gain is poor; a 1 GB file with `maxConnections = 8`; assert no more than 8 active segments.

**Effort:** 2–3 days. **Risk:** medium.

#### H4 — One-second resume cadence (P2)

Grabbit autosaves every 5 s (`DownloadEngine.swift:122`); GD3 rewrites `.ghd` every 1 s. At 100 MB/s, 4 s of lost progress is 400 MB. But 1 s JSON writes for every item are wasteful.

**Proposed:** keep the 5 s full JSON cadence, and add a small per-task sidecar (or an in-memory snapshot flushed every 1 s) for **active** downloads only. Use atomic replace; no `fsync` needed. Alternatively, make the interval adaptive: 1 s while speed > 10 MB/s, 5 s otherwise.

**Effort:** 0.5–1 day. **Risk:** low. Do this only if users report large re-downloads after a crash.

#### H5 — TLS fingerprint / browser profiles (P2 research)

GD3 uses `wreq` with browser TLS profiles (Chrome, Edge, Firefox, Safari, OkHttp) and per-host client profiles (`app/client.py`, `cfg.py:325`). Grabbit uses `NWConnection`, so its TLS ClientHello is Apple's, not Chrome's; a spoofed User-Agent is not enough for JA3/JA4-sensitive hosts.

**Recommendation:** do not implement now. Run a research spike: collect 20–30 URLs that fail in Grabbit with `403`/connection resets but work in a browser, and check whether the cause is TLS fingerprinting or missing cookies/headers. If the failure rate is material, evaluate a `curl-impersonate` sidecar or a BoringSSL-based transport. Both are large changes and would bypass the current HTTP/1.1 range engine.

**Effort:** 1 week research. **Risk:** high.

#### H6 — Explicitly skip

- **Direct final-file writes.** Grabbit's `.grabbit-part` prevents a partial file from looking complete and makes the finalize journal meaningful. Keep it.
- **Binary `.ghd`.** JSON is debuggable, atomic, and already stores per-segment offsets. A binary format is not worth the migration.
- **Infinite retries.** Use the budget in H1.

---

## 3. Streaming (HLS / DASH / yt-dlp)

### 3.1 How GD3 works

**M3U8 pack.** `M3U8Parser` has priority 80 and matches `.m3u8`, `.m3u`, and `.mpd` URLs (`features/m3u8_pack/pack.py:32-38`). It fetches the manifest with the task's headers, parses HLS with `m3u8` and DASH with `mpegdash`, lists video/audio/subtitle streams, and detects live playlists via `is_endlist` (`pack.py:78-110`). It then shells out to **N_m3u8DL-RE** with a large argument list: thread count, retries, timeout, concurrent download, binary merge, subtitle format, decryption engine, keys, live flags (`--live-real-time-merge`, `--live-keep-segments`, `--live-record-limit`), and ffmpeg muxing (`features/m3u8_pack/task.py:198-282`). It parses both VOD and live progress lines (`task.py:25-29`, `311-316`) and maps common errors to user-facing hints (`task.py:37-62`).

**yt-dlp pack.** The pack is YouTube-only (`allowed_extractors=['youtube']`, `features/yt_dlp_pack/task.py:54-66`). It uses yt-dlp as an **extract-only library**: `extract_info(url, download=False)` returns solved stream URLs, then GD3 downloads the video and audio tracks through its own HTTP engine and merges them with ffmpeg. It installs a QuickJS-NG `qjs` binary (~2 MB) instead of Deno (~100 MB), per ADR 0007. It supports:

- multiple audio languages, merging all selected tracks (`task.py:187-203`, `503-534`);
- clip ranges by parsing the MP4/WebM header and computing byte ranges, then patching the container header (`task.py:411-454`);
- URL refresh on resume: if a stream URL is near expiry, re-extract before continuing (`task.py:396-409`);
- playlists as N independent tasks (`task.py:89-96`, `209+`).

**Strengths:** live recording, clip ranges, audio languages, URL refresh, and a tiny JS runtime.  
**Weaknesses:** N_m3u8DL-RE is another binary; the MP4/WebM header parser is complex and codec-specific; the pack is Python and GPL.

### 3.2 How Grabbit works

`MediaProbe` runs `yt-dlp -J` and builds presets by height (best, 2160p…360p, video-only, audio MP3/M4A/original) (`Grabbit/Engine/MediaProbe.swift:144-227`). `MediaEngine` runs `yt-dlp -f <preset>` with `--newline --no-playlist --continue`, parses `[download] N%`, and post-processes metadata/thumbnail/chapters/subtitles (`Grabbit/Engine/MediaEngine.swift:142-257`). Deno is injected into `PATH` for YouTube's JS challenges (`MediaRuntimeResolver`, `scripts/vendor-media-runtime.sh`).

Routing is hard-coded: only YouTube, X, TikTok, Instagram, Telegram, and URLs containing `.m3u8`/`.mpd` go to the media engine (`Grabbit/UI/Views/AddDownloadSheet.swift:248-259`, `371-386`; `Grabbit/GrabbitApp.swift:268-284`). Everything else goes to the HTTP engine. There is no clip UI, no live-record UI, no audio-language picker, and `--no-playlist` is unconditional. Errors show only the last stderr line (`MediaEngine.swift:245-255`).

Grabbit's unique strength is browser-side **MSE/Telegram capture**: `page-hook.js` mirrors `SourceBuffer.appendBuffer`, the helper writes chunks to the Inbox, and the app muxes video + audio with ffmpeg (`ARCHITECTURE.md`, `GrabbitExtension/content.js:309+`). GD3 only has a Cat Catch bridge for this.

### 3.3 Comparison

| Capability | GD3 | Grabbit |
|---|---|---|
| HLS/DASH VOD | N_m3u8DL-RE | yt-dlp + ffmpeg |
| Live recording | Yes, real-time merge, record limit | yt-dlp default live behavior, no UI |
| Clip ranges | Yes, byte-range header parser | No |
| Audio languages | All selected tracks | Best audio only |
| Playlists | N tasks | `--no-playlist` always |
| JS runtime | QuickJS-NG ~2 MB | Deno ~124 MB |
| Error messages | Pattern-based hints | Last stderr line |
| Progress | Per-step / per-track | Percent only |
| Resume | URL refresh + `.ghd` | yt-dlp `--continue` |
| Telegram/MSE | Cat Catch bridge | Native capture |
| App size impact | Small | Large |

### 3.4 Findings and recommendations

#### M1 — Replace Deno with QuickJS-NG (P0)

**Numbers.** The vendored Deno 2.4.5 binary is **124 MB** on disk (`/opt/homebrew/bin/deno`; the release artifact is similar). QuickJS-NG v0.17.0 publishes `qjs-darwin-arm64` at **1.32 MB** and `qjs-darwin-x86_64` at **1.23 MB**. That is roughly a **123 MB** reduction in the app/DMG, before compression.

**yt-dlp support.** yt-dlp 2026.08.19 (the pinned version in `scripts/vendor-media-runtime.sh`) supports:

```text
--js-runtimes RUNTIME[:PATH]
--no-js-runtimes
```

The CLI accepts `quickjs:<path>`. Because Deno has higher priority when both are available, force QuickJS with:

```bash
yt-dlp --no-js-runtimes --js-runtimes "quickjs:/path/to/qjs" ...
```

The official `yt-dlp_macos` executable bundles the EJS components, so `--remote-components` is not required. Verify this on the pinned build before shipping.

**Changes:**

1. `scripts/vendor-media-runtime.sh`: replace `DENO_VERSION` with `QJS_VERSION`; download `qjs-darwin-arm64` (and `qjs-darwin-x86_64` for the Intel roadmap); `chmod +x`; sign.
2. `MediaRuntimeResolver.Component`: rename `.deno` to `.quickJS`; resolve `qjs`; keep a `DENO_PATH` override for one release.
3. `MediaProbe.childEnvironment` / `MediaEngine` arguments: add `--no-js-runtimes --js-runtimes quickjs:<path>`; do not inject Deno into `PATH` anymore.
4. `MediaComponentUpdater`: optionally update `qjs` on the same cadence as yt-dlp; at minimum, pin and verify the checksum.
5. `DEPENDENCIES.md` / `THIRD-PARTY-LICENSES.md`: QuickJS-NG is MIT; remove Deno.
6. Keep a hidden fallback: if yt-dlp fails with a JS-runtime error and a Deno binary is still present, retry once with Deno. Remove the fallback after one release.

**Test matrix:** standard YouTube video, age-gated video with `cookies.txt`, live stream, playlist, Shorts, YouTube Music, a video requiring signature/n-challenge, and a non-YouTube yt-dlp site. Compare success rate and speed against Deno.

**Effort:** 1–2 days plus QA. **Risk:** low–medium (yt-dlp/qjs compatibility; mitigated by the fallback).

#### M2 — Actionable media error mapping (P1)

Grabbit currently surfaces `result.stderrTail.split(separator: "\n").last` (`MediaEngine.swift:246`). That is usually a fragment like `ERROR: [youtube] abc: Video unavailable`, which is not actionable.

**Proposed mapping** (keep the raw stderr in a details disclosure and the log):

| Pattern | User-facing message (en) |
|---|---|
| `HTTP Error 403` | The site refused the request (403). Try importing cookies or opening the page in your browser first. |
| `HTTP Error 404` | The video was not found or has been removed. |
| `Sign in to confirm you're not a bot` | YouTube wants a sign-in check. Import a `cookies.txt` or use the browser extension. |
| `This video is DRM protected` | This video is DRM-protected and cannot be downloaded. |
| `Requested format is not available` | That quality is no longer available. Re-probe the link. |
| `Unable to extract` | The extractor failed. Update yt-dlp and try again. |
| `ffmpeg not found` / `ffprobe not found` | The media runtime is missing. Reinstall Grabbit or the media components. |
| `Unsupported URL` | This is not a supported media page. |
| `Live event will begin` | The live event has not started yet. |
| `The uploader has not made this video available` | The uploader restricted this video in your region. |

Add both `en` and `my` strings to `Localizable.xcstrings`. Keep a `details` field with the raw line for bug reports.

**Effort:** 0.5 day. **Risk:** low.

#### M3 — Structured progress and ETA (P1, cheap)

The current regex only reads `[download] N%`. Add a machine-readable progress template:

```bash
--progress-template "download:GRABBIT:%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.speed)s|%(progress.eta)s"
```

Parse the `GRABBIT:` line into bytes/total/speed/ETA and show a real ETA and speed in the media card. This also makes tests deterministic.

**Effort:** 0.5 day. **Risk:** low.

#### M4 — Clip ranges (P1)

Add optional start/end fields to the media add sheet (and a "Clip" action on completed media). Validate `0 <= start < end`; pass:

```bash
--download-sections "*00:01:30-00:02:45"
```

For HLS/DASH, yt-dlp downloads only the relevant fragments. For progressive files, ffmpeg cuts at keyframes; offer `--force-keyframes-at-cuts` only when the user asks for an exact cut (it re-encodes and is slower). Name the output with a suffix such as `[00-01-30--00-02-45]`.

Do **not** port GD3's MP4/WebM header byte-range parser. It is a large, codec-specific subsystem, and `--download-sections` covers the common cases.

**Effort:** 1–2 days. **Risk:** low.

#### M5 — Live recording (P1)

`yt-dlp -J` exposes `is_live`. Add a "Record live" toggle and a Stop button:

- `--live-from-start` for YouTube (records from the beginning if available).
- `--wait-for-video 10` for scheduled streams.
- Keep `--continue` and `.part` files for crash recovery.
- Parse `[download]` progress; live streams have no total, so show elapsed time, downloaded bytes, and speed instead of a percentage.
- Check free disk space before starting and warn when it drops below a threshold.
- On Stop, terminate the process group and let yt-dlp finalize the container.

Do not add N_m3u8DL-RE just for live; yt-dlp already handles HLS/DASH live. If a specific host fails, revisit.

**Effort:** 1–2 days. **Risk:** medium (live edge cases).

#### M6 — Audio-language selection (P1)

`yt-dlp -J` includes `language` and `language_preference` on audio formats. Extend `MediaProbe`:

```swift
struct AudioTrack: Identifiable {
    let id: String          // language code or "original"
    let label: String       // "English", "Japanese", …
    let isOriginal: Bool
    let formatID: String?
}
```

Build a picker; default to the original track (`language_preference >= 10`). Format spec:

```text
bv*+ba[language=fr]/bv*+ba/b
```

Remember the preferred language per site. For multiple audio tracks in one file, add `--audio-multistreams` and an MKV container as a separate P2 option.

**Effort:** 1 day. **Risk:** low.

#### M7 — Playlists (P2)

`--no-playlist` is hard-coded (`MediaEngine.swift:177`). Add:

- Probe with `--flat-playlist -J` to detect a playlist and list entries.
- UI: "This is a playlist — download first video / all / range".
- Download with `--yes-playlist`; enqueue each entry as its own task; naming template `%(playlist_index)02d - %(title)s`.
- Cap the number of concurrent media tasks and warn for very large playlists.

**Effort:** 2–3 days. **Risk:** medium (queue integration).

#### M8 — Per-track media engine (P2, only if needed)

GD3 downloads video and audio as separate HTTP tasks, which gives per-track progress, resume, and clip control. Grabbit delegates all of that to yt-dlp. Rebuilding it in Swift is a multi-week project and would duplicate yt-dlp's format selection.

**Recommendation:** don't do it now. If per-track control becomes a product requirement, start with a narrow case (YouTube only) and reuse `DownloadEngine` for each track, then merge with ffmpeg. The existing `MediaEngine` remains the fallback.

#### M9 — Explicitly skip

- **N_m3u8DL-RE.** Another binary, another updater, another set of flags; yt-dlp + ffmpeg already covers VOD and live. Revisit only if a must-support host fails.
- **A custom manifest parser.** `yt-dlp -J` already parses HLS/DASH and returns formats; a Swift parser would duplicate it.
- **GD3's header byte-range clipper.** Too complex for the benefit.

---

## 4. Browser Extension

### 4.1 How GD3 works

GD3's extension connects directly to the app over `ws://127.0.0.1:14370` (`browser_extension/app/src/shared/constants.ts`). The protocol is version 2 (`app/services/browser_service.py:90`) and has a real handshake:

- `pair_request` / `pair_result`: the app shows a pairing request; the user approves it.
- `hello` with `protocolVersion`, `token`, `extensionVersion`, `installType`; the app replies with `hello_ack`, `appVersion`, and `capabilities` (`browser_service.py:408-446`).
- `subscribe_tasks` → `task_snapshot` with a list of task summaries; snapshots are sent on change and deduplicated (`browser_service.py:336-345`).
- `create_task` with a payload, source, title, and `draft` flag; the result is `created`, `drafted`, or `rejected` (`browser_service.py:458-516`).
- `task_action` with `toggle_pause`, `cancel`, `remove`, `redownload`, `open_file`, `open_folder` (`browser_service.py:68-75`, `519-575`).
- The app bundles a CRX; for development installs it extracts a newer version and tells the extension to reload (`browser_service.py:438-446`). Store installs are updated by the browser.

The popup is a full remote control: Tasks, Resources, Images, Advanced, Settings; media actions include play/pause, speed, PiP, screenshot, loop, mute, volume, seek, fullscreen (`shared/types.ts`). It also integrates Cat Catch for media sniffing/recording.

**Security:** the server binds loopback and requires the pairing token, but there is **no Origin check** in `browser_service.py`. The token is the only gate. That is acceptable for a local app but should not be copied as-is.

### 4.2 How Grabbit works

Grabbit uses Chrome native messaging:

1. The extension calls `chrome.runtime.connectNative("com.sankahchan.grabbit")` (`GrabbitExtension/background.js:73-106`).
2. The installed host is a Python helper (`GrabbitExtension/native-messaging/grabbit-native-helper.py`), not the app binary. The helper handles `grab`, `stream-init/chunk/finalize/cancel`, and `import`.
3. For a grab, the helper writes a payload JSON (URL + headers) to `~/Library/Application Support/Grabbit/Inbox/` and opens `grabbit://download?payload=<file>`; the app parses the payload, deletes it, and adds the download.
4. For a stream capture, the helper writes chunks to `Inbox/part-*.part` and a `meta-<captureId>.json` sidecar; finalize assembles the file(s) and opens `grabbit://import`.
5. Every message is ACKed with `{"type":"ack","id":…,"ok":…}` for backpressure.

The app also has a `--native-messaging` mode (`NativeMessagingHost.swift`, `GrabbitApp.swift:339-357`), but the installer points the browser at the Python helper (`NativeHostInstaller.swift:113-116`). The helper exists so the browser can hand off work even when the app is not running, and so stream chunks survive MV3 worker recycling.

**Strengths:** offline handoff, allow-listed extension IDs, Inbox path containment, and the Telegram/MSE capture pipeline.  
**Weaknesses:** no app→extension push, no live task list, no actions, and a Python 3 dependency that is not guaranteed on a clean macOS install.

### 4.3 Comparison

| Concern | GD3 | Grabbit |
|---|---|---|
| Transport | Direct WebSocket, loopback | Native messaging via Python helper |
| App must be running | Yes | No (Inbox + URL scheme) |
| Live task state | Snapshots | None |
| Pause/cancel/open actions | Yes | None |
| Pairing | Request/approve + token | Extension-ID allow-list |
| Offline queue | No | Yes |
| Helper runtime | None (app server) | Python 3 |
| Extension update | App-bundled CRX (dev installs) | GitHub ZIP + in-app updater |
| Media capture | Cat Catch bridge | Native MSE/Telegram |
| Popup scope | Tasks/resources/images/advanced | Detected media + grab |

### 4.4 Findings and recommendations

#### B1 — Loopback bridge for live control (P1)

**Goal:** let the extension see and control running downloads without giving up the existing offline handoff.

**Architecture:**

- Add a `BrowserBridgeServer` in the app, bound to `127.0.0.1` on a configurable port (default 14370, with conflict fallback).
- Protocol: WebSocket if the server-side implementation is reasonable; otherwise HTTP + Server-Sent Events (SSE) for snapshots and `POST` for actions. The extension already runs a service worker, so both are workable. A WS implementation gives GD3-compatible semantics; SSE is simpler to build with `NWListener`.
- Keep native messaging for `grab`/`stream-*`/`import`. The bridge is additive: live control when the app is running, offline queue when it is not.
- Handshake: `hello` with protocol version, extension version, and token; reply with `hello_ack`, app version, and capabilities.
- Token: 32 random bytes, generated at first launch, stored in the Keychain, displayed as a pairing code in Settings. Rotate on demand.
- Origin allow-list: exact `chrome-extension://<id>` origins for the two known IDs; reject `null`, `file://`, and unknown origins.
- Bind loopback only; never `0.0.0.0`.
- Message size cap (1 MB), JSON schema validation, rate limiting, and close-on-violation.

**Security checklist:**

- [ ] Origin allow-list, not just a token.
- [ ] Token in the `Authorization` header or first WS frame, never in the URL.
- [ ] No wildcard CORS. Echo only allowed origins.
- [ ] Host header check to block DNS rebinding.
- [ ] Task IDs are opaque; never accept paths from the extension.
- [ ] `open_file` only for completed tasks; `open_folder` only for existing directories.
- [ ] Snapshots never include cookies, headers, or full filesystem paths.
- [ ] Auth failures are rate-limited and logged without the token.
- [ ] Protocol version mismatch closes the connection with a clear error.

**Effort:** 5–10 days (WS server + protocol + tests + security review). **Risk:** high; do a short spike first to choose WS vs SSE.

#### B2 — Task snapshots and actions (P1)

Define a compact DTO:

```swift
struct BrowserTaskSummary: Codable {
    let id: String
    let name: String
    let status: String        // queued/downloading/paused/completed/failed
    let progress: Double
    let receivedBytes: Int64
    let totalBytes: Int64?
    let speed: Int64
    let eta: Int?
    let canPause: Bool
    let canOpenFile: Bool
    let canOpenFolder: Bool
    let fileExt: String
    let source: String        // http/media/torrent
}
```

- Send a full snapshot on subscribe and on every change, debounced to 200 ms.
- Add a monotonically increasing `sequence` so the extension can detect gaps.
- Actions map to `DownloadEngine` methods: `pause`, `resume`, `cancel` (delete files), `remove` (keep files), `redownload`, `openFile`, `openFolder`.
- Start with HTTP downloads; add media and torrents after the protocol is stable.
- Make actions idempotent: repeating `pause` on a paused task returns success, not an error.

**Effort:** 2–3 days after B1. **Risk:** medium.

#### B3 — Replace the Python helper with a signed Swift helper (P2)

The Python helper is a reliability and security liability:

- macOS does not guarantee a system Python 3 on a clean install.
- The helper is a script in Application Support, outside the app bundle's signature.
- It duplicates logic that could live in a small Swift CLI.

**Proposed:** add a `GrabbitNativeHelper` command-line target (Swift) that speaks the same native-messaging protocol, writes the same Inbox payloads, and talks to the app over a Unix domain socket or XPC for live state. Build it in `project.yml`, sign it with the app, install it via `NativeHostInstaller`, and keep the Python helper as a fallback for one release.

If B1 lands, the helper's live-control role shrinks; it still owns offline grabs and stream chunks.

**Effort:** 3–5 days. **Risk:** medium (new target, signing, notarization).

#### B4 — App-bundled extension auto-update (P2)

Grabbit already has a one-click extension updater from the Grabber tab (v1.6.0). GD3 goes further for development installs: the app bundles a CRX, extracts it, and asks the extension to reload.

**Proposed:**

- Ship `GrabbitExtension.zip` inside the app bundle.
- On launch, compare the bundled version with `~/Library/Application Support/Grabbit/Extension/<version>`; extract if newer.
- For unpacked installs, the extension checks the app's version over the bridge and calls `chrome.runtime.reload()` after the app writes the new files.
- For store installs, do nothing; the store handles updates.
- Show "Extension update available" in the popup when the app is newer.

Chrome does not allow silent updates of unpacked extensions without a reload, so be explicit in the UI.

**Effort:** 2–3 days. **Risk:** medium (Chrome policy/behavior).

#### B5 — Popup Tasks tab (P2)

Once B1/B2 exist, add a Tasks tab to the popup: active/completed filters, progress bars, speed/ETA, pause/cancel/open actions, and a badge with the active count. This is the most visible payoff of the bridge and matches GD3's best UX feature.

**Effort:** 2 days. **Risk:** low.

#### B6 — Keep the Telegram/MSE capture (do not regress)

GD3's Cat Catch bridge covers more media sources, but Grabbit's native MSE capture is deeper for Telegram restricted channels: it mirrors `SourceBuffer.appendBuffer`, handles separate video/audio tracks, and muxes them on import. Add regression tests for `stream-init/chunk/finalize/cancel` and the meta sidecar before changing the helper.

#### B7 — Explicitly skip

- **Full remote media control** (PiP, screenshot, playback speed, screen/WebRTC recording). It is scope creep for a downloader and would expand the extension's permissions and attack surface.
- **A CRX-only distribution path.** Grabbit is outside the Chrome Web Store; the Edge Add-ons listing is the realistic store path. Keep the ZIP + unpacked flow.

---

## 5. aria2 RPC

### 5.1 How GD3 works

GD3 runs a ~253-line loopback JSON-RPC server (`app/services/aria2_rpc.py`). It supports HTTP POST and WebSocket upgrade (`aria2_rpc.py:122-129`), CORS `*` (`57`), and a token check that is optional because `aria2RpcToken` defaults to empty (`cfg.py:277`). Methods:

- `aria2.getVersion` → `{version, enabledFeatures: ["HTTPS"]}`
- `aria2.getGlobalOption` → `{dir}`
- `aria2.addUri` → parses the URL and adds a task; returns a random 16-hex GID
- `system.multicall`

There is no `tellStatus`, `pause`, `unpause`, `remove`, or `getGlobalStat`. The GID is fake, so a client cannot track the task. It is a compatibility shim for "add URL" integrations, not a real aria2 endpoint.

### 5.2 How Grabbit works

Grabbit bundles **aria2-next** and manages it as a torrent daemon:

- `Aria2Daemon` writes an ownership manifest with PID, binary path, RPC port, random start signature, and a 32-byte secret; it reclaims or evicts stale daemons (`Aria2Daemon.swift`).
- `Aria2RPC` is an outbound client: `addUri`, `tellStatus`, `getVersion`, etc., with `token:<secret>` auth (`Aria2RPC.swift`).
- The daemon listens on loopback only (`--rpc-listen-all=false`) with a random per-start secret (`Aria2Daemon.swift:269-280`).
- Torrent session persistence, metadata, and info-hash reconciliation are implemented.

This is **more robust than GD3's shim** for torrents, but Grabbit does not expose an aria2-compatible server for HTTP downloads.

### 5.3 Comparison

| Concern | GD3 | Grabbit |
|---|---|---|
| Role | Server shim | Client of a managed real daemon |
| Scope | HTTP add only | Torrents (full aria2) |
| Methods | 3 + multicall | Client supports many |
| GID | Fake | Real aria2 GID |
| Status/pause/remove | No | Yes, for torrents |
| Auth | Optional token | Random secret, always |
| CORS | `*` | N/A (loopback client) |
| Persistence | Task service | aria2 session + Grabbit records |

### 5.4 Findings and recommendations

#### A1 — HTTP-only aria2 facade (P2)

**When:** only if users ask for interoperability with Motrix, Aria2 for Chrome, or automation scripts. Grabbit's own extension covers the common case.

**Scope:**

- Loopback HTTP JSON-RPC; optional WebSocket later.
- Required token (do not make it optional).
- Methods: `aria2.getVersion`, `aria2.getGlobalOption`, `aria2.addUri`, `aria2.tellStatus`, `aria2.tellActive`, `aria2.tellWaiting`, `aria2.tellStopped`, `aria2.pause`, `aria2.unpause`, `aria2.remove`, `aria2.purgeDownloadResult`, `aria2.getGlobalStat`, `system.multicall`.
- GID: derive a stable 16-hex ID from the `DownloadItem` UUID; keep a map for the process lifetime.
- Status mapping: `active` (downloading), `waiting` (queued), `paused`, `complete`, `error`, `removed`.
- Options: `dir`, `out`, `header`, `referer`, `user-agent`, `split`, `max-connection-per-server`, `continue`. Ignore unsupported options with a warning, or reject with aria2 error code 1.
- Do **not** proxy torrents initially; mixing two namespaces is confusing. Document that the facade is HTTP-only.

**Security:** bind `127.0.0.1`, require the token, check `Origin`, cap the body size, rate-limit, and restrict `dir` to user-approved roots (or require a confirmation for a new root). A local aria2 endpoint that accepts arbitrary `dir` is a filesystem-write primitive for any local process.

**Effort:** 3–5 days. **Risk:** medium.

#### A2 — Explicitly skip

- **A full aria2 clone** (BitTorrent, ED2K, metalink, session control). Grabbit already has a real aria2 for torrents; reimplementing it is pointless.
- **GD3's fake-GID shim.** Returning a GID that cannot be queried is worse than rejecting the call.

---

## 6. Feature Packs

### 6.1 How GD3 works

A Feature Pack is a Python package with a `manifest.toml`:

```toml
[pack]
entry = "pack.py"
class = "HttpPack"
dependencies = []
version = "1.1.5"
gdMinVersion = "4.4.4"
```

`PackManifest.fromDir` validates the entry, class, dependencies, version, and minimum app version (`app/models/pack.py:195-262`). `loadPacks` sorts packs by dependency order (`app/loader.py:44-96`), imports the entry module with `importlib`, and instantiates the class (`loader.py:107-133`). `seedPacks` copies bundled packs into the user pack directory when the seed version is newer (`loader.py:17-41`).

A pack can contribute:

- **Parsers** with a priority and `match`/`matchPassive` (`app/models/pack.py:40-57`). The HTTP pack is priority 100, BitTorrent 85, M3U8 80, yt-dlp 70, Bilibili 50, etc.
- **Task/draft cards, option cards, edit cards, detail cards** (Qt widgets) (`pack.py:280-293`).
- **Runtimes** (binaries with version/install/update) (`pack.py:154-177`).
- **File types and URI schemes** (`pack.py:298-302`).
- **Pages** (`pack.py:304`).
- **Pack-specific settings** via `PackConfig` (`pack.py:59-110`).

Packs include HTTP, M3U8, yt-dlp, ffmpeg, BitTorrent, FTP, ED2K, GitHub, HuggingFace, and Bilibili. This is how GD3 adds protocols and sites quickly.

**Strengths:** high extensibility, per-pack UI/settings, runtime management, dependency ordering.  
**Weaknesses:** in-process arbitrary Python with no sandbox or signing; Qt UI coupling; a Python runtime; GPL; the public plugin API is still on the roadmap.

### 6.2 How Grabbit works

Grabbit is native Swift with no plugin system. Routing is hard-coded in `AddDownloadSheet` and `GrabbitApp`; site detection is a chain of `contains` checks (`AddDownloadSheet.swift:371-386`); media vs HTTP is a boolean (`isMediaSite`); torrents and magnets have separate paths. Adding a site or protocol requires an app release.

**Strengths:** type safety, notarization, no arbitrary code, one build system.  
**Weaknesses:** routing is scattered; no declarative rules; no way for users to add a niche site without a release.

### 6.3 Comparison

| Concern | GD3 | Grabbit |
|---|---|---|
| Language | Python, in-process | Swift, compiled |
| Isolation | None | N/A (no plugins) |
| Manifest | `manifest.toml` with deps/version | None |
| Parsers | Priority + active/passive match | Hard-coded if/else |
| UI extension | Qt cards/pages | None |
| Runtimes | Pack-managed binaries | Fixed vendored binaries |
| File types / URI schemes | Pack-declared | Hard-coded |
| Updates | Seed sync + per-pack versions | App releases |
| Security | Arbitrary code | Strong |
| Licensing | GPL-3.0 | MIT |

### 6.4 Findings and recommendations

#### P1 — Provider registry (P1)

**Goal:** get GD3's parser-priority idea without dynamic code. One place decides which engine handles a request, with explicit capabilities and testable precedence.

**Design:**

```swift
struct DownloadRequest {
    let url: URL
    let headers: [String: String]
    let suggestedFilename: String?
    let sourcePageURL: URL?
}

enum ProviderMatch {
    case active(DownloadPlan)     // provider is confident; use it
    case passive(DownloadPlan)    // provider can handle it; offer as an option
    case none
}

protocol DownloadProvider {
    var id: String { get }
    var priority: Int { get }
    var capabilities: ProviderCapabilities { get }
    func match(_ request: DownloadRequest) async -> ProviderMatch
}
```

- `ProviderRegistry` sorts by priority, runs active matches first, and exposes passive matches to the UI.
- Built-ins: `HTTPProvider` (100), `TorrentProvider` (90), `TelegramProvider` (85), `MediaProvider` (80), `FTPProvider` later.
- Move `detectSourceSite`, `isMediaSite`, and the URL-scheme routing out of `AddDownloadSheet`/`GrabbitApp` into providers.
- **Unknown HTML fallback:** if `HTTPProvider` probes a URL and gets `text/html`, return a passive match from `MediaProvider`; the add sheet offers "Download as media" if `yt-dlp -J` recognizes it. This fixes the current dead end for Vimeo, Facebook, Reddit, SoundCloud, and other yt-dlp-supported sites without hard-coding every host.
- Capabilities: `.range`, `.resume`, `.playlist`, `.live`, `.audioTracks`, `.torrent`, `.requiresApp`.

**Tests:** priority order; active vs passive; unknown host; HTML fallback; no regression for YouTube/Telegram/magnet; a provider that throws does not block the next one.

**Effort:** 2–3 days. **Risk:** medium (routing changes touch the add flow).

#### P2 — Declarative extractor packs (P2)

For simple sites, a TOML/JSON rule can replace code:

```toml
id = "example-video"
version = "1.0.0"
minAppVersion = "1.9.0"
priority = 60

[match]
hosts = ["video.example.com"]
pathRegex = "^/watch/"

[request]
referer = "https://video.example.com/"
userAgent = "Mozilla/5.0 ..."

[extract]
jsonPath = "$.data.playbackUrl"
filename = "$.data.title"

[capabilities]
range = true
audioTracks = false
```

- No code execution; parse JSON with JSONPath/regex, apply headers, build a direct download.
- Bundle first-party packs; allow user-installed signed packs later.
- Do not build a Qt-like card/page system; use a small `ProviderOptionsView` protocol if a pack needs custom UI.
- If a site needs JavaScript or login flows, keep it in yt-dlp.

**Effort:** ~1 week. **Risk:** medium. Do it only when site requests pile up.

#### P3 — Native plugin API (P3)

A real plugin API would need an XPC helper, a sandbox profile, a manifest, capability declarations, signing, and a review process. That is a multi-week project and a large security surface. Defer until there is clear third-party demand.

#### P4 — Explicitly skip Python packs

- GPL-3.0 code cannot be copied into MIT Grabbit.
- In-process Python would add a runtime and a sandbox escape surface.
- GD3's packs are coupled to Qt widgets; they cannot be reused in SwiftUI.
- Most of the value (HTTP, M3U8, yt-dlp, ffmpeg, torrents) already exists in Grabbit.

#### P5 — Adopt the manifest ideas, not the runtime

Use `version`, `minAppVersion`, `dependencies`, and `capabilities` for **built-in** providers. Keep them static Swift, but make the metadata explicit so the registry can enable/disable providers and show compatibility.

---

## 7. Prioritized Backlog

| ID | Priority | Change | Why | Effort | Risk |
|---|---|---|---|---|---|
| **H1** | P0 | HTTP status disposition + retry budget + `Retry-After` + `cf-mitigated` | Fixes one-shot failures on transient 5xx; avoids GD3's infinite retry | 1–2 d | Low |
| **H2** | P0 | Probe `bytes=1-1` / `0-0`, 416, `Content-Range`, Cloudflare detection | Correct size/range discovery; better errors | 0.5–1 d | Low |
| **M1** | P0 | QuickJS-NG instead of Deno | ~123 MB smaller app; faster startup | 1–2 d + QA | Low–Med |
| **M2** | P1 | Map yt-dlp stderr to actionable messages | Biggest media UX win for the effort | 0.5 d | Low |
| **M2b** | P1 | Structured yt-dlp progress (`--progress-template`) | Real speed/ETA; testable | 0.5 d | Low |
| **H3** | P1 | Mid-flight split + growth benefit guard | Fixes slow-tail downloads; avoids connection churn | 2–3 d | Med |
| **M4** | P1 | Clip ranges | Feature parity; common user request | 1–2 d | Low |
| **M5** | P1 | Live recording UI | Feature parity | 1–2 d | Med |
| **M6** | P1 | Audio-language selection | Feature parity | 1 d | Low |
| **B1** | P1 | Loopback browser bridge (WS or SSE) | Live task control; removes the Python-only path eventually | 5–10 d | High |
| **B2** | P1 | Task snapshots + actions | Makes the bridge useful | 2–3 d | Med |
| **P1** | P1 | Provider registry + HTML fallback | Centralizes routing; fixes unsupported-site dead ends | 2–3 d | Med |
| **H4** | P2 | 1 s resume cadence for active downloads | Less re-download after a crash | 0.5–1 d | Low |
| **M7** | P2 | Playlist support | Common media workflow | 2–3 d | Med |
| **M8** | P2 | Per-track media engine | Per-track resume/control; large project | 2 w | High |
| **B3** | P2 | Swift native helper | Removes Python dependency; easier signing | 3–5 d | Med |
| **B4** | P2 | App-bundled extension auto-update | Keeps unpacked installs current | 2–3 d | Med |
| **B5** | P2 | Popup Tasks tab | Visible payoff of B1/B2 | 2 d | Low |
| **A1** | P2 | HTTP-only aria2 facade | Interop with aria2 clients | 3–5 d | Med |
| **P2** | P2 | Declarative extractor packs | Adds sites without releases | ~1 w | Med |
| **H5** | P2 | TLS fingerprint research | Some 403s may be TLS, not headers | 1 w | High |
| **P3** | P3 | Native plugin API | Ecosystem; large security surface | 3 w+ | High |
| **B7** | Skip | Full remote media control | Scope creep | — | — |

---

## 8. Suggested Sequencing

**Sprint 1 — correctness and size (1 week)**

- H1 HTTP status taxonomy.
- H2 probe hardening.
- M2 media error mapping.
- M2b structured progress.
- M1 QuickJS-NG + QA.

**Sprint 2 — media parity (2 weeks)**

- H3 mid-flight split + growth guard (behind a flag).
- M4 clip ranges.
- M5 live recording.
- M6 audio-language selection.

**Sprint 3 — browser bridge (2–3 weeks)**

- B1 loopback bridge (spike WS vs SSE first).
- B2 snapshots + actions.
- P1 provider registry (can run in parallel).

**Sprint 4 — polish and interop (2 weeks)**

- A1 aria2 facade (only if demand).
- M7 playlists.
- B4 extension auto-update.
- H4 1 s resume.
- B5 popup Tasks tab.

**Later:** M8 per-track engine, B3 Swift helper, P2 declarative packs, H5 TLS research, P3 plugin API.

---

## 9. Risks and Open Questions

1. **GPL contamination.** GD3 is GPL-3.0. Do not copy code, comments, or tests. Reimplement from behavior. Keep this document as the provenance record.
2. **QuickJS compatibility.** Test the pinned yt-dlp build against qjs 0.17.0 on YouTube before removing Deno. Keep a one-release fallback.
3. **Bridge attack surface.** A loopback server that can add downloads and open files is a local privilege boundary. Origin allow-list, token, Host check, and no wildcard CORS are mandatory.
4. **Mid-flight split can regress speed.** Some servers penalize reconnects. Keep it behind a setting and measure before defaulting on.
5. **yt-dlp flag drift.** `--download-sections`, `--live-from-start`, `--progress-template`, and `--js-runtimes` are version-sensitive. Pin and test; the updater can move faster than the app.
6. **App size.** QuickJS saves ~123 MB, but ffmpeg and yt-dlp still dominate. Do not add N_m3u8DL-RE without measuring the benefit.
7. **Localization.** Every new string needs `en` and `my` in `Localizable.xcstrings`; the PR checklist requires it.
8. **Signing/notarization.** A new Swift helper target and a new bridge server must be covered by the release signing and hardened-runtime steps.
9. **Test infrastructure.** Network chaos tests need a local HTTP server with controllable status codes, delays, and range behavior. Add it to `GrabbitTests` rather than relying on public hosts.
10. **User demand.** aria2 facade and declarative packs are speculative. Validate with issues before building.

---

## Appendix A — GD3 Constants Worth Knowing

| Constant | Value | Source |
|---|---|---|
| Default subworkers | 8 | `features/http_pack/task.py:66` |
| Min reassign size | 512 KB | `app/config/cfg.py:254-256` |
| Retry delay | 5 s, forever | `features/http_pack/task.py:275-276` |
| Permanent statuses | 400, 401, 403, 404, 405, 410, 451 | `features/http_pack/task.py:19-20` |
| Speed-up samples | 5 × 1 s | `features/http_pack/task.py:168-176` |
| Speed-up deviation | ≤ 15% | `features/http_pack/task.py:182-184` |
| Speed-up stop rule | `speedRatio < 0.8 * workerRatio` | `features/http_pack/task.py:200-203` |
| Resume record | 24-byte triples, every 1 s | `features/http_pack/task.py:93`, `209-240` |
| Browser protocol | v2 | `app/services/browser_service.py:90` |
| Browser port | 14370 | `app/config/cfg.py:268` |
| aria2 port | 16800 | `app/config/cfg.py:276` |
| aria2 token | empty by default | `app/config/cfg.py:277` |

## Appendix B — Grabbit Constants Worth Knowing

| Constant | Value | Source |
|---|---|---|
| Initial connections | 8 | `Grabbit/Engine/DownloadEngine.swift:81` |
| Max connections | 16 default; per-task 1–16, host profile 1–32 | `DownloadEngine.swift:24`, `AddDownloadSheet.swift:139` |
| Growth min split | 8 MiB | `DownloadEngine.swift:85` |
| Segment retry cap | 5 | `DownloadEngine.swift:77` |
| Throttle retry cap | 4 | `DownloadEngine.swift:1309` |
| Slowness threshold | 32 KB/s | `DownloadEngine.swift:71` |
| Slowness warmup | 60 s | `DownloadEngine.swift:73` |
| Slowness check | 15 s, 2 streaks | `DownloadEngine.swift:72-74` |
| Resume autosave | 5 s | `DownloadEngine.swift:122` |
| Partial suffix | `.grabbit-part` | `ResumeStore.swift:93-96` |
| Media binary | yt-dlp 2026.08.19 | `scripts/vendor-media-runtime.sh` |
| JS runtime | Deno 2.4.5 (~124 MB) | `scripts/vendor-media-runtime.sh` |
| aria2 binary | aria2-next | `Grabbit/Resources/bin/aria2-next` |

## Appendix C — Proposed Browser Protocol Messages

```json
// extension -> app
{"type":"hello","protocolVersion":3,"token":"…","extensionVersion":"1.1.0"}

// app -> extension
{"type":"hello_ack","protocolVersion":3,"appVersion":"1.10.0",
 "capabilities":{"taskSnapshots":true,"taskActions":["toggle_pause","cancel","remove","redownload","open_file","open_folder"]}}

// extension -> app
{"type":"subscribe_tasks"}

// app -> extension
{"type":"task_snapshot","sequence":42,"tasks":[
  {"id":"…","name":"file.zip","status":"downloading","progress":0.42,
   "receivedBytes":4200000,"totalBytes":10000000,"speed":1200000,"eta":5,
   "canPause":true,"canOpenFile":false,"canOpenFolder":false,"fileExt":"zip","source":"http"}
]}

// extension -> app
{"type":"task_action","requestId":"…","taskId":"…","action":"toggle_pause"}

// app -> extension
{"type":"task_action_result","requestId":"…","ok":true}
```

## Appendix D — References

**GD3**

- `features/http_pack/task.py` — segmentation, `.ghd`, retries, split, auto-speedup.
- `features/http_pack/pack.py` — `bytes=1-1` probe, range detection, filename.
- `features/m3u8_pack/task.py`, `pack.py` — N_m3u8DL-RE, live, progress.
- `features/yt_dlp_pack/task.py`, `config.py` — extract-only, QuickJS, clips, audio languages.
- `docs/adr/0007-yt-dlp-library-mode-with-wreq.md` — QuickJS decision.
- `app/services/browser_service.py` — protocol v2, pairing, snapshots, actions.
- `app/services/aria2_rpc.py` — aria2 shim.
- `app/models/pack.py`, `app/loader.py` — Feature Pack model and loader.
- `browser_extension/app/src/` — popup, bridge, page-media strategies.

**Grabbit**

- `Grabbit/Engine/DownloadEngine.swift` — probe, segments, growth, retries, collapse.
- `Grabbit/Engine/SegmentTransport.swift` — per-segment HTTP/1.1 transport.
- `Grabbit/Engine/HTTP1Client.swift` — request/response, redirects, timeouts.
- `Grabbit/Engine/ResumeStore.swift` — atomic JSON state, partial file.
- `Grabbit/Engine/FinalizeJournal.swift` — crash-safe finalize.
- `Grabbit/Engine/MediaEngine.swift`, `MediaProbe.swift` — yt-dlp path.
- `Grabbit/Engine/MediaRuntimeResolver.swift`, `MediaComponentUpdater.swift` — binaries.
- `Grabbit/NativeMessaging/NativeMessagingHost.swift`, `NativeHostInstaller.swift` — native messaging.
- `GrabbitExtension/background.js`, `content.js`, `page-hook.js`, `popup.js` — extension.
- `GrabbitExtension/native-messaging/grabbit-native-helper.py` — Python helper.
- `Grabbit/UI/Views/AddDownloadSheet.swift`, `Grabbit/GrabbitApp.swift` — routing.
- `Grabbit/Engine/Aria2RPC.swift`, `Aria2Daemon.swift` — aria2 client/daemon.
- `ARCHITECTURE.md`, `DEPENDENCIES.md`, `ROADMAP.md` — project context.
