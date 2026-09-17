#!/usr/bin/env python3
"""Fake typesafe.ai System One endpoint for tests/fm-jev-class.test.sh.

Binds 127.0.0.1 on an ephemeral port (port 0), writes the chosen port to
--port-file so the test can point TYPESAFE_BASE_URL at it, then answers every
POST /v1/systemone with one canned answer for each of the classifier's two
questions. The test never reaches the real API.

Usage:
  python3 jev-class-fake-typesafe.py --port-file <path> --log-dir <dir> \
      [--class-choice <optionId>] [--class-confidence <0..1>] \
      [--effort-choice <optionId>] [--effort-confidence <0..1>] \
      [--class-confidence-raw <literal>] [--effort-confidence-raw <literal>] \
      [--status <http-code>] [--delay <seconds>] [--body-file <path>] \
      [--drop <class|effort>]

Each request records the path, the Authorization header, and the raw body into
--log-dir, so a test can assert both what the classifier sent and what it did
not send. --status != 200 answers that status with a small JSON error body,
--body-file answers 200 with exactly those bytes instead of the canned answer,
--drop omits one question's answer to exercise a malformed success response, and
--delay sleeps before answering so a test can exercise the wall-clock bound.
--class-confidence-raw and --effort-confidence-raw write that literal, unquoted,
as the answer's confidence, so a test can return a value strict JSON cannot
express such as NaN or Infinity beside an ordinary number.
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
    parser.add_argument("--class-choice", default="volume_cheap")
    parser.add_argument("--class-confidence", type=float, default=0.97)
    parser.add_argument("--class-confidence-raw", default="")
    parser.add_argument("--effort-choice", default="low")
    parser.add_argument("--effort-confidence", type=float, default=0.96)
    parser.add_argument("--effort-confidence-raw", default="")
    parser.add_argument("--status", type=int, default=200)
    parser.add_argument("--delay", type=float, default=0.0)
    parser.add_argument("--body-file", default="")
    parser.add_argument("--drop", default="")
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
            with open(os.path.join(args.log_dir, "path"), "w", encoding="utf-8") as fh:
                fh.write(self.path)
            with open(os.path.join(args.log_dir, "auth"), "w", encoding="utf-8") as fh:
                fh.write(self.headers.get("Authorization") or "")
            with open(os.path.join(args.log_dir, "body"), "wb") as fh:
                fh.write(body)
            with open(os.path.join(args.log_dir, "count"), "a", encoding="utf-8") as fh:
                fh.write("1\n")

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
            answers = {}
            if args.drop != "class":
                answers["class"] = {
                    "type": "choice",
                    "choice": args.class_choice,
                    "confidence": args.class_confidence,
                    "probabilities": {
                        args.class_choice: args.class_confidence,
                        "none": max(0.0, 1.0 - args.class_confidence),
                    },
                }
                if args.class_confidence_raw:
                    answers["class"]["confidence"] = "__RAW_CLASS__"
            if args.drop != "effort":
                answers["effort"] = {
                    "type": "choice",
                    "choice": args.effort_choice,
                    "confidence": args.effort_confidence,
                    "probabilities": {
                        args.effort_choice: args.effort_confidence,
                        "none": max(0.0, 1.0 - args.effort_confidence),
                    },
                }
                if args.effort_confidence_raw:
                    answers["effort"]["confidence"] = "__RAW_EFFORT__"
            answer = {
                "model": "jev-fake",
                "answers": answers,
                "usage": {"input_tokens": 42, "output_tokens": 9},
            }
            body = json.dumps(answer)
            if args.class_confidence_raw:
                body = body.replace('"__RAW_CLASS__"', args.class_confidence_raw)
            if args.effort_confidence_raw:
                body = body.replace('"__RAW_EFFORT__"', args.effort_confidence_raw)
            self._respond(200, body.encode("utf-8"))

    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(args.port_file, "w", encoding="utf-8") as fh:
        fh.write("%d\n" % server.server_address[1])
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
