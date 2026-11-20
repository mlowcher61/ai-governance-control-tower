"""Unit tests for policy_input_refresh and reassessment_outcome."""

import copy
import json
import pathlib

import pytest

from ansible_collections.mlowcher61.ai_governance.plugins.filter.remediation import policy_input_refresh, reassessment_outcome

REPO = pathlib.Path(__file__).resolve().parents[8]
FIX = REPO / "policies" / "fixtures"


def _load(kind, name):
    return json.loads((FIX / kind / f"{name}.json").read_text())


@pytest.mark.parametrize("name", ["payments_dispute_assistant", "quick_helper_bot", "hr_faq_agent", "research_runtime"])
def test_refresh_with_unchanged_state_gives_the_stored_input(name):
    stored = _load("inputs", name)
    stored.pop("evaluation")
    assert policy_input_refresh(stored, _load("discovery", name)) == stored


def test_refresh_takes_the_live_identity_and_keeps_registration():
    stored = _load("inputs", "quick_helper_bot")
    stored.pop("evaluation")
    record = _load("discovery", "quick_helper_bot")
    approved = _load("discovery", "payments_dispute_assistant")["identity"]["policies"]
    record = copy.deepcopy(record)
    record["identity"]["policies"] = approved          # remediated: approved policy instead of AdministratorAccess
    record["identity"]["simulation"] = {k: "denied" for k in record["identity"]["simulation"]}
    out = policy_input_refresh(stored, record)
    assert [p["name"] for p in out["identity"]["policies"]] == ["aigov-approved-agentcore-runtime-basic"]
    assert set(out["identity"]["simulation"].values()) == {"denied"}
    assert out["registration"] == stored["registration"] and out["agent"]["id"] == stored["agent"]["id"]


def test_refresh_keeps_evidence_gaps():
    stored = _load("inputs", "hr_faq_agent")
    record = copy.deepcopy(_load("discovery", "hr_faq_agent"))
    record["evidence_status"]["identity"] = "access_denied"
    assert policy_input_refresh(stored, record)["evidence"]["identity"] == "access_denied"


@pytest.mark.parametrize("decision,assessment", [("pass", "compliant"), ("not_applicable", "compliant"), ("fail", "noncompliant"),
                                                 ("unknown", "missing_evidence"), ("error", "error")])
def test_outcome_per_decision(decision, assessment):
    result = {"overall_status": "noncompliant", "input_errors": [],
              "results": [{"policy_id": "AIGOV-IAM-001", "decision": decision, "severity": "critical"}]}
    out = reassessment_outcome(result, "AIGOV-IAM-001")
    assert out["assessment"] == assessment and out["decision"] == decision


def test_stale_finding_is_compliant():
    """The finding said IAM-001 fails; the live state passes: the finding is stale."""
    golden = json.loads((FIX / "expected" / "payments_dispute_assistant.json").read_text())
    assert reassessment_outcome(golden, "AIGOV-IAM-001")["assessment"] == "compliant"


def test_errors():
    assert reassessment_outcome(None, "AIGOV-IAM-001")["assessment"] == "error"
    assert reassessment_outcome({"overall_status": "error", "results": []}, "AIGOV-IAM-001")["assessment"] == "error"
    assert reassessment_outcome({"overall_status": "compliant", "results": []}, "AIGOV-IAM-001")["assessment"] == "error"
