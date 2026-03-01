#!/usr/bin/env python3
"""
NoMercy CI — GitHub Webhook Receiver
Listens for GitHub "release published" events and triggers run_matrix.sh.

Configuration via environment variables (see webhook_server.env):
  GITHUB_SECRET   Required. Webhook secret set in GitHub → Settings → Webhooks.
  WEBHOOK_PORT    Optional. Port to listen on (default: 9000).
  CI_ROOT         Optional. Path to CI scripts (default: /opt/nomercy-ci).
  ARTIFACT_ROOT   Optional. Artifact storage root (default: /mnt/nomercy-artifacts).
"""

import hashlib
import hmac
import http.server
import json
import logging
import os
import subprocess
import sys
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("nomercy-ci-webhook")

GITHUB_SECRET = os.environ.get("GITHUB_SECRET", "").encode()
WEBHOOK_PORT  = int(os.environ.get("WEBHOOK_PORT", "9000"))
CI_ROOT       = Path(os.environ.get("CI_ROOT", "/opt/nomercy-ci"))
ARTIFACT_ROOT = Path(os.environ.get("ARTIFACT_ROOT", "/mnt/nomercy-artifacts"))

if not GITHUB_SECRET:
    log.error("GITHUB_SECRET environment variable is not set. Refusing to start.")
    sys.exit(1)


def verify_signature(payload: bytes, signature_header: str) -> bool:
    """Validate X-Hub-Signature-256 against GITHUB_SECRET."""
    if not signature_header or not signature_header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(GITHUB_SECRET, payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature_header)


def trigger_matrix(tag: str) -> None:
    """Spawn run_matrix.sh in the background, streaming output to artifact log."""
    script = CI_ROOT / "run_matrix.sh"
    if not script.exists():
        log.error("run_matrix.sh not found at %s", script)
        return

    log_dir = ARTIFACT_ROOT / tag
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "webhook.log"

    log.info("Triggering matrix for release %s → log: %s", tag, log_file)

    with open(log_file, "a") as lf:
        subprocess.Popen(
            ["bash", str(script), tag],
            stdout=lf,
            stderr=subprocess.STDOUT,
            close_fds=True,
        )


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # suppress default access log
        log.debug(fmt, *args)

    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(content_length)

        # Validate HMAC signature
        sig = self.headers.get("X-Hub-Signature-256", "")
        if not verify_signature(payload, sig):
            log.warning("Invalid signature from %s", self.client_address[0])
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"Invalid signature\n")
            return

        # Parse event type
        event = self.headers.get("X-GitHub-Event", "")
        if event != "release":
            log.info("Ignoring event type: %s", event)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Ignored\n")
            return

        # Parse payload
        try:
            data = json.loads(payload)
        except json.JSONDecodeError:
            log.error("Failed to parse JSON payload")
            self.send_response(400)
            self.end_headers()
            return

        action = data.get("action", "")
        tag = data.get("release", {}).get("tag_name", "")

        if action != "published":
            log.info("Ignoring release action: %s", action)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Ignored\n")
            return

        if not tag:
            log.error("No tag_name in release payload")
            self.send_response(400)
            self.end_headers()
            return

        log.info("Release published: %s — spawning matrix run", tag)
        trigger_matrix(tag)

        # Return immediately; the matrix run is async
        self.send_response(202)
        self.end_headers()
        self.wfile.write(f"Matrix run triggered for {tag}\n".encode())

    def do_GET(self):
        """Health check endpoint."""
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK\n")
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", WEBHOOK_PORT), WebhookHandler)
    log.info("Webhook server listening on port %d", WEBHOOK_PORT)
    log.info("CI root : %s", CI_ROOT)
    log.info("Artifact root: %s", ARTIFACT_ROOT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
