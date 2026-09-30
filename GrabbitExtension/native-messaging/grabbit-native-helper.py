#!/usr/bin/env python3
"""Grabbit native messaging helper.

Chrome launches this lightweight script (not the full GUI app) as the native
host. It stays alive for the lifetime of the browser's native-messaging port
and handles three kinds of work:

  grab            URL downloads: the payload (URL + captured headers) is
                  written to Inbox/ and handed to the running Grabbit app
                  via grabbit://download?payload=<file>.
  stream-init     In-page media capture (Telegram Web blobs and MSE streams):
  stream-chunk    chunks are written to disk as they arrive. A sidecar
  stream-finalize meta-<captureId>.json records each stream so a NEW helper
  stream-cancel   process can keep appending after the service worker was
                  recycled. finalize assembles the file(s), moves them into
                  Inbox/ and opens grabbit://import?payload=<file>.
  import          A completed browser download: handed to the app as
                  grabbit://import via a payload file.

Every message is acknowledged with {"type":"ack","id":...,"ok":bool} so the
extension can apply backpressure while streaming. Messages are read with raw
os.read so select() never races with Python's buffered stdin.
"""
import base64
import json
import os
import re
import select
import shutil
import struct
import subprocess
import sys
import time
import uuid
from pathlib import Path
from urllib.parse import quote

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Grabbit"
INBOX = APP_SUPPORT / "Inbox"
STALE_SECONDS = 6 * 60 * 60
CAPTURE_IDLE_SECONDS = 30 * 60
META_PREFIX = "meta-"

CAPTURES = {}  # capture_id -> {"filename", "page_url", "streams": {stream_id: meta}}


# --- protocol ---------------------------------------------------------------


def read_exact(fd, count):
    buf = b""
    while len(buf) < count:
        chunk = os.read(fd, count - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def read_message(fd):
    raw_len = read_exact(fd, 4)
    if raw_len is None:
        return None
    msg_len = struct.unpack("<I", raw_len)[0]
    if msg_len == 0 or msg_len > 64 * 1024 * 1024:
        return None
    payload = read_exact(fd, msg_len)
    if payload is None:
        return None
    try:
        return json.loads(payload.decode("utf-8"))
    except Exception:
        return None


def send_message(obj):
    try:
        data = json.dumps(obj).encode("utf-8")
        os.write(1, struct.pack("<I", len(data)) + data)
    except Exception:
        pass


def ack(msg, ok=True):
    if msg.get("id") is not None:
        send_message({"type": "ack", "id": msg["id"], "ok": bool(ok)})


def open_scheme(url):
    try:
        subprocess.run(
            ["open", url],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except Exception:
        pass


# --- helpers ----------------------------------------------------------------


def safe_component(value, limit=80):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", str(value or ""))[:limit]


def sanitize_filename(name):
    name = (name or "").strip()
    name = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", name)
    name = name.lstrip(".")
    if not name:
        name = "grabbit-" + str(int(time.time()))
    return name[:180]


def mime_extension(mime):
    mime = (mime or "").lower()
    is_audio = mime.startswith("audio")
    if "mp4" in mime:
        return "m4a" if is_audio else "mp4"
    if "webm" in mime:
        return "weba" if is_audio else "webm"
    if "mpeg" in mime or "mp3" in mime:
        return "mp3"
    if "aac" in mime:
        return "aac"
    if "ogg" in mime or "opus" in mime:
        return "ogg"
    if "wav" in mime:
        return "wav"
    if "quicktime" in mime:
        return "mov"
    if "pdf" in mime:
        return "pdf"
    if "zip" in mime:
        return "zip"
    if mime.startswith("video"):
        return "mp4"
    if mime.startswith("audio"):
        return "m4a"
    return "bin"


def sniff_extension(path):
    """Best-effort file-type detection from magic bytes.

    Blob downloads often carry no MIME type, so Chrome suggests a generic name
    and the mime-based extension resolves to "bin". Sniffing the actual bytes
    recovers the real extension (zip, mp4, pdf, ...).
    """
    try:
        with open(path, "rb") as handle:
            head = handle.read(16)
    except Exception:
        return ""
    if not head:
        return ""
    if head[:4] in (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"):
        return "zip"
    if head[:4] == b"%PDF":
        return "pdf"
    if head[4:8] == b"ftyp":
        return "mp4"
    if head[:4] == b"\x1aE\xdf\xa3":
        return "mkv"
    if head[:3] == b"ID3" or head[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"):
        return "mp3"
    if head[:4] == b"Rar!":
        return "rar"
    if head[:6] == b"7z\xbc\xaf\x27\x1c":
        return "7z"
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if head[:3] == b"\xff\xd8\xff":
        return "jpg"
    if head[:2] == b"MZ":
        return "exe"
    if head[:5] == b"<?xml":
        return "xml"
    return ""


def unique_path(path):
    if not path.exists():
        return path
    stem, suffix = path.stem, path.suffix
    for i in range(2, 1000):
        candidate = path.with_name(f"{stem} ({i}){suffix}")
        if not candidate.exists():
            return candidate
    return path.with_name(f"{stem}-{uuid.uuid4().hex[:6]}{suffix}")


def unlink_quiet(path):
    try:
        Path(path).unlink(missing_ok=True)
    except Exception:
        pass


def close_stream(meta):
    handle = meta.get("handle")
    if handle is not None:
        try:
            handle.close()
        except Exception:
            pass
        meta["handle"] = None


def capture_meta_path(capture_id):
    return INBOX / f"{META_PREFIX}{safe_component(capture_id)}.json"


def save_capture_meta(capture_id, capture):
    try:
        INBOX.mkdir(parents=True, exist_ok=True)
        payload = {
            "filename": capture.get("filename", ""),
            "page_url": capture.get("page_url", ""),
            "streams": {
                sid: {
                    "path": meta.get("path", ""),
                    "mime": meta.get("mime", ""),
                    "track": meta.get("track", "other"),
                    "name": meta.get("name", ""),
                }
                for sid, meta in capture.get("streams", {}).items()
            },
        }
        capture_meta_path(capture_id).write_text(json.dumps(payload), encoding="utf-8")
    except Exception:
        pass


def load_capture(capture_id):
    path = capture_meta_path(capture_id)
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    streams = {}
    for sid, meta in (payload.get("streams") or {}).items():
        streams[sid] = {
            "path": meta.get("path", ""),
            "handle": None,
            "mime": meta.get("mime", ""),
            "track": meta.get("track", "other"),
            "bytes": 0,
            "name": meta.get("name", ""),
        }
    capture = {
        "filename": payload.get("filename", ""),
        "page_url": payload.get("page_url", ""),
        "streams": streams,
    }
    CAPTURES[capture_id] = capture
    return capture


def ensure_capture(capture_id, msg=None):
    capture = CAPTURES.get(capture_id)
    if capture is None:
        capture = load_capture(capture_id)
    if capture is not None and msg is not None:
        if msg.get("pageUrl"):
            capture["page_url"] = msg["pageUrl"]
        if msg.get("filename") and not capture.get("filename"):
            capture["filename"] = msg["filename"]
    return capture


def capture_files(capture):
    return [meta.get("path", "") for meta in capture.get("streams", {}).values() if meta.get("path")]


def cancel_capture(capture_id):
    capture = CAPTURES.pop(capture_id, None) or load_capture(capture_id)
    CAPTURES.pop(capture_id, None)
    if capture:
        for meta in capture.get("streams", {}).values():
            close_stream(meta)
            unlink_quiet(meta["path"])
    unlink_quiet(str(capture_meta_path(capture_id)))


def cleanup_stale():
    now = time.time()
    if not INBOX.exists():
        return
    # Expire capture sessions idle for too long. Active captures are skipped.
    for meta_file in list(INBOX.glob(f"{META_PREFIX}*.json")):
        capture_id = meta_file.stem[len(META_PREFIX):]
        if capture_id in CAPTURES:
            continue
        try:
            if now - meta_file.stat().st_mtime > CAPTURE_IDLE_SECONDS:
                cancel_capture(capture_id)
        except Exception:
            pass
    # Orphaned helper files from crashed/abandoned sessions.
    for entry in list(INBOX.iterdir()):
        try:
            if not entry.is_file():
                continue
            if now - entry.stat().st_mtime <= STALE_SECONDS:
                continue
            if entry.name.startswith(META_PREFIX):
                capture_id = entry.stem[len(META_PREFIX):]
                if capture_id in CAPTURES:
                    continue
            if entry.name.startswith(("grab-", "import-", "part-", META_PREFIX)):
                entry.unlink()
        except Exception:
            pass


# --- handlers ---------------------------------------------------------------


def handle_grab(msg):
    payload = {
        "url": msg.get("url", ""),
        "filename": msg.get("filename", ""),
        "title": msg.get("title", ""),
        "pageUrl": msg.get("pageUrl", ""),
        "source": msg.get("source", "native"),
        "headers": msg.get("headers", {}),
    }
    INBOX.mkdir(parents=True, exist_ok=True)
    path = INBOX / f"grab-{uuid.uuid4().hex}.json"
    try:
        path.write_text(json.dumps(payload), encoding="utf-8")
    except Exception:
        return False
    open_scheme(f"grabbit://download?payload={quote(str(path))}")
    return True


def handle_import(msg):
    source = Path(msg.get("path") or "")
    if not source.is_file():
        return False
    # The app only ever imports files from the Inbox, so stage the finished
    # browser download there first (same volume: an atomic rename).
    INBOX.mkdir(parents=True, exist_ok=True)
    name = sanitize_filename(msg.get("filename") or source.name)
    if Path(name).suffix.lower() in ("", ".bin"):
        sniffed = sniff_extension(source)
        if sniffed:
            name = f"{Path(name).stem}.{sniffed}"
    destination = unique_path(INBOX / name)
    try:
        shutil.move(str(source), str(destination))
    except Exception:
        try:
            shutil.copy2(str(source), str(destination))
            source.unlink()
        except Exception:
            return False
    payload = {
        "path": str(destination),
        "filename": destination.name,
        "pageUrl": msg.get("pageUrl", ""),
        "source": msg.get("source", "browser"),
    }
    payload_path = INBOX / f"import-{uuid.uuid4().hex}.json"
    try:
        payload_path.write_text(json.dumps(payload), encoding="utf-8")
    except Exception:
        return False
    open_scheme(f"grabbit://import?payload={quote(str(payload_path))}")
    return True


def handle_stream_init(msg):
    capture_id = str(msg.get("captureId") or "")
    stream_id = str(msg.get("streamId") or "")
    if not capture_id or not stream_id:
        return False
    capture = ensure_capture(capture_id, msg)
    if capture is None:
        capture = {
            "filename": "",
            "page_url": msg.get("pageUrl", ""),
            "streams": {},
        }
        CAPTURES[capture_id] = capture
    if msg.get("filename") and not capture.get("filename"):
        capture["filename"] = msg["filename"]

    old = capture["streams"].get(stream_id)
    if old is not None:
        close_stream(old)
        unlink_quiet(old["path"])

    INBOX.mkdir(parents=True, exist_ok=True)
    path = INBOX / (
        f"part-{safe_component(capture_id)}-{safe_component(stream_id, 60)}-{uuid.uuid4().hex[:8]}.part"
    )
    try:
        handle = open(path, "wb")
    except Exception:
        return False
    capture["streams"][stream_id] = {
        "path": str(path),
        "handle": handle,
        "mime": msg.get("mime", ""),
        "track": msg.get("track", "other"),
        "bytes": 0,
        "name": msg.get("filename", ""),
    }
    save_capture_meta(capture_id, capture)
    return True


def handle_stream_chunk(msg):
    capture_id = str(msg.get("captureId") or "")
    stream_id = str(msg.get("streamId") or "")
    capture = CAPTURES.get(capture_id) or load_capture(capture_id)
    if capture is None:
        return False
    meta = capture.get("streams", {}).get(stream_id)
    if meta is None:
        return False
    if meta.get("handle") is None:
        try:
            meta["handle"] = open(meta["path"], "ab")
        except Exception:
            return False
    try:
        chunk = base64.b64decode(msg.get("data") or "")
    except Exception:
        return False
    try:
        meta["handle"].write(chunk)
        meta["bytes"] += len(chunk)
        if msg.get("mime") and not meta.get("mime"):
            meta["mime"] = msg["mime"]
    except Exception:
        return False
    return True


def size_of(meta):
    try:
        return Path(meta["path"]).stat().st_size
    except Exception:
        return meta.get("bytes", 0)


def handle_stream_finalize(msg):
    capture_id = str(msg.get("captureId") or "")
    capture = CAPTURES.pop(capture_id, None) or load_capture(capture_id)
    CAPTURES.pop(capture_id, None)
    if not capture:
        return False
    streams = capture.get("streams", {})
    for meta in streams.values():
        close_stream(meta)
    unlink_quiet(str(capture_meta_path(capture_id)))

    candidates = [m for m in streams.values() if size_of(m) > 0]
    if not candidates:
        for meta in streams.values():
            unlink_quiet(meta["path"])
        return False

    video = max((m for m in candidates if m.get("track") == "video"), key=size_of, default=None)
    audio = max((m for m in candidates if m.get("track") == "audio"), key=size_of, default=None)
    if video is not None:
        primary = video
    elif audio is not None:
        primary = audio
        audio = None
    else:
        primary = max(candidates, key=size_of)
        audio = None

    requested = sanitize_filename(
        msg.get("filename") or capture.get("filename") or primary.get("name") or ""
    )
    suffix = Path(requested).suffix.lstrip(".")
    stem = sanitize_filename(Path(requested).stem if suffix else requested)
    ext = suffix or mime_extension(primary.get("mime", ""))
    dest = unique_path(INBOX / f"{stem}.{ext}")
    try:
        os.replace(primary["path"], dest)
    except Exception:
        for meta in candidates:
            unlink_quiet(meta["path"])
        return False

    if ext.lower() == "bin":
        sniffed = sniff_extension(dest)
        if sniffed:
            renamed = unique_path(dest.with_suffix("." + sniffed))
            try:
                os.replace(dest, renamed)
                dest = renamed
            except Exception:
                pass

    aux_path = ""
    if audio is not None and audio is not primary:
        audio_ext = mime_extension(audio.get("mime", ""))
        aux_dest = unique_path(INBOX / f"{stem}.audio.{audio_ext}")
        try:
            os.replace(audio["path"], aux_dest)
            aux_path = str(aux_dest)
        except Exception:
            unlink_quiet(audio["path"])

    for meta in candidates:
        if meta is primary or meta is audio:
            continue
        unlink_quiet(meta["path"])

    payload = {
        "path": str(dest),
        "auxPath": aux_path,
        "filename": dest.name,
        "mime": primary.get("mime", ""),
        "pageUrl": capture.get("page_url", ""),
        "source": "extension-stream",
        "title": stem,
    }
    try:
        payload_path = INBOX / f"import-{uuid.uuid4().hex}.json"
        payload_path.write_text(json.dumps(payload), encoding="utf-8")
    except Exception:
        return False
    open_scheme(f"grabbit://import?payload={quote(str(payload_path))}")
    return True


# --- main loop --------------------------------------------------------------


def handle_debug(msg):
    try:
        INBOX.mkdir(parents=True, exist_ok=True)
        with open(INBOX / "telegram-debug.log", "a", encoding="utf-8") as handle:
            handle.write((msg.get("line") or "") + "\n")
    except Exception:
        pass
    return True


def dispatch(msg):
    msg_type = msg.get("type")
    if not msg_type and msg.get("url"):
        msg_type = "grab"
    if msg_type == "grab" and msg.get("url"):
        return handle_grab(msg)
    if msg_type == "import" and msg.get("path"):
        return handle_import(msg)
    if msg_type == "stream-init":
        return handle_stream_init(msg)
    if msg_type == "stream-chunk":
        return handle_stream_chunk(msg)
    if msg_type == "stream-finalize":
        return handle_stream_finalize(msg)
    if msg_type == "stream-cancel":
        cancel_capture(str(msg.get("captureId") or ""))
        return True
    if msg_type == "debug":
        return handle_debug(msg)
    return True


def main():
    cleanup_stale()
    fd = sys.stdin.fileno()
    while True:
        try:
            ready, _, _ = select.select([fd], [], [], 60)
        except Exception:
            break
        if not ready:
            cleanup_stale()
            continue
        msg = read_message(fd)
        if msg is None:
            break
        ok = True
        try:
            ok = dispatch(msg)
        except Exception as exc:  # never kill the channel on one bad message
            send_message({"type": "error", "error": str(exc)})
            ok = False
        finally:
            ack(msg, ok)
    # Port closed (service worker recycled or browser quit). Close handles but
    # KEEP files + sidecars: a fresh helper resumes them, and stale ones are
    # garbage-collected by CAPTURE_IDLE_SECONDS.
    for capture in CAPTURES.values():
        for meta in capture.get("streams", {}).values():
            close_stream(meta)


if __name__ == "__main__":
    main()
