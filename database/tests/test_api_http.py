#!/usr/bin/env python3
"""HTTP tests for the Governance Inventory API (PostgREST over the V002 api schema), task T1.02.

Mints one JWT per API role with the PostgREST secret and checks role switching end to end:
OpenAPI is exposed, each token runs as its role, a role cannot call another role's function,
anonymous and expired tokens are refused, and the discovery RPCs work over HTTP.

    AIGOV_API_URL=http://127.0.0.1:3000 AIGOV_JWT_SECRET=... python3 database/tests/test_api_http.py

Standard library only. Writes test rows (account 000000000000) unless AIGOV_API_READONLY=1.
"""

import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = os.environ["AIGOV_API_URL"].rstrip("/")
SECRET = os.environ["AIGOV_JWT_SECRET"]
READONLY = os.environ.get("AIGOV_API_READONLY") == "1"
ROLES = ["aigov_discovery", "aigov_registry", "aigov_evaluator", "aigov_remediator", "aigov_reader", "aigov_auditor"]
failures = []


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token(role, ttl=600):
    now = int(time.time())
    parts = [{"alg": "HS256", "typ": "JWT"}, {"role": role, "sub": "http-test-" + role, "iat": now, "exp": now + ttl}]
    signing_input = ".".join(b64url(json.dumps(p, separators=(",", ":")).encode()) for p in parts)
    sig = hmac.new(SECRET.encode(), signing_input.encode(), hashlib.sha256).digest()
    return signing_input + "." + b64url(sig)


def call(method, path, tok=None, body=None):
    req = urllib.request.Request(API + path, method=method, data=None if body is None else json.dumps(body).encode())
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if tok:
        req.add_header("Authorization", "Bearer " + tok)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        raw = err.read()
        try:
            return err.code, json.loads(raw)
        except ValueError:
            return err.code, raw.decode(errors="replace")


def check(name, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + name + ("" if ok else "  -> " + str(detail)[:400]))
    if not ok:
        failures.append(name)


# Liveness (anonymous) and OpenAPI
status, body = call("GET", "/rpc/health")
check("anonymous GET /rpc/health is 200", status == 200 and body.get("status") == "ok", (status, body))
status, body = call("GET", "/", token("aigov_discovery"))
paths = body.get("paths", {}) if isinstance(body, dict) else {}
check("OpenAPI lists the discovery RPCs for the discovery role",
      status == 200 and "/rpc/record_discovery" in paths and "/rpc/load_registry" not in paths, (status, list(paths)))

# Every role token switches to its own database role
for role in ROLES:
    status, body = call("POST", "/rpc/whoami", token(role), {})
    check(f"{role} token runs as {role}", status == 200 and body == {"role": role, "actor": "http-test-" + role},
          (status, body))

# Refusals
status, _ = call("POST", "/rpc/whoami", None, {})
check("anonymous cannot call whoami", status in (401, 403), status)
status, _ = call("POST", "/rpc/whoami", token("aigov_reader", ttl=-60), {})
check("expired token is refused (401)", status == 401, status)
forged = token("aigov_reader")[:-4] + "AAAA"
status, _ = call("POST", "/rpc/whoami", forged, {})
check("token with a bad signature is refused (401)", status == 401, status)
status, _ = call("POST", "/rpc/start_discovery_run", token("aigov_reader"), {"scope": {"provider": "aws", "account_ref": "000000000000"}})
check("reader cannot start a discovery run", status in (401, 403), status)
status, _ = call("GET", "/evaluation_inputs?limit=1", token("aigov_discovery"))
check("discovery role cannot read evaluation_inputs", status in (401, 403), status)
status, _ = call("GET", "/evaluation_inputs?limit=1", token("aigov_evaluator"))
check("evaluator can read evaluation_inputs", status == 200, status)
status, _ = call("GET", "/agent_overview?limit=1", token("aigov_reader"))
check("reader can read agent_overview", status == 200, status)

# Discovery over HTTP (writes test rows)
if not READONLY:
    disc = token("aigov_discovery")
    status, run = call("POST", "/rpc/start_discovery_run", disc,
                       {"scope": {"provider": "aws", "account_ref": "000000000000", "regions": ["us-west-1"]}})
    check("start_discovery_run over HTTP", status == 200 and "discovery_run_id" in run, (status, run))
    if status == 200:
        record = {"provider": "aws", "platform": "aws.bedrock_agentcore_runtime", "account_ref": "000000000000",
                  "region": "us-west-1", "external_id": "http-test-runtime", "name": "http_test_runtime",
                  "resource_ref": "arn:aws:bedrock-agentcore:us-west-1:000000000000:runtime/http-test-runtime",
                  "status": "READY", "tags": {}, "evidence_status": {"agent": "collected"}}
        status, res = call("POST", "/rpc/record_discovery", disc,
                           {"discovery_run_id": run["discovery_run_id"], "records": [record]})
        check("record_discovery over HTTP", status == 200 and res[0]["change"] in ("new", "unchanged"), (status, res))
        status, res = call("POST", "/rpc/record_discovery", disc,
                           {"discovery_run_id": run["discovery_run_id"], "records": [dict(record, account_ref="9")]})
        check("out-of-scope record is a 400", status == 400, (status, res))
        status, res = call("POST", "/rpc/complete_discovery_run", disc,
                           {"discovery_run_id": run["discovery_run_id"], "status": "partial",
                            "counts": {"agents": 1}, "errors": []})
        check("complete_discovery_run over HTTP", status == 200 and res["status"] == "partial", (status, res))

print(f"\n{len(failures)} failure(s)" if failures else "\nall HTTP checks passed")
sys.exit(1 if failures else 0)
