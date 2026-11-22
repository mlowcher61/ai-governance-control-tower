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


# ---- Plan Remediation helpers ---------------------------------------------------------------------------------
from ansible_collections.mlowcher61.ai_governance.plugins.filter.remediation import (  # noqa: E402
    remediation_ai_check,
    remediation_applicable_actions,
    remediation_blast_radius,
    remediation_governance_tags,
)

ADMIN_ARNS = ["arn:aws:iam::aws:policy/AdministratorAccess"]
TRUST_AGENT = {"Statement": [{"Effect": "Allow", "Principal": {"Service": "bedrock-agentcore.amazonaws.com"}, "Action": "sts:AssumeRole"}]}


def _identity(name):
    ident = _load("discovery", name)["identity"]
    return ident


def test_applicable_actions_for_the_admin_agent():
    acts = remediation_applicable_actions(_identity("quick_helper_bot"), ADMIN_ARNS, "aws.bedrock_agentcore_runtime")
    assert acts[0] == "iam_replace_managed_policy" and "iam_remove_inline_policy" not in acts
    assert "agentcore_apply_governance_tags" in acts and "bedrock_pause_agent_alias" not in acts


def test_inline_admin_policy_needs_removal():
    ident = {"principal_ref": "r", "policies": [{"type": "inline", "ref": "x", "statements": [
        {"effect": "Allow", "actions": [], "not_actions": ["iam:*"], "resources": ["*"]}]}]}
    assert remediation_applicable_actions(ident, ADMIN_ARNS, "aws.bedrock_agentcore_runtime")[0] == "iam_remove_inline_policy"


def test_approved_agent_has_no_admin_fix():
    acts = remediation_applicable_actions(_identity("payments_dispute_assistant"), ADMIN_ARNS, "aws.bedrock_agentcore_runtime")
    assert "iam_replace_managed_policy" not in acts and "iam_remove_inline_policy" not in acts


def test_blast_radius():
    ident = dict(_identity("quick_helper_bot"), trust_policy=TRUST_AGENT)
    assert remediation_blast_radius(0, ident)["shared_role"] == "no"
    assert remediation_blast_radius(2, ident)["shared_role"] == "yes"
    assert remediation_blast_radius(None, ident)["shared_role"] == "unknown"
    assert remediation_blast_radius(0, ident, "access_denied")["shared_role"] == "unknown"
    other = dict(ident, trust_policy={"Statement": [{"Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::1:root"}, "Action": ["sts:AssumeRole"]}]})
    out = remediation_blast_radius(0, other)
    assert out["shared_role"] == "yes" and "arn:aws:iam::1:root" in out["detail"]
    assert remediation_blast_radius(0, dict(ident, trust_policy={}))["shared_role"] == "unknown"


DECISION = {"selected_action": "iam_replace_managed_policy", "allowed_actions": ["iam_replace_managed_policy", "iam_apply_permissions_boundary"]}


def test_ai_check():
    rec = {"agrees_with_selected_action": "yes", "recommended_action": "iam_replace_managed_policy"}
    assert remediation_ai_check(rec, [], DECISION) == {"ai_agrees": "yes", "accepted": True, "detail": "agrees with iam_replace_managed_policy"}
    alt = remediation_ai_check(dict(rec, recommended_action="iam_apply_permissions_boundary", agrees_with_selected_action="no"), [], DECISION)
    assert alt["ai_agrees"] == "no" and alt["accepted"] is True
    outside = remediation_ai_check(dict(rec, recommended_action="bedrock_pause_agent_alias"), [], DECISION)
    assert outside["ai_agrees"] == "no" and outside["accepted"] is False
    assert remediation_ai_check({}, [], DECISION)["ai_agrees"] == "invalid"
    assert remediation_ai_check(None, [], DECISION)["ai_agrees"] == "invalid"
    assert remediation_ai_check(rec, [{"message": "bad"}], DECISION)["ai_agrees"] == "invalid"


def test_governance_tags_never_invent_owners():
    unregistered = remediation_governance_tags({"finding_id": "f1", "policy_id": "AIGOV-REG-001", "registration": None})
    assert unregistered == {"aigov:status": "noncompliant", "aigov:finding": "f1", "aigov:policy": "AIGOV-REG-001"}
    registration = {"registration_id": "REG-0002", "owner_email": "hr@example.com", "environment": "production",
                    "data_classification": None}
    registered = remediation_governance_tags({"finding_id": "f", "registration": registration})
    assert registered == {"Owner": "hr@example.com", "Environment": "production", "aigov:registration": "REG-0002"}


from ansible_collections.mlowcher61.ai_governance.plugins.filter.remediation import (  # noqa: E402
    remediation_admin_inline_policies,
    remediation_policy_sets,
    remediation_state_drift,
)

APPROVED = "arn:aws:iam::111122223333:policy/aigov/aigov-approved-agentcore-runtime-basic"


def test_policy_sets_attach_before_detach():
    sets = remediation_policy_sets(_identity("quick_helper_bot"), ADMIN_ARNS, APPROVED)
    assert APPROVED in sets["step1"] and ADMIN_ARNS[0] in sets["step1"]      # step 1 never removes anything
    assert APPROVED in sets["step2"] and ADMIN_ARNS[0] not in sets["step2"]  # step 2 removes only admin policies
    assert sets["detach"] == ADMIN_ARNS and sets["attach"] == [APPROVED]


def test_policy_sets_keep_other_policies_and_are_idempotent():
    ident = {"policies": [{"type": "customer_managed", "ref": "arn:keep"}, {"type": "aws_managed", "ref": APPROVED}]}
    sets = remediation_policy_sets(ident, ADMIN_ARNS, APPROVED)
    assert sets["step1"] == sets["step2"] == sorted(["arn:keep", APPROVED]) and sets["attach"] == [] and sets["detach"] == []


def test_admin_inline_policies_only():
    ident = {"policies": [
        {"type": "inline", "name": "admin", "statements": [{"effect": "Allow", "actions": ["*"], "resources": ["*"]}]},
        {"type": "inline", "name": "s3read", "statements": [{"effect": "Allow", "actions": ["s3:GetObject"], "resources": ["*"]}]},
        {"type": "aws_managed", "ref": ADMIN_ARNS[0], "statements": [{"effect": "Allow", "actions": ["*"], "resources": ["*"]}]}]}
    assert remediation_admin_inline_policies(ident) == ["admin"]
    assert remediation_admin_inline_policies(_identity("payments_dispute_assistant")) == []


def test_state_drift():
    pre = _identity("quick_helper_bot")
    assert remediation_state_drift(pre, copy.deepcopy(pre)) == []
    cur = copy.deepcopy(pre)
    cur["policies"] = [p for p in cur["policies"] if p.get("ref") not in ADMIN_ARNS]
    cur["permissions_boundary_ref"] = "arn:b"
    cur["policies"].append({"type": "inline", "name": "new", "statements": []})
    drift = remediation_state_drift(pre, cur)
    assert len(drift) == 3 and "removed ['arn:aws:iam::aws:policy/AdministratorAccess']" in drift[0]
    # Tags and trust policy changes are not drift for these actions
    cur = copy.deepcopy(pre)
    cur["tags"] = {"x": "y"}
    assert remediation_state_drift(pre, cur) == []


from ansible_collections.mlowcher61.ai_governance.plugins.filter.remediation import (  # noqa: E402
    remediation_probe_check,
    remediation_simulation_checks,
)

PROBES = ["iam:CreateUser", "iam:AttachRolePolicy", "iam:PutRolePolicy"]


def test_probe_check():
    denied = dict((a, "denied") for a in PROBES)
    assert remediation_probe_check(denied, PROBES, "iam_replace_managed_policy") == "all_denied"
    assert remediation_probe_check(dict(denied, **{"iam:CreateUser": "allowed"}), PROBES, "iam_remove_inline_policy") == "some_allowed"
    assert remediation_probe_check({"iam:CreateUser": "denied"}, PROBES, "iam_apply_permissions_boundary") == "unknown"
    assert remediation_probe_check({}, [], "iam_replace_managed_policy") == "unknown"
    assert remediation_probe_check({}, PROBES, "agentcore_apply_governance_tags") == "not_applicable"
    # the demo admin agent before remediation
    assert remediation_probe_check(_identity("quick_helper_bot")["simulation"], PROBES, "iam_replace_managed_policy") == "some_allowed"


def test_simulation_checks():
    assert remediation_simulation_checks(PROBES[:2]) == [{"action": "iam:CreateUser"}, {"action": "iam:AttachRolePolicy"}]
    assert remediation_simulation_checks(None) == []


from ansible_collections.mlowcher61.ai_governance.plugins.filter.remediation import remediation_rollback_plan  # noqa: E402

BOUNDARY = "arn:aws:iam::111122223333:policy/aigov/aigov-agentcore-runtime-boundary"


def _remediated(pre, attach=(), detach=()):
    cur = copy.deepcopy(pre)
    cur["policies"] = [p for p in cur["policies"] if p.get("ref") not in detach] + [{"type": "customer_managed", "ref": a} for a in attach]
    return cur


def test_rollback_of_admin_replacement_is_manual():
    pre = _identity("quick_helper_bot")
    plan = remediation_rollback_plan("iam_replace_managed_policy", {"identity": pre}, _remediated(pre, [APPROVED], ADMIN_ARNS),
                                     {}, APPROVED, BOUNDARY)
    assert plan["mode"] == "manual" and "AdministratorAccess" in plan["manual_steps"][0]
    assert plan["managed_policies"] == sorted(p["ref"] for p in pre["policies"] if p["type"] != "inline")


def test_rollback_after_partial_failure_is_automated():
    pre = _identity("quick_helper_bot")   # step 1 attached the approved policy, step 2 (detach admin) failed
    plan = remediation_rollback_plan("iam_replace_managed_policy", {"identity": pre}, _remediated(pre, [APPROVED]), {}, APPROVED, BOUNDARY)
    assert plan["mode"] == "automated" and APPROVED not in plan["managed_policies"] and plan["manual_steps"] == []


def test_rollback_at_pre_state_does_nothing():
    pre = _identity("quick_helper_bot")
    assert remediation_rollback_plan("iam_replace_managed_policy", {"identity": pre}, copy.deepcopy(pre), {}, APPROVED, BOUNDARY)["mode"] == "nothing"


def test_boundary_rollback():
    pre = _identity("quick_helper_bot")
    cur = dict(copy.deepcopy(pre), permissions_boundary_ref=BOUNDARY)
    plan = remediation_rollback_plan("iam_apply_permissions_boundary", {"identity": pre}, cur, {}, APPROVED, BOUNDARY)
    assert plan["mode"] == "automated" and plan["boundary"] == ""
    pre_other = dict(copy.deepcopy(pre), permissions_boundary_ref="arn:other")
    assert remediation_rollback_plan("iam_apply_permissions_boundary", {"identity": pre_other}, cur, {}, APPROVED, BOUNDARY)["mode"] == "manual"


def test_inline_rollback_is_manual():
    pre = {"policies": [{"type": "inline", "name": "admin", "statements": []}]}
    plan = remediation_rollback_plan("iam_remove_inline_policy", {"identity": pre}, {"policies": []}, {}, APPROVED, BOUNDARY)
    assert plan["mode"] == "manual" and "admin" in plan["manual_steps"][0]


def test_tag_rollback_restores_only_the_remediation_keys():
    pre = {"runtime_tags": {"team": "x", "aigov:status": "old"}}
    cur = {"team": "x", "later": "kept", "aigov:status": "noncompliant", "aigov:finding": "f1"}
    plan = remediation_rollback_plan("agentcore_apply_governance_tags", pre, {}, cur, APPROVED, BOUNDARY,
                                     tags_added={"aigov:status": "noncompliant", "aigov:finding": "f1"})
    assert plan["mode"] == "automated" and plan["tags"] == {"team": "x", "later": "kept", "aigov:status": "old"}
    assert remediation_rollback_plan("agentcore_apply_governance_tags", pre, {}, {"team": "x", "aigov:status": "old"}, APPROVED, BOUNDARY,
                                     tags_added={"aigov:status": "noncompliant"})["mode"] == "nothing"


def test_unknown_action_rollback_is_manual():
    assert remediation_rollback_plan("bedrock_pause_agent_alias", {}, {}, {}, APPROVED, BOUNDARY)["mode"] == "manual"


def test_reassessment_outcome_lists_candidate_actions_for_the_platform():
    result = _load("expected", "quick_helper_bot")
    out = reassessment_outcome(result, "AIGOV-REG-001", "aws.bedrock_agentcore_runtime")
    assert out["candidate_actions"] == ["agentcore_apply_governance_tags"] and out["remediation_summary"]
    assert "bedrock_pause_agent_alias" in reassessment_outcome(result, "AIGOV-REG-001")["candidate_actions"]
