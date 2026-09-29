#!/usr/bin/env python3
"""Grabbit native messaging helper.

Chrome launches this lightweight script (not the full GUI app) as the native
host. It reads the JSON message from stdin, forwards the download to the
running Grabbit app via the grabbit:// URL scheme, then ACKs and exits.

This avoids running a second GUI app instance as the native host.
"""
import sys
import struct
import json
import subprocess
import urllib.parse


def read_message():
    raw_len = sys.stdin.buffer.read(4)
    if len(raw_len) < 4:
        return None
    msg_len = struct.unpack("<I", raw_len)[0]
    if msg_len == 0 or msg_len > 10 * 1024 * 1024:
        return None
    payload = sys.stdin.buffer.read(msg_len)
    if len(payload) < msg_len:
        return None
    return json.loads(payload.decode("utf-8"))


def send_message(obj):
    data = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(data)) + data)
    sys.stdout.buffer.flush()


def main():
    msg = read_message()
    if not msg or not msg.get("url"):
        send_message({"ok": False, "error": "no url"})
        return
    params = urllib.parse.urlencode({
        "url": msg["url"],
        "filename": msg.get("filename", ""),
        "source": msg.get("source", "native"),
        "pageUrl": msg.get("pageUrl", ""),
    })
    # Forward to the running Grabbit app via URL scheme
    subprocess.run(["open", f"grabbit://download?{params}"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    send_message({"ok": True, "url": msg["url"]})


if __name__ == "__main__":
    main()
