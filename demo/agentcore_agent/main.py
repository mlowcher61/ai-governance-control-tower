"""Minimal demo agent for Amazon Bedrock AgentCore Runtime (HTTP protocol contract).

This agent exists only to give the AI Governance Control Tower real AgentCore
runtimes to discover, evaluate, and remediate. It deliberately does NOT call a
foundation model, read data, or use tools, so it costs nothing to run and cannot
leak data. Governance findings come from the runtime's configuration and its IAM
execution role, not from what the agent does.

Contract implemented (see the AgentCore Runtime HTTP protocol contract):
  * listens on 0.0.0.0:8080
  * GET  /ping         -> 200 {"status": "Healthy"}
  * POST /invocations  -> 200 {"response": "...", "status": "success"}

Standard library only, so the direct-code-deployment package is a single file.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AGENT_NAME = os.environ.get("AGENT_NAME", "aigov_demo_agent")
PORT = int(os.environ.get("PORT", "8080"))
MAX_PROMPT_CHARS = 2000


class AgentHandler(BaseHTTPRequestHandler):
    """Serve the AgentCore HTTP protocol contract."""

    server_version = "aigov-demo-agent/1.0"

    def _send_json(self, status_code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/ping":
            self._send_json(200, {"status": "Healthy"})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/invocations":
            self._send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            request = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, {"error": "request body must be JSON"})
            return
        prompt = str(request.get("prompt", ""))[:MAX_PROMPT_CHARS]
        self._send_json(
            200,
            {
                "response": f"[{AGENT_NAME}] demo agent received {len(prompt)} characters. "
                "This governance demo agent does not call a model.",
                "status": "success",
            },
        )

    def log_message(self, format, *args):  # noqa: A002 - signature defined by base class
        # Send access logs to stdout so they reach CloudWatch Logs.
        sys.stdout.write("%s - %s\n" % (self.address_string(), format % args))
        sys.stdout.flush()


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), AgentHandler)  # nosec B104 - required by the AgentCore contract
    print(f"{AGENT_NAME} listening on 0.0.0.0:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
