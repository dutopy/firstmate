#!/usr/bin/env python3
"""Fake typesafe.ai System One endpoint for the Jev classifier tests.

Binds 127.0.0.1 on an ephemeral port (port 0), writes the chosen port to
--port-file so a test can point TYPESAFE_BASE_URL at it, then answers every
POST /v1/systemone with one canned Choice answer. The tests never reach the
real API.

Usage:
  python3 jev-classify-fake-typesafe.py --port-file <path> --log-dir <dir> \
      [--choice <optionId>] [--confidence <0..1>] [--status <http-code>] \
      [--delay <seconds>] [--body-file <path>] [--answers-file <path>] \
      [--answers-map-file <path>] [--threaded]

Each request appends its path to <log-dir>/requests and rewrites <log-dir>/
path, <log-dir>/auth, and <log-dir>/body, so a test can assert both what the
classifier sent and how many calls it made. --status != 200 answers that status
with a small JSON error body, --body-file answers 200 with exactly those bytes
instead of the canned Choice answer, and --delay sleeps before answering so a
test can exercise a classifier's wall-clock bound.
--answers-file answers 200 with the `answers` object read from that JSON file
wrapped in the usual model/usage envelope, which is how a multi-question caller
(the console request preparation asks intent, project, and entity at once) is
driven; --choice and --confidence keep their single-answer behavior.
--answers-map-file answers the same way but chooses per request: the file maps a
question key to its `answers` object, and the entry whose key appears in the
incoming request's `questions` is served, so one fake can serve a console that
asks the route question and the preparation questions through the same base URL.
--threaded serves with a threading server so a test can prove that two callers
overlap, and every request appends its start and end epoch to
<log-dir>/times.jsonl so that overlap is measurable rather than asserted.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--choice", default="real_business_blocker")
    parser.add_argument("--confidence", type=float, default=0.97)
    parser.add_argument("--status", type=int, default=200)
    parser.add_argument("--delay", type=float, default=0.0)
    parser.add_argument("--body-file", default="")
    parser.add_argument("--answers-file", default="")
    parser.add_argument("--answers-map-file", default="")
    parser.add_argument("--threaded", action="store_true")
    args = parser.parse_args()
    os.makedirs(args.log_dir, exist_ok=True)
    override = b""
    if args.body_file:
        with open(args.body_file, "rb") as fh:
            override = fh.read()
    multi = {}
    if args.answers_file:
        with open(args.answers_file, encoding="utf-8") as fh:
            multi = json.load(fh)
        if not isinstance(multi, dict):
            raise SystemExit("--answers-file must hold a JSON object of answers")
    answer_map = {}
    if args.answers_map_file:
        with open(args.answers_map_file, encoding="utf-8") as fh:
            answer_map = json.load(fh)
        if not isinstance(answer_map, dict):
            raise SystemExit("--answers-map-file must hold a JSON object of answers objects")

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
            started = time.time()
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length)
            self._record(body)
            with open(os.path.join(args.log_dir, "times.jsonl"), "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"start": started}) + "\n")
            if args.delay > 0:
                time.sleep(args.delay)
            with open(os.path.join(args.log_dir, "times.jsonl"), "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"end": time.time()}) + "\n")
            if args.status != 200:
                self._respond(args.status, b'{"error":"fake upstream failure"}')
                return
            if args.body_file:
                self._respond(200, override)
                return
            answers = multi if args.answers_file else {
                "route": {
                    "type": "choice",
                    "choice": args.choice,
                    "confidence": args.confidence,
                    "probabilities": {args.choice: args.confidence},
                }
            }
            if args.answers_map_file:
                try:
                    asked = json.loads(body.decode("utf-8")).get("questions") or {}
                except Exception:
                    asked = {}
                if not isinstance(asked, dict):
                    asked = {}
                for key, entry in answer_map.items():
                    if key in asked:
                        answers = entry
                        break
            answer = {
                "model": "jev-fake",
                "answers": answers,
                "usage": {"input_tokens": 11, "output_tokens": 4},
            }
            self._respond(200, json.dumps(answer).encode("utf-8"))

    server_class = ThreadingHTTPServer if args.threaded else HTTPServer
    server = server_class(("127.0.0.1", 0), Handler)
    with open(args.port_file, "w", encoding="utf-8") as fh:
        fh.write("%d\n" % server.server_address[1])
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
