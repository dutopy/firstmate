#!/usr/bin/env python3
"""Fake typesafe.ai System One endpoint for the Jev finding classifier tests.

Binds 127.0.0.1 on an ephemeral port (port 0), writes the chosen port to
--port-file so a test can point TYPESAFE_BASE_URL at it, then answers every
POST /v1/systemone with one canned Choice answer. The tests never reach the
real API.

Usage:
  python3 jev-finding-fake-typesafe.py --port-file <path> --log-dir <dir> \
      [--choice <optionId>] [--confidence <0..1>] [--status <http-code>] \
      [--delay <seconds>] [--body-file <path>]

Each request appends its path to <log-dir>/requests and rewrites <log-dir>/
path, <log-dir>/auth, and <log-dir>/body, so a test can assert both what the
classifier sent and how many calls it made. --status != 200 answers that status
with a small JSON error body, --body-file answers 200 with exactly those bytes
instead of the canned Choice answer, and --delay sleeps before answering so a
test can exercise a classifier's wall-clock bound.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--choice", default="important")
    parser.add_argument("--confidence", type=float, default=0.95)
    parser.add_argument("--status", type=int, default=200)
    parser.add_argument("--delay", type=float, default=0.0)
    parser.add_argument("--body-file", default="")
    args = parser.parse_args()
    os.makedirs(args.log_dir, exist_ok=True)
    override = b""
    if args.body_file:
        with open(args.body_file, "rb") as fh:
            override = fh.read()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *unused: object) -> None:
            pass

        def _record(self, body: bytes) -> None:
            with open(os.path.join(args.log_dir, "requests"), "a", encoding="utf-8") as fh:
                fh.write(self.path + "\n")
            with open(os.path.join(args.log_dir, "path"), "w", encoding="utf-8") as fh:
                fh.write(self.path)
            with open(os.path.join(args.log_dir, "auth"), "w", encoding="utf-8") as fh:
                fh.write(self.headers.get("Authorization") or "")
            with open(os.path.join(args.log_dir, "body"), "wb") as fh:
                fh.write(body)

        def _respond(self, status: int, payload: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            self._record(self.rfile.read(length))
            if args.delay > 0:
                time.sleep(args.delay)
            if args.status != 200:
                self._respond(args.status, b'{"error":"fake upstream failure"}')
                return
            if args.body_file:
                self._respond(200, override)
                return
            answer = {
                "model": "jev-fake",
                "answers": {
                    "route": {
                        "type": "choice",
                        "choice": args.choice,
                        "confidence": args.confidence,
                        "probabilities": {args.choice: args.confidence},
                    }
                },
                "usage": {"input_tokens": 11, "output_tokens": 4},
            }
            # allow_nan keeps the fake deliberately non-strict: a test can point
            # --confidence at NaN or Infinity and assert that the classifier
            # refuses to pass that answer through.
            self._respond(200, json.dumps(answer, allow_nan=True).encode("utf-8"))

    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(args.port_file, "w", encoding="utf-8") as fh:
        fh.write("%d\n" % server.server_address[1])
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
