#!/usr/bin/env python3
"""Instrumented controlled origin for egress-firewall evidence.

Listens on TCP/80 and TCP/443 and logs, per accepted connection, the peer, whether
the first bytes are a TLS ClientHello (with the visible SNI, or none) or plaintext,
and the first application bytes received. Any row in the log is proof that bytes
reached the origin; the absence of a row for a probe that got an empty reply from
the firewall is what turns "empty reply" into a deny verdict.

TLS connections are completed with a self-signed certificate (probes use curl -k)
and answered "ORIGIN-TLS sni=<name>"; plaintext or malformed bytes on either port are
answered "ORIGIN-PLAINTEXT port=<port>" so an escaped request is unmistakable in the
client output as well.

Usage: origin-server.py <cert.pem> <key.pem> <log-file>
"""
import datetime
import socket
import ssl
import sys
import threading

CERT, KEY, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
lock = threading.Lock()


def log(line):
    with lock, open(LOG, "a") as f:
        f.write(f"{datetime.datetime.utcnow().isoformat()}Z {line}\n")


def parse_sni(hello):
    """Return the SNI host_name from a TLS ClientHello record, or None."""
    try:
        if hello[0] != 0x16 or hello[5] != 0x01:
            return None
        p = 9 + 2 + 32  # record(5) + handshake(4) + version(2) + random(32)
        p += 1 + hello[p]  # session id
        p += 2 + int.from_bytes(hello[p:p + 2], "big")  # cipher suites
        p += 1 + hello[p]  # compression
        end = p + 2 + int.from_bytes(hello[p:p + 2], "big")
        p += 2
        while p + 4 <= end:
            etype = int.from_bytes(hello[p:p + 2], "big")
            elen = int.from_bytes(hello[p + 2:p + 4], "big")
            if etype == 0:
                nlen = int.from_bytes(hello[p + 7:p + 9], "big")
                return hello[p + 9:p + 9 + nlen].decode("ascii", "replace")
            p += 4 + elen
        return ""  # ClientHello without SNI
    except (IndexError, ValueError):
        return None


def handle(conn, port, ctx):
    peer = "%s:%d" % conn.getpeername()
    try:
        conn.settimeout(5)
        first = conn.recv(4096, socket.MSG_PEEK)
        if not first:
            log(f"port={port} peer={peer} kind=empty bytes=0")
            return
        sni = parse_sni(first) if first[0] == 0x16 else None
        if sni is not None:
            log(f"port={port} peer={peer} kind=tls-clienthello sni={sni or '<none>'} bytes={len(first)}")
            try:
                tls = ctx.wrap_socket(conn, server_side=True)
            except ssl.SSLError as e:
                log(f"port={port} peer={peer} kind=tls-handshake-failed err={e}")
                return
            req = tls.recv(4096)
            line = req.split(b"\r\n", 1)[0].decode("latin-1", "replace")
            log(f"port={port} peer={peer} kind=tls-application sni={sni or '<none>'} request={line!r} bytes={len(req)}")
            body = f"ORIGIN-TLS sni={sni or '<none>'}\n".encode()
            tls.sendall(b"HTTP/1.1 200 OK\r\nServer: egfw-origin\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
            tls.close()
        else:
            data = conn.recv(4096)
            printable = data[:120].decode("latin-1", "replace").replace("\r", "\\r").replace("\n", "\\n")
            log(f"port={port} peer={peer} kind=plaintext bytes={len(data)} first={printable!r}")
            body = f"ORIGIN-PLAINTEXT port={port}\n".encode()
            conn.sendall(b"HTTP/1.1 200 OK\r\nServer: egfw-origin\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
    except (socket.timeout, ConnectionError, OSError) as e:
        log(f"port={port} peer={peer} kind=error err={e}")
    finally:
        try:
            conn.close()
        except OSError:
            pass


def serve(port, ctx):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))
    s.listen(64)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=handle, args=(conn, port, ctx), daemon=True).start()


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
threading.Thread(target=serve, args=(80, ctx), daemon=True).start()
log("origin-server started ports=80,443")
serve(443, ctx)
