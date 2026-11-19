"""Unit tests for the agentcore_discovery_record filter: module outputs -> discovery record."""

import copy
import json
import pathlib

import pytest

from ansible_collections.mlowcher61.ai_governance.plugins.filter.discovery_record import _ts, agentcore_discovery_record

REPO = pathlib.Path(__file__).resolve().parents[8]
FIXTURES = REPO / "policies" / "fixtures" / "discovery"
NAMES = ["payments_dispute_assistant", "quick_helper_bot", "hr_faq_agent", "research_runtime"]


def module_outputs(fixture):
    """What agentcore_runtime_info, iam_role_permissions_info and iam_policy_simulation_info return for a runtime."""
    ident = fixture["identity"]
    attrs = fixture["attributes"]
    runtime = {"id": fixture["external_id"], "name": fixture["name"], "arn": fixture["resource_ref"], "status": fixture["status"],
               "version": attrs["agent_runtime_version"], "description": attrs["description"], "role_arn": ident["principal_ref"],
               "network_mode": attrs["network_mode"], "protocol": attrs["protocol"], "authorizer": attrs["authorizer"],
               "code_runtime": attrs["code_runtime"], "endpoints": attrs["endpoints"], "tags": fixture["tags"],
               "created_at": "2026-11-10T09:12:00.415000+00:00", "updated_at": "2026-11-16T22:40:00+00:00",
               "evidence_status": {"agent": "collected", "tags": "collected"}, "errors": []}
    role = {"identity": {k: ident[k] for k in ("principal_ref", "permissions_boundary_ref", "trust_policy", "tags", "policies")},
            "evidence_status": "collected", "errors": []}
    sim = {"simulation": ident["simulation"], "evidence_status": "collected", "errors": []}
    return runtime, role, sim


@pytest.mark.parametrize("name", NAMES)
def test_rebuilds_the_demo_fixture_exactly(name):
    fixture = json.loads((FIXTURES / f"{name}.json").read_text())
    runtime, role, sim = module_outputs(fixture)
    record = agentcore_discovery_record(runtime, account_ref="111122223333", region="us-west-1", identity=role, simulation=sim,
                                        collected_at="2026-11-17T15:00:00Z")
    assert record == fixture


def test_identity_access_denied_keeps_role_and_marks_evidence():
    fixture = json.loads((FIXTURES / "quick_helper_bot.json").read_text())
    runtime = module_outputs(fixture)[0]
    role = {"identity": {"principal_ref": None, "policies": []}, "evidence_status": "access_denied", "errors": [{"code": "AccessDenied"}]}
    record = agentcore_discovery_record(runtime, "111122223333", "us-west-1", identity=role,
                                        simulation={"simulation": {}, "evidence_status": "access_denied"})
    assert record["evidence_status"]["identity"] == "access_denied"
    assert record["evidence_status"]["identity_simulation"] == "access_denied"
    assert record["identity"]["principal_ref"] == runtime["role_arn"] and record["identity"]["policies"] == []


def test_unreadable_runtime_has_no_identity():
    runtime = {"id": "rt-1", "name": "x", "arn": "arn:aws:bedrock-agentcore:us-west-1:1:runtime/rt-1", "role_arn": None,
               "tags": {}, "evidence_status": {"agent": "access_denied", "tags": "collected"}}
    record = agentcore_discovery_record(copy.deepcopy(runtime), "1", "us-west-1")
    assert record["identity"] is None
    assert record["evidence_status"]["agent"] == "access_denied" and record["evidence_status"]["identity"] == "not_collected"


def test_environment_comes_from_the_tag_lowercased_or_null():
    base = {"id": "rt", "name": "n", "arn": "a", "role_arn": None}
    assert agentcore_discovery_record(dict(base, tags={"Environment": "Production "}), "1", "r")["environment"] == "production"
    assert agentcore_discovery_record(dict(base, tags={}), "1", "r")["environment"] is None
    assert agentcore_discovery_record(dict(base, tags={"Env": "dev"}), "1", "r", environment_tag="Env")["environment"] == "dev"


@pytest.mark.parametrize("raw,expected", [
    ("2026-11-10T09:12:00.415000+00:00", "2026-11-10T09:12:00Z"),
    ("2026-11-10 09:12:00+00:00", "2026-11-10T09:12:00Z"),
    ("2026-11-10T09:12:00-05:00", "2026-11-10T09:12:00-05:00"),
    (None, None),
])
def test_timestamps(raw, expected):
    assert _ts(raw) == expected
