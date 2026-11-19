#!/usr/bin/env python3
"""Contract test through the Inventory API (T1.03): discovery fixtures in -> policy inputs out.

Loads policies/fixtures/registry.json (api.load_registry) and the four demo discovery records
(api.record_discovery), reads api.evaluation_inputs, adds the 'evaluation' block the Evaluate job adds,
and checks that each result:
  * validates against schemas/policy-input.v1.json, and
  * equals policies/fixtures/inputs/<agent>.json (except agent.id, which the database assigns).
So the database view and the policy contract cannot drift apart.

    AIGOV_API_URL=http://127.0.0.1:3000 AIGOV_JWT_SECRET=... python3 database/tests/test_contracts_api.py

Needs: jsonschema >= 4.18. Writes to the database: run it only against a test database.
"""

import base64
import hashlib
import hmac
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "policies" / "fixtures"
API = os.environ["AIGOV_API_URL"].rstrip("/")
SECRET = os.environ["AIGOV_JWT_SECRET"]


def token(role):
    def b64(data):
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

    now = int(time.time())
    parts = [{"alg": "HS256", "typ": "JWT"}, {"role": role, "sub": "contract-test", "iat": now, "exp": now + 600}]
    signing_input = ".".join(b64(json.dumps(p).encode()) for p in parts)
    return signing_input + "." + b64(hmac.new(SECRET.encode(), signing_input.encode(), hashlib.sha256).digest())


def call(method, path, role, body=None):
    req = urllib.request.Request(API + path, method=method, data=None if body is None else json.dumps(body).encode())
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + token(role))
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as err:
        sys.exit(f"{method} {path} as {role}: HTTP {err.code} {err.read().decode(errors='replace')}")


schemas = [json.loads(p.read_text()) for p in sorted((ROOT / "schemas").glob("*.v1.json"))]
registry = Registry().with_resources((s["$id"], Resource.from_contents(s)) for s in schemas)
policy_input = Draft202012Validator({"$ref": "https://github.com/mlowcher61/ai-governance-control-tower/schemas/policy-input.v1.json"},
                                    registry=registry)

# 1. Registry, then discovery (same order as production: registry load re-matches agents anyway)
reg = json.loads((FIXTURES / "registry.json").read_text())
print("load_registry:", call("POST", "/rpc/load_registry", "aigov_registry",
                             {"owners": reg["owners"], "registrations": reg["registrations"], "source_commit": "fixtures"}))
records = [json.loads(p.read_text()) for p in sorted((FIXTURES / "discovery").glob("*.json"))]
run = call("POST", "/rpc/start_discovery_run", "aigov_discovery",
           {"scope": {"provider": "aws", "account_ref": records[0]["account_ref"], "regions": [records[0]["region"]]}})
res = call("POST", "/rpc/record_discovery", "aigov_discovery", {"discovery_run_id": run["discovery_run_id"], "records": records})
call("POST", "/rpc/complete_discovery_run", "aigov_discovery",
     {"discovery_run_id": run["discovery_run_id"], "status": "succeeded", "counts": {"agents": len(records)}, "errors": []})
print("record_discovery:", [(r["external_id"], r["change"]) for r in res])

# 2. Policy inputs out of the database vs the fixtures
rows = call("GET", "/evaluation_inputs?select=agent_id,input", "aigov_evaluator")
by_name = {r["input"]["agent"]["name"]: r["input"] for r in rows}
failures = 0
for path in sorted((FIXTURES / "inputs").glob("*.json")):
    expected = json.loads(path.read_text())
    actual = by_name.get(path.stem)
    if actual is None:
        print(f"FAIL  {path.stem}: not in api.evaluation_inputs")
        failures += 1
        continue
    actual = dict(actual, evaluation=expected["evaluation"])
    errors = [f"{list(e.absolute_path)}: {e.message}" for e in policy_input.iter_errors(actual)]
    actual["agent"] = dict(actual["agent"], id=expected["agent"]["id"])
    if errors:
        print(f"FAIL  {path.stem}: not a valid policy input: {errors[:3]}")
        failures += 1
    elif actual != expected:
        diff = [k for k in expected if actual.get(k) != expected[k]]
        print(f"FAIL  {path.stem}: differs from the fixture in {diff}")
        for k in diff:
            print("      expected", json.dumps(expected[k], sort_keys=True)[:600])
            print("      actual  ", json.dumps(actual.get(k), sort_keys=True)[:600])
        failures += 1
    else:
        print(f"ok    {path.stem}: api.evaluation_inputs equals the fixture and validates")

print(f"\n{failures} failure(s)" if failures else "\nall contract checks passed")
sys.exit(1 if failures else 0)
