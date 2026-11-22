# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
name: policy_input_refresh
short_description: Rebuild a policy input with freshly collected cloud state
version_added: "0.1.0"
description:
  - Takes the stored policy input of an agent (from C(api.evaluation_inputs)) and replaces everything that comes from the
    cloud (agent attributes, tags, identity and permissions, simulation, tools, data sources, evidence) with a freshly
    collected discovery record. Registration and IDs stay as stored.
  - Used by the Reassess Agent and Verify Remediation jobs, so that a decision is based on what AWS shows now, not on the
    last discovery run.
positional: _input
options:
  _input:
    description: The stored policy input (C(schemas/policy-input.v1.json) without the evaluation block).
    type: dict
    required: true
  record:
    description: A freshly collected discovery record (C(schemas/discovery-record.v1.json)).
    type: dict
    required: true
author:
  - AI Governance Control Tower contributors (@mlowcher61)
"""

EXAMPLES = r"""
- name: Rebuild the input with live state
  ansible.builtin.set_fact:
    fresh_input: "{{ stored_input | mlowcher61.ai_governance.policy_input_refresh(record=fresh_record) }}"
"""

RETURN = r"""
_value:
  description: The refreshed policy input.
  type: dict
"""

import copy  # noqa: E402 - Ansible plugins keep DOCUMENTATION first


def policy_input_refresh(stored, record):
    out = copy.deepcopy(stored)
    agent = out.setdefault("agent", {})
    attributes = record.get("attributes") or {}
    agent.update(
        status=record.get("status"),
        environment=record.get("environment"),
        tags=record.get("tags") or {},
        attributes=attributes,
        guardrail=attributes.get("guardrail"),
        foundation_model=(record.get("foundation_model") or {}).get("model_id"),
        source_created_at=record.get("source_created_at"),
        source_updated_at=record.get("source_updated_at"),
    )
    identity = record.get("identity")
    if identity is None:
        out["identity"] = None
    else:
        out["identity"] = dict(
            principal_ref=identity.get("principal_ref"),
            permissions_boundary_ref=identity.get("permissions_boundary_ref"),
            policies=[dict(type=p["type"], ref=p["ref"], name=p.get("name"), statements=p.get("statements") or [])
                      for p in sorted(identity.get("policies") or [], key=lambda p: (p["type"], p["ref"]))],
            simulation=identity.get("simulation") or {},
        )
    out["tools"] = [dict(type=t["type"], external_id=t["external_id"], name=t.get("name"), state=t.get("state"),
                         executor_ref=t.get("executor_ref"), parent_signature=t.get("parent_signature"))
                    for t in record.get("tools") or []]
    out["data_sources"] = [dict(type=d["type"], external_id=d["external_id"], name=d.get("name"), storage_ref=d.get("storage_ref"),
                                classification=d.get("classification"), classification_source=d.get("classification_source"))
                           for d in record.get("data_sources") or []]
    evidence = dict(record.get("evidence_status") or {})
    evidence["registration"] = (stored.get("evidence") or {}).get("registration", "collected")
    out["evidence"] = evidence
    return out


def reassessment_outcome(result, policy_id):
    """compliant / noncompliant / missing_evidence / error for one policy of an evaluation result."""
    if not isinstance(result, dict) or result.get("overall_status") == "error" or result.get("input_errors"):
        return dict(assessment="error", decision=None, severity=None)
    for r in result.get("results") or []:
        if r.get("policy_id") == policy_id:
            decision = r.get("decision")
            assessment = {"pass": "compliant", "not_applicable": "compliant", "fail": "noncompliant",
                          "unknown": "missing_evidence"}.get(decision, "error")
            return dict(assessment=assessment, decision=decision, severity=r.get("severity"))
    return dict(assessment="error", decision=None, severity=None)


ADMIN_ACTIONS = ("*", "*:*", "iam:*")
AGENT_SERVICES = ("bedrock-agentcore.amazonaws.com", "bedrock.amazonaws.com")


def _statement_is_admin(st):
    if st.get("effect") != "Allow" or "*" not in (st.get("resources") or []):
        return False
    return any(a in ADMIN_ACTIONS for a in st.get("actions") or []) or bool(st.get("not_actions"))


def remediation_applicable_actions(identity, admin_policy_arns, platform):
    """Catalog actions that fit the real pre-state (which admin grant exists, which platform)."""
    identity = identity or {}
    policies = identity.get("policies") or []
    out = []
    if any(p.get("type") in ("aws_managed", "customer_managed") and p.get("ref") in (admin_policy_arns or []) for p in policies):
        out.append("iam_replace_managed_policy")
    if any(p.get("type") == "inline" and any(_statement_is_admin(s) for s in p.get("statements") or []) for p in policies):
        out.append("iam_remove_inline_policy")
    if identity.get("principal_ref"):
        out += ["iam_apply_permissions_boundary", "iam_tag_role"]
    if platform == "aws.bedrock_agentcore_runtime":
        out.append("agentcore_apply_governance_tags")
    if platform == "aws.bedrock_agents_classic":
        out += ["bedrock_apply_governance_tags", "bedrock_pause_agent_alias", "bedrock_disable_action_group"]
    return out


def _principals(statement):
    principal = statement.get("Principal")
    if principal == "*":
        return [("AWS", "*")]
    out = []
    for kind, value in (principal or {}).items():
        for v in value if isinstance(value, list) else [value]:
            out.append((kind, v))
    return out


def remediation_blast_radius(agents_sharing_role, identity, identity_evidence="collected"):
    """shared_role yes / no / unknown, with the reason. Unknown forces approval (docs/plan/04 section 7.2)."""
    if identity_evidence != "collected" or not (identity or {}).get("principal_ref") or agents_sharing_role is None:
        return dict(shared_role="unknown", detail="the execution role could not be read completely")
    if int(agents_sharing_role) > 0:
        return dict(shared_role="yes", detail="the role is also used by %d other agent(s) in the inventory" % int(agents_sharing_role))
    trust = (identity or {}).get("trust_policy") or {}
    statements = trust.get("Statement") or []
    if isinstance(statements, dict):
        statements = [statements]
    others = sorted(set("%s:%s" % (k, v) for st in statements if st.get("Effect", "Allow") == "Allow" and
                        "sts:AssumeRole" in (st.get("Action") if isinstance(st.get("Action"), list) else [st.get("Action")])
                        for k, v in _principals(st) if not (k == "Service" and v in AGENT_SERVICES)))
    if others:
        return dict(shared_role="yes", detail="other principals may assume the role: " + ", ".join(others))
    if not statements:
        return dict(shared_role="unknown", detail="the trust policy could not be read")
    return dict(shared_role="no", detail="role used by this agent only; only the agent service may assume it")


def remediation_ai_check(recommendation, recommendation_errors, decision):
    """ai_agrees yes / no / invalid, and whether the AI's recommended action is one OPA allows."""
    if not isinstance(recommendation, dict) or not recommendation:
        return dict(ai_agrees="invalid", accepted=False, detail="no AI recommendation was returned")
    if recommendation_errors:
        return dict(ai_agrees="invalid", accepted=False, detail="the AI recommendation does not match its contract")
    accepted = recommendation.get("recommended_action") in (decision.get("allowed_actions") or [])
    agrees = recommendation.get("agrees_with_selected_action") == "yes" and \
        recommendation.get("recommended_action") == decision.get("selected_action")
    detail = "agrees with %s" % decision.get("selected_action") if agrees else \
        "recommends %s instead of %s" % (recommendation.get("recommended_action"), decision.get("selected_action"))
    return dict(ai_agrees="yes" if agrees else "no", accepted=accepted, detail=detail)


def remediation_governance_tags(context):
    """Tags for agentcore_apply_governance_tags: registry values when registered, else quarantine tags.
    Owner values are never invented (docs/plan/04 section 6.1)."""
    reg = context.get("registration") or None
    if reg:
        tags = {"Owner": reg.get("owner_email") or reg.get("owner_id"), "Environment": reg.get("environment"),
                "DataClassification": reg.get("data_classification"), "aigov:registration": reg.get("registration_id")}
        return dict((k, str(v)) for k, v in tags.items() if v)
    return {"aigov:status": "noncompliant", "aigov:finding": str(context.get("finding_id")), "aigov:policy": str(context.get("policy_id"))}


MANAGED_TYPES = ("aws_managed", "customer_managed")


def _managed_refs(identity):
    return sorted(p.get("ref") for p in (identity or {}).get("policies") or [] if p.get("type") in MANAGED_TYPES)


def remediation_admin_inline_policies(identity):
    """Names of the inline policies that grant administrator access (what iam_remove_inline_policy deletes)."""
    return sorted(p.get("name") or p.get("ref") for p in (identity or {}).get("policies") or []
                  if p.get("type") == "inline" and any(_statement_is_admin(s) for s in p.get("statements") or []))


def remediation_policy_sets(identity, admin_policy_arns, approved_policy_arn):
    """The two managed-policy sets of iam_replace_managed_policy (docs/plan/04 section 6.1), attach before detach:
    step 1 = current + approved (nothing detached), step 2 = current - administrator policies + approved."""
    current = _managed_refs(identity)
    step1 = sorted(set(current) | {approved_policy_arn})
    step2 = sorted((set(current) - set(admin_policy_arns or [])) | {approved_policy_arn})
    return dict(step1=step1, step2=step2, detach=sorted(set(current) & set(admin_policy_arns or [])),
                attach=[] if approved_policy_arn in current else [approved_policy_arn])


def remediation_state_drift(pre_identity, current_identity):
    """What changed on the execution role since the pre-state was captured: managed policies, permissions boundary,
    inline policy names. Execute refuses to act on a role that drifted, because the approval was for the old state."""
    pre, cur = pre_identity or {}, current_identity or {}
    out = []
    if _managed_refs(pre) != _managed_refs(cur):
        added = sorted(set(_managed_refs(cur)) - set(_managed_refs(pre)))
        removed = sorted(set(_managed_refs(pre)) - set(_managed_refs(cur)))
        out.append("managed policies changed (added %s, removed %s)" % (added or "none", removed or "none"))
    if (pre.get("permissions_boundary_ref") or None) != (cur.get("permissions_boundary_ref") or None):
        out.append("permissions boundary changed (%s -> %s)" % (pre.get("permissions_boundary_ref"), cur.get("permissions_boundary_ref")))
    inline = [sorted(p.get("name") or p.get("ref") for p in i.get("policies") or [] if p.get("type") == "inline") for i in (pre, cur)]
    if inline[0] != inline[1]:
        out.append("inline policies changed (%s -> %s)" % (inline[0], inline[1]))
    return out


class FilterModule:
    def filters(self):
        return {"policy_input_refresh": policy_input_refresh, "reassessment_outcome": reassessment_outcome,
                "remediation_applicable_actions": remediation_applicable_actions,
                "remediation_blast_radius": remediation_blast_radius, "remediation_ai_check": remediation_ai_check,
                "remediation_governance_tags": remediation_governance_tags,
                "remediation_admin_inline_policies": remediation_admin_inline_policies,
                "remediation_policy_sets": remediation_policy_sets, "remediation_state_drift": remediation_state_drift}
