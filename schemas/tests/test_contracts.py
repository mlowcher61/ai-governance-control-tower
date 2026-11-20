"""Contract tests (T1.03): every schema is valid JSON Schema 2020-12, every fixture and valid example
passes its schema, and every invalid example is rejected.

    python -m pytest -q schemas/tests

Layout:
    schemas/<name>.v1.json                          the contracts
    schemas/examples/<name>/{valid,invalid}/*.json  examples for <name>.v1.json
    schemas/examples/artifacts/<job>/{valid,invalid}/*.json   examples for artifacts.v1.json#/$defs/<job>
    policies/fixtures/discovery/*.json              discovery-record.v1.json (the four demo agents)
    policies/fixtures/inputs/*.json                 policy-input.v1.json
    policies/fixtures/registry.json                 registry.v1.json
"""

import json
import pathlib

import pytest
from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "schemas"
EXAMPLES = SCHEMAS / "examples"
FIXTURES = ROOT / "policies" / "fixtures"
BASE = "https://github.com/mlowcher61/ai-governance-control-tower/schemas/"

SCHEMA_FILES = sorted(SCHEMAS.glob("*.v1.json"))
REGISTRY = Registry().with_resources(
    (json.loads(p.read_text())["$id"], Resource.from_contents(json.loads(p.read_text()))) for p in SCHEMA_FILES
)


def validator(schema_name, pointer=""):
    schema = {"$ref": BASE + schema_name + pointer}
    return Draft202012Validator(schema, registry=REGISTRY)


def load(path):
    return json.loads(path.read_text())


def cases(kind):
    """(validator target, file) pairs for valid or invalid examples."""
    out = []
    for path in sorted(EXAMPLES.glob(f"*/{kind}/*.json")):
        out.append((path.parts[-3] + ".v1.json", "", path))
    for path in sorted(EXAMPLES.glob(f"artifacts/*/{kind}/*.json")):
        out.append(("artifacts.v1.json", "#/$defs/" + path.parts[-3], path))
    return out


def ids(params):
    return [str(p[2].relative_to(EXAMPLES)) for p in params]


@pytest.mark.parametrize("path", SCHEMA_FILES, ids=lambda p: p.name)
def test_schema_is_valid_2020_12(path):
    schema = load(path)
    Draft202012Validator.check_schema(schema)
    assert schema["$id"] == BASE + path.name, "the $id must match the file name"


@pytest.mark.parametrize(
    "schema_name,path",
    [("discovery-record.v1.json", p) for p in sorted((FIXTURES / "discovery").glob("*.json"))]
    + [("policy-input.v1.json", p) for p in sorted((FIXTURES / "inputs").glob("*.json"))]
    + [("registry.v1.json", FIXTURES / "registry.json")],
    ids=lambda v: v.name if isinstance(v, pathlib.Path) else v,
)
def test_fixture_matches_contract(schema_name, path):
    errors = sorted(validator(schema_name).iter_errors(load(path)), key=str)
    assert not errors, "\n".join(f"{list(e.absolute_path)}: {e.message}" for e in errors)


VALID = cases("valid")
INVALID = cases("invalid")


@pytest.mark.parametrize("schema_name,pointer,path", VALID, ids=ids(VALID))
def test_valid_example(schema_name, pointer, path):
    errors = sorted(validator(schema_name, pointer).iter_errors(load(path)), key=str)
    assert not errors, "\n".join(f"{list(e.absolute_path)}: {e.message}" for e in errors)


@pytest.mark.parametrize("schema_name,pointer,path", INVALID, ids=ids(INVALID))
def test_invalid_example_is_rejected(schema_name, pointer, path):
    assert not validator(schema_name, pointer).is_valid(load(path)), f"{path.name} should be rejected"


def test_every_schema_has_examples_or_fixtures():
    covered = {c[0] for c in VALID + INVALID} | {"discovery-record.v1.json", "policy-input.v1.json", "registry.v1.json"}
    documents = {p.name for p in SCHEMA_FILES} - {"common.v1.json"}
    assert documents <= covered, f"no examples for {sorted(documents - covered)}"


def test_fixtures_cover_the_four_demo_agents():
    names = {"payments_dispute_assistant", "quick_helper_bot", "hr_faq_agent", "research_runtime"}
    assert {p.stem for p in (FIXTURES / "discovery").glob("*.json")} == names
    assert {p.stem for p in (FIXTURES / "inputs").glob("*.json")} == names


def test_artifact_findings_string_holds_valid_findings():
    """The evaluate artifact carries findings as JSON text; the decoded text must match its own contract."""
    artifact = load(EXAMPLES / "artifacts" / "evaluate" / "valid" / "needs-explanation.json")
    decoded = json.loads(artifact["findings_for_explanation"])
    assert validator("findings-for-explanation.v1.json").is_valid(decoded)
    assert len(decoded) == int(artifact["explain_count"])


# ---- Bundled copies (schemas/bundled/, used by ansible.utils.validate in playbooks) ----------------

BUNDLED = SCHEMAS / "bundled"


def bundled_validator(schema_name, pointer=""):
    schema = load(BUNDLED / schema_name)
    if pointer:
        schema = dict(schema, **{"$ref": pointer})
    return Draft202012Validator(schema)  # no registry: a bundle must be self-contained


def test_bundles_are_up_to_date():
    import subprocess
    import sys

    result = subprocess.run([sys.executable, str(ROOT / "scripts" / "bundle_schemas.py"), "--check"], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr or result.stdout


@pytest.mark.parametrize("schema_name,pointer,path", VALID + INVALID, ids=ids(VALID + INVALID))
def test_bundle_agrees_with_source(schema_name, pointer, path):
    data = load(path)
    assert bundled_validator(schema_name, pointer).is_valid(data) == validator(schema_name, pointer).is_valid(data)


@pytest.mark.parametrize("path", sorted((FIXTURES / "discovery").glob("*.json")), ids=lambda p: p.name)
def test_bundled_discovery_record_accepts_fixtures(path):
    assert bundled_validator("discovery-record.v1.json").is_valid(load(path))


# ---- The governance registry as code (inventory/registry/) ---------------------------------------------


def load_registry_files(account="111122223333"):
    import yaml

    reg_dir = ROOT / "inventory" / "registry"
    text = {name: (reg_dir / f"{name}.yml").read_text().replace("{{ aigov_aws_account_id | string }}", account)
            for name in ("owners", "registrations")}
    return {"owners": yaml.safe_load(text["owners"])["aigov_owners"],
            "registrations": yaml.safe_load(text["registrations"])["aigov_registrations"]}


def test_registry_files_match_the_contract():
    errors = [f"{list(e.absolute_path)}: {e.message}" for e in validator("registry.v1.json").iter_errors(load_registry_files())]
    assert not errors, errors


def test_registry_files_describe_the_fixture_scenario():
    """The demo registry and the fixture registry must not drift: same owners, same registrations."""
    files, fixture = load_registry_files(), load(FIXTURES / "registry.json")
    assert files["owners"] == fixture["owners"]

    def strip(regs):
        return [{k: v for k, v in r.items() if k != "match_keys"} for r in regs]

    assert strip(files["registrations"]) == strip(fixture["registrations"])
    for f, x in zip(files["registrations"], fixture["registrations"]):
        assert f["match_keys"]["name"] == x["match_keys"]["name"]
        assert f["match_keys"]["account_ref"] == "111122223333"


def test_quick_helper_bot_is_deliberately_unregistered():
    names = [r["match_keys"].get("name") for r in load_registry_files()["registrations"]]
    assert "quick_helper_bot" not in names


# ---- The demo reset baseline matches the CloudFormation that created the demo agents ----------------------


def _cfn_load(path):
    import yaml

    class Loader(yaml.SafeLoader):
        pass

    def any_tag(loader, suffix, node):
        if isinstance(node, yaml.ScalarNode):
            return {"Fn::" + suffix: loader.construct_scalar(node)}
        if isinstance(node, yaml.SequenceNode):
            return {"Fn::" + suffix: loader.construct_sequence(node)}
        return {"Fn::" + suffix: loader.construct_mapping(node)}

    Loader.add_multi_constructor("!", any_tag)
    return yaml.load(path.read_text(), Loader=Loader)


def test_demo_baseline_matches_cloudformation():
    import yaml

    cfn = _cfn_load(ROOT / "aws" / "cloudformation" / "aigov-demo-agents.yaml")
    baseline = yaml.safe_load((ROOT / "playbooks" / "demo" / "vars" / "demo_baseline.yml").read_text())["aigov_demo_baseline"]
    runtimes = {r["Properties"]["AgentRuntimeName"]: r["Properties"] for r in cfn["Resources"].values()
                if r["Type"] == "AWS::BedrockAgentCore::Runtime"}
    roles = {r["Properties"]["RoleName"]: r["Properties"] for r in cfn["Resources"].values() if r["Type"] == "AWS::IAM::Role"}
    assert {b["runtime"] for b in baseline} == set(runtimes)
    # The stack tags in the baseline are the ones the deploy playbook gives the demo stack
    stack_tags = yaml.safe_load((ROOT / "playbooks" / "demo" / "vars" / "demo_baseline.yml").read_text())["aigov_demo_stack_tags"]
    deploy = yaml.safe_load((ROOT / "playbooks" / "demo" / "deploy_demo_agents.yml").read_text())
    deploy_tags = [t["amazon.aws.cloudformation"]["tags"] for t in deploy[0]["tasks"]
                   if "amazon.aws.cloudformation" in t and "aigov-demo-agents" in str(t["amazon.aws.cloudformation"].get("template_body", ""))]
    assert deploy_tags and all(d == stack_tags for d in deploy_tags)
    for b in baseline:
        assert {str(k): str(v) for k, v in runtimes[b["runtime"]]["Tags"].items()} == b["tags"], b["runtime"]
        assert b["runtime_arn_output"] in cfn["Outputs"]
        cfn_policies = roles[b["role_name"]]["ManagedPolicyArns"]
        wanted = ["approved" if "ApprovedAgentRuntimePolicyArn" in json.dumps(p) else p.get("Fn::Sub", p) if isinstance(p, dict) else p
                  for p in cfn_policies]
        wanted = [w.replace("${AWS::Partition}", "aws") for w in wanted]
        assert wanted == b["managed_policies"], b["role_name"]


# ---- Remediation profiles (policies/data, policies/overlays) -----------------------------------------------


def test_demo_overlay_matches_the_default_remediation_settings():
    default = load(ROOT / "policies" / "data" / "governance" / "config" / "data.json")["remediation"]
    overlay = {k: v for k, v in load(ROOT / "policies" / "overlays" / "demo" / "remediation.json").items() if k != "_comment"}
    catalog = load(ROOT / "policies" / "data" / "governance" / "remediation_catalog" / "data.json")
    assert set(overlay) == set(default), "the overlay must replace every remediation setting"
    assert default["enabled"] is False and default["mode"] == "detect_only", "the committed default must stay detection-only"
    assert overlay["allowed_accounts"] == [], "the account is filled in at publish time, never committed"
    assert all(catalog[a]["auto_eligible"] for a in overlay["auto_remediation_actions"])
