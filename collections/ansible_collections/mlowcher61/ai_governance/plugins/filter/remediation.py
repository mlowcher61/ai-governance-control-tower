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


class FilterModule:
    def filters(self):
        return {"policy_input_refresh": policy_input_refresh, "reassessment_outcome": reassessment_outcome}
