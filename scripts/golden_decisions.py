#!/usr/bin/env python3
"""Golden decisions (T1.08/T1.09): evaluate every policy-input fixture with OPA and compare the result
with policies/fixtures/expected/<agent>.json. Every result must also match the contract
schemas/evaluation-result.v1.json.

    python3 scripts/golden_decisions.py            # check (CI)
    python3 scripts/golden_decisions.py --update   # rewrite the expected files after an intended change

Needs the opa binary (OPA env var, default "opa") and jsonschema >= 4.18.
"""

import json
import os
import pathlib
import subprocess
import sys

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = pathlib.Path(__file__).resolve().parents[1]
INPUTS = ROOT / "policies" / "fixtures" / "inputs"
EXPECTED = ROOT / "policies" / "fixtures" / "expected"
OPA = os.environ.get("OPA", "opa")

schemas = [json.loads(p.read_text()) for p in (ROOT / "schemas").glob("*.v1.json")]
registry = Registry().with_resources((s["$id"], Resource.from_contents(s)) for s in schemas)
contract = Draft202012Validator(
    {"$ref": "https://github.com/mlowcher61/ai-governance-control-tower/schemas/evaluation-result.v1.json"}, registry=registry)


def evaluate(path):
    out = subprocess.run(
        [OPA, "eval", "--format", "json", "--data", str(ROOT / "policies" / "governance"), "--data", str(ROOT / "policies" / "data"),
         "--input", str(path), "data.governance.evaluate.result"],
        check=True, capture_output=True, text=True).stdout
    return json.loads(out)["result"][0]["expressions"][0]["value"]


def main():
    update = "--update" in sys.argv
    EXPECTED.mkdir(exist_ok=True)
    failures = 0
    for path in sorted(INPUTS.glob("*.json")):
        result = evaluate(path)
        errors = [f"{list(e.absolute_path)}: {e.message}" for e in contract.iter_errors(result)]
        if errors:
            print(f"FAIL  {path.stem}: result breaks the contract: {errors[:3]}")
            failures += 1
            continue
        target = EXPECTED / path.name
        text = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if update:
            target.write_text(text)
            print(f"wrote {target.relative_to(ROOT)} ({result['overall_status']}, risk {result['risk']['score']})")
        elif not target.exists() or json.loads(target.read_text()) != result:
            expected = json.loads(target.read_text()) if target.exists() else {}
            changed = sorted(k for k in set(result) | set(expected) if result.get(k) != expected.get(k))
            print(f"FAIL  {path.stem}: decision differs from {target.relative_to(ROOT)} in {changed}")
            failures += 1
        else:
            print(f"ok    {path.stem}: {result['overall_status']}, risk {result['risk']['score']} {result['risk']['category']}")
    if failures:
        sys.exit(f"{failures} golden decision(s) failed. If the change is intended, run with --update and review the diff.")


if __name__ == "__main__":
    main()
