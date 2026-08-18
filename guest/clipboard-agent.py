#!/usr/bin/env python3
"""Clipboard bridge, guest half.

Listens on AF_VSOCK and mirrors the Plasma clipboard to and from macOS. vsock is
used rather than TCP so the bridge keeps working when the guest's networking is
broken — a host VPN with a small MTU already black-holes this VM's traffic, and
the clipboard should not go down with it.
"""
import hashlib
import json
import socket
import struct
import subprocess
import sys
import threading
import time

PORT = 7788
MAX_BYTES = 4 * 1024 * 1024

# Guards `suppressed`, which is the whole loop-prevention scheme: whatever we
# just wrote locally must not be read back and echoed to the host.
lock = threading.Lock()
suppressed = None


def digest(text):
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()


def watcher():
    """One long-lived `wl-paste --watch` that emits a NUL-terminated record on
    every clipboard change.

    An earlier version polled `wl-paste` several times a second. That is a
    process spawn per poll, thousands per hour, for a clipboard that changes a
    handful of times a minute — and the guest's sshd eventually stopped being
    able to fork. Waiting on an event costs nothing while idle.
    """
    return subprocess.Popen(
        ["wl-paste", "--type", "text/plain;charset=utf-8",
         "--watch", "sh", "-c", "cat; printf '\\0'"],
        stdout=subprocess.PIPE,
    )


def records(stream):
    """Yield NUL-delimited clipboard payloads as they arrive."""
    buffer = bytearray()
    while True:
        chunk = stream.read(1)
        if not chunk:
            return
        if chunk == b"\0":
            if len(buffer) <= MAX_BYTES:
                yield bytes(buffer).decode("utf-8", "replace")
            buffer.clear()
        else:
            buffer.extend(chunk)


def write_local(text):
    try:
        subprocess.run(
            ["wl-copy", "--type", "text/plain;charset=utf-8"],
            input=text.encode("utf-8"), timeout=4, check=False,
        )
    except Exception as exc:
        print(f"wl-copy failed: {exc}", file=sys.stderr, flush=True)


def send_frame(conn, payload):
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    conn.sendall(struct.pack("!I", len(body)) + body)


def recv_exactly(conn, count):
    chunks = []
    remaining = count
    while remaining:
        chunk = conn.recv(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def recv_frame(conn):
    header = recv_exactly(conn, 4)
    if header is None:
        return None
    (length,) = struct.unpack("!I", header)
    if length > MAX_BYTES:
        return None
    body = recv_exactly(conn, length)
    if body is None:
        return None
    return json.loads(body.decode("utf-8"))


def reader(conn, stop):
    """Host -> guest."""
    global suppressed
    while not stop.is_set():
        try:
            frame = recv_frame(conn)
        except Exception:
            break
        if frame is None:
            break
        if frame.get("t") != "clip":
            continue
        text = frame.get("data", "")
        with lock:
            suppressed = digest(text)
        write_local(text)
    stop.set()


def serve(conn, stream):
    global suppressed
    stop = threading.Event()
    threading.Thread(target=reader, args=(conn, stop), daemon=True).start()

    last_sent = None
    for text in records(stream):
        if stop.is_set():
            break
        if not text:
            continue
        fingerprint = digest(text)
        if fingerprint == last_sent:
            continue
        with lock:
            if fingerprint == suppressed:
                last_sent = fingerprint
                continue
        try:
            send_frame(conn, {"t": "clip", "fmt": "text", "data": text})
        except Exception:
            break
        last_sent = fingerprint
    stop.set()


def main():
    listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((socket.VMADDR_CID_ANY, PORT))
    listener.listen(1)
    print(f"clipboard agent listening on vsock port {PORT}", flush=True)

    stream = watcher()
    print("watching the clipboard for changes", flush=True)

    while True:
        conn, addr = listener.accept()
        print(f"host connected from cid {addr[0]}", flush=True)
        try:
            serve(conn, stream.stdout)
        finally:
            conn.close()
            print("host disconnected", flush=True)
        if stream.poll() is not None:
            stream = watcher()
            print("clipboard watcher restarted", flush=True)


if __name__ == "__main__":
    main()
