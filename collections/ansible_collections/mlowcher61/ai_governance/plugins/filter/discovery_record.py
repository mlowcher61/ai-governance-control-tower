# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
name: agentcore_discovery_record
short_description: Build a discovery record for an AgentCore runtime
version_added: "0.1.0"
description:
  - Combines the outputs of C(agentcore_runtime_info), C(iam_role_permissions_info) and
    C(iam_policy_simulation_info) into one discovery record (C(schemas/discovery-record.v1.json)).
  - AgentCore does not link tools, data sources or the foundation model to a runtime in its control plane,
    so those evidence domains are C(not_supported); the registry supplies them.
positional: _input
options:
  _input:
    description: One runtime from C(agentcore_runtime_info).
    type: dict
    required: true
  account_ref:
    description: AWS account ID.
    type: str
    required: true
  region:
    description: AWS region.
    type: str
    required: true
  identity:
    description: The registered result of C(iam_role_permissions_info) for the runtime role, or omit.
    type: dict
  simulation:
    description: The registered result of C(iam_policy_simulation_info) for the runtime role, or omit.
    type: dict
  collected_at:
    description: Collection time (RFC 3339).
    type: str
  environment_tag:
    description: Tag key that holds the environment name.
    type: str
    default: Environment
author:
  - AI Governance Control Tower contributors (@mlowcher61)
"""

EXAMPLES = r"""
- name: Build the record
  ansible.builtin.set_fact:
    aigov_record: >-
      {{ runtime | mlowcher61.ai_governance.agentcore_discovery_record(account_ref='111122223333', region='us-west-1',
         identity=role_result, simulation=sim_result, collected_at=now(utc=true).isoformat()) }}
"""

RETURN = r"""
_value:
  description: A discovery record (schemas/discovery-record.v1.json).
  type: dict
"""

import re  # noqa: E402 - Ansible plugins keep DOCUMENTATION first

PLATFORM = "aws.bedrock_agentcore_runtime"


def _ts(value):
    """ISO timestamps from boto3 to the contract form: no fractional seconds, UTC as Z."""
    if not value:
        return None
    text = re.sub(r"\.\d+", "", str(value).replace(" ", "T"))
    return text[:-6] + "Z" if text.endswith("+00:00") else text


def agentcore_discovery_record(runtime, account_ref, region, identity=None, simulation=None, collected_at=None,
                               environment_tag="Environment"):
    tags = dict(runtime.get("tags") or {})
    runtime_evidence = runtime.get("evidence_status") or {}
    environment = (tags.get(environment_tag) or "").strip().lower() or None

    identity_obj = None
    identity_status = "not_collected"
    simulation_status = "not_collected"
    if runtime.get("role_arn"):
        identity = identity or {}
        found = identity.get("identity") or {}
        identity_status = identity.get("evidence_status") or "not_collected"
        identity_obj = dict(
            principal_ref=found.get("principal_ref") or runtime["role_arn"],
            permissions_boundary_ref=found.get("permissions_boundary_ref"),
            trust_policy=found.get("trust_policy"),
            tags=found.get("tags") or {},
            simulation=(simulation or {}).get("simulation") or {},
            policies=found.get("policies") or [],
        )
        if collected_at:
            identity_obj["collected_at"] = collected_at
        if simulation:
            simulation_status = simulation.get("evidence_status") or "collected"

    record = dict(
        schema_version="1.0",
        provider="aws",
        platform=PLATFORM,
        account_ref=str(account_ref),
        region=region,
        external_id=runtime["id"],
        resource_ref=runtime["arn"],
        name=runtime["name"],
        status=runtime.get("status"),
        environment=environment,
        tags=tags,
        attributes=dict(
            description=runtime.get("description"),
            agent_runtime_version=runtime.get("version"),
            network_mode=runtime.get("network_mode"),
            protocol=runtime.get("protocol"),
            code_runtime=runtime.get("code_runtime"),
            authorizer=runtime.get("authorizer"),
            endpoints=runtime.get("endpoints") or [],
        ),
        evidence_status=dict(
            agent=runtime_evidence.get("agent", "collected"),
            tags=runtime_evidence.get("tags", "collected"),
            identity=identity_status,
            identity_simulation=simulation_status,
            tools="not_supported",
            data_sources="not_supported",
            model="not_supported",
        ),
        source_created_at=_ts(runtime.get("created_at")),
        source_updated_at=_ts(runtime.get("updated_at")),
        foundation_model=None,
        identity=identity_obj,
        tools=[],
        data_sources=[],
    )
    if collected_at:
        record["collected_at"] = collected_at
    return record


class FilterModule:
    def filters(self):
        return {"agentcore_discovery_record": agentcore_discovery_record}
