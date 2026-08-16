#!/usr/bin/env python3
"""TCP proxy: listen on LAN (0.0.0.0:18000) → forward to Paperless on 127.0.0.1:18000.

Needed because Docker Desktop (vpnkit/gvisor) + VPN often accepts LAN
connections to published ports but returns empty HTTP responses.
"""
from __future__ import annotations

import argparse
import os
import select
import signal
import socket
import sys
import threading

DEFAULT_LISTEN = ("0.0.0.0", 18000)
DEFAULT_TARGET = ("127.0.0.1", 18000)
PID_FILE_DEFAULT = os.path.join(os.path.dirname(__file__), ".paperless-lan-proxy.pid")


def pipe(a: socket.socket, b: socket.socket) -> None:
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 60)
            if not r:
                continue
            for src in r:
                dst = b if src is a else a
                data = src.recv(65536)
                if not data:
                    return
                dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass


def handle(client: socket.socket, target: tuple[str, int]) -> None:
    upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        upstream.connect(target)
    except OSError as exc:
        print(f"proxy: connect to {target} failed: {exc}", file=sys.stderr)
        client.close()
        return
    t1 = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
    t1.start()
    t1.join()


def serve(listen: tuple[str, int], target: tuple[str, int]) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(listen)
    srv.listen(128)
    print(
        f"paperless-lan-proxy listening on {listen[0]}:{listen[1]} → {target[0]}:{target[1]}",
        flush=True,
    )

    def _stop(*_args: object) -> None:
        try:
            srv.close()
        finally:
            sys.exit(0)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    while True:
        try:
            client, _addr = srv.accept()
        except OSError:
            break
        threading.Thread(target=handle, args=(client, target), daemon=True).start()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--listen-host", default=DEFAULT_LISTEN[0])
    p.add_argument("--listen-port", type=int, default=DEFAULT_LISTEN[1])
    p.add_argument("--target-host", default=DEFAULT_TARGET[0])
    p.add_argument("--target-port", type=int, default=DEFAULT_TARGET[1])
    p.add_argument("--pid-file", default=PID_FILE_DEFAULT)
    p.add_argument("--daemon", action="store_true", help="fork to background and write pid file")
    args = p.parse_args()

    listen = (args.listen_host, args.listen_port)
    target = (args.target_host, args.target_port)

    if args.daemon:
        if os.fork() != 0:
            sys.exit(0)
        os.setsid()
        if os.fork() != 0:
            sys.exit(0)
        with open(args.pid_file, "w", encoding="utf-8") as fh:
            fh.write(str(os.getpid()))
        sys.stdin.close()
        sys.stdout = open(os.devnull, "w")  # noqa: SIM115
        sys.stderr = open(os.devnull, "w")  # noqa: SIM115

    serve(listen, target)


if __name__ == "__main__":
    main()
