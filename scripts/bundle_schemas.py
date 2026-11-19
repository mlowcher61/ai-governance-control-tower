#!/usr/bin/env python3
"""Write self-contained copies of the v1 contracts to schemas/bundled/.

Ansible's ansible.utils.validate (jsonschema engine) cannot follow $ref links to other files, so the
playbooks validate against these bundles: the shared definitions from common.v1.json are copied in
under "$defs" (prefixed "common_") and every reference is rewritten to point inside the file.

    python3 scripts/bundle_schemas.py          # rewrite the bundles
    python3 scripts/bundle_schemas.py --check  # fail if a bundle is out of date (CI)
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / "schemas"
OUT = ROOT / "bundled"
COMMON = json.loads((ROOT / "common.v1.json").read_text())


def rewrite(node, own_prefix):
    if isinstance(node, dict):
        out = {}
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str):
                if value.startswith("common.v1.json#/$defs/"):
                    value = "#/$defs/common_" + value.split("/")[-1]
                elif value.startswith("#/$defs/") and own_prefix:
                    value = "#/$defs/" + own_prefix + value.split("/")[-1]
                elif value.endswith(".v1.json"):
                    value = "#/$defs/doc_" + value[: -len(".v1.json")].replace("-", "_")
            out[key] = rewrite(value, own_prefix)
        return out
    if isinstance(node, list):
        return [rewrite(v, own_prefix) for v in node]
    return node


def bundle(path):
    schema = json.loads(path.read_text())
    out = rewrite({k: v for k, v in schema.items() if k != "$defs"}, "")
    out["$id"] = schema["$id"].replace("/schemas/", "/schemas/bundled/")
    defs = {k: rewrite(v, "") for k, v in schema.get("$defs", {}).items()}
    defs.update({"common_" + k: rewrite(v, "common_") for k, v in COMMON["$defs"].items()})
    # Whole-document references (evaluation-result -> policy-result) are embedded too.
    for other in ROOT.glob("*.v1.json"):
        name = other.name[: -len(".v1.json")]
        if other != path and ('"' + other.name + '"') in path.read_text():
            doc = json.loads(other.read_text())
            embedded = rewrite({k: v for k, v in doc.items() if k not in ("$defs", "$id", "$schema")}, "")
            defs["doc_" + name.replace("-", "_")] = embedded
    out["$defs"] = dict(sorted(defs.items()))
    return json.dumps(out, indent=2, sort_keys=False) + "\n"


def main():
    check = "--check" in sys.argv
    stale = []
    OUT.mkdir(exist_ok=True)
    for path in sorted(ROOT.glob("*.v1.json")):
        if path.name == "common.v1.json":
            continue
        text = bundle(path)
        target = OUT / path.name
        if check:
            if not target.exists() or target.read_text() != text:
                stale.append(target.name)
        else:
            target.write_text(text)
    if stale:
        sys.exit("out of date bundles (run python3 scripts/bundle_schemas.py): " + ", ".join(stale))
    print("bundles " + ("up to date" if check else "written"))


if __name__ == "__main__":
    main()
