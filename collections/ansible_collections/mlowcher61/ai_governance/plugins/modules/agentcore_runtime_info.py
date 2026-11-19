#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: agentcore_runtime_info
short_description: List Amazon Bedrock AgentCore runtimes with their governance details
version_added: "0.1.0"
description:
  - Lists the AgentCore runtimes in a region and, for each, returns the details governance needs, namely
    the execution role, status, version, network mode, protocol, authorizer type, endpoints and tags.
  - Reports an evidence status per runtime (C(agent), C(tags)) instead of failing on a single runtime.
  - Never returns runtime environment variables, which can hold secrets.
  - Read-only. Temporary module until a certified C(amazon.ai) 2.x (which adds
    C(bedrock_agentcore_runtime_info)) is available on the private automation hub.
  - Needs boto3 with the C(bedrock-agentcore-control) client (boto3 >= 1.40, the AI Governance EE).
options:
  agent_runtime_ids:
    description: Only return these runtime IDs. By default every runtime in the region is returned.
    type: list
    elements: str
    default: []
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
notes:
  - Supports check mode. The module never changes anything.
  - "Permissions used: bedrock-agentcore:ListAgentRuntimes, bedrock-agentcore:GetAgentRuntime,
    bedrock-agentcore:ListAgentRuntimeEndpoints, bedrock-agentcore:ListTagsForResource."
author:
  - AI Governance Control Tower contributors (@mlowcher61)
"""

EXAMPLES = r"""
- name: List the AgentCore runtimes in us-west-1 through the discovery role
  mlowcher61.ai_governance.agentcore_runtime_info:
    region: us-west-1
    access_key: "{{ aigov_session.access_key }}"
    secret_key: "{{ aigov_session.secret_key }}"
    session_token: "{{ aigov_session.session_token }}"
  register: aigov_runtimes
"""

RETURN = r"""
runtimes:
  description: One entry per runtime, sorted by name.
  returned: always
  type: list
  elements: dict
  contains:
    id:
      description: Runtime ID.
      type: str
    name:
      description: Runtime name.
      type: str
    arn:
      description: Runtime ARN.
      type: str
    version:
      description: Runtime version.
      type: str
    status:
      description: Runtime status, for example C(READY).
      type: str
    role_arn:
      description: Execution role ARN.
      type: str
    description:
      description: Runtime description.
      type: str
    network_mode:
      description: C(PUBLIC) or C(VPC).
      type: str
    protocol:
      description: Server protocol, for example C(HTTP), C(MCP) or C(A2A).
      type: str
    authorizer:
      description: Inbound authorizer type (C(customJWTAuthorizer)), or null when IAM SigV4 is used.
      type: str
    code_runtime:
      description: Language runtime of a direct code deployment, for example C(PYTHON_3_13); null for containers.
      type: str
    created_at:
      description: Creation time (ISO 8601).
      type: str
    updated_at:
      description: Last update time (ISO 8601).
      type: str
    endpoints:
      description: Runtime endpoints with name, status and live version.
      type: list
      elements: dict
    tags:
      description: Runtime tags.
      type: dict
    evidence_status:
      description: Evidence status for the agent and tags domains.
      type: dict
    errors:
      description: AWS calls that failed for this runtime.
      type: list
      elements: dict
errors:
  description: Region-level failures (for example AccessDenied on ListAgentRuntimes).
  returned: always
  type: list
  elements: dict
listing_status:
  description: collected when the runtimes could be listed, else access_denied or error.
  returned: always
  type: str
"""

try:
    import botocore
except ImportError:
    pass  # Handled by AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule
from ansible_collections.amazon.aws.plugins.module_utils.retries import AWSRetry
from ansible_collections.mlowcher61.ai_governance.plugins.module_utils.evidence import (
    COLLECTED,
    EvidenceTracker,
)


def _iso(value):
    return value.isoformat() if hasattr(value, "isoformat") else value


def runtime_details(client, summary):
    """Details for one runtime summary. Never raises for AWS client errors."""
    tracker = EvidenceTracker("agent", "tags")
    runtime_id = summary["agentRuntimeId"]
    entry = dict(id=runtime_id, name=summary.get("agentRuntimeName"), arn=summary.get("agentRuntimeArn"),
                 version=summary.get("agentRuntimeVersion"), status=summary.get("status"),
                 description=summary.get("description"), role_arn=None, network_mode=None, protocol=None,
                 authorizer=None, code_runtime=None, created_at=None, updated_at=_iso(summary.get("lastUpdatedAt")),
                 endpoints=[], tags={})
    try:
        rt = client.get_agent_runtime(agentRuntimeId=runtime_id)
        entry.update(
            name=rt.get("agentRuntimeName"), arn=rt.get("agentRuntimeArn"), version=rt.get("agentRuntimeVersion"),
            status=rt.get("status"), description=rt.get("description"), role_arn=rt.get("roleArn"),
            network_mode=(rt.get("networkConfiguration") or {}).get("networkMode"),
            protocol=(rt.get("protocolConfiguration") or {}).get("serverProtocol"),
            authorizer=next(iter((rt.get("authorizerConfiguration") or {}).keys()), None),
            code_runtime=((rt.get("agentRuntimeArtifact") or {}).get("codeConfiguration") or {}).get("runtime"),
            created_at=_iso(rt.get("createdAt")), updated_at=_iso(rt.get("lastUpdatedAt")))
    except botocore.exceptions.ClientError as e:
        tracker.failed("agent", "GetAgentRuntime", e, runtime_id)
    try:
        pages = client.get_paginator("list_agent_runtime_endpoints").paginate(agentRuntimeId=runtime_id)
        endpoints = pages.build_full_result().get("runtimeEndpoints", [])
        entry["endpoints"] = sorted(
            (dict(name=ep.get("name"), status=ep.get("status"), live_version=ep.get("liveVersion")) for ep in endpoints),
            key=lambda ep: ep["name"] or "")
    except botocore.exceptions.ClientError as e:
        tracker.failed("agent", "ListAgentRuntimeEndpoints", e, runtime_id)
    if entry["arn"]:
        try:
            entry["tags"] = client.list_tags_for_resource(resourceArn=entry["arn"]).get("tags", {})
        except botocore.exceptions.ClientError as e:
            tracker.failed("tags", "ListTagsForResource", e, entry["arn"])
    entry["evidence_status"] = tracker.status
    entry["errors"] = tracker.errors
    return entry


def collect(client, runtime_ids=None):
    """Return (runtimes, listing_status, errors)."""
    tracker = EvidenceTracker("listing")
    try:
        summaries = client.get_paginator("list_agent_runtimes").paginate().build_full_result().get("agentRuntimes", [])
    except botocore.exceptions.ClientError as e:
        tracker.failed("listing", "ListAgentRuntimes", e)
        return [], tracker.status["listing"], tracker.errors
    if runtime_ids:
        summaries = [s for s in summaries if s["agentRuntimeId"] in runtime_ids]
    runtimes = [runtime_details(client, s) for s in summaries]
    return sorted(runtimes, key=lambda r: r["name"] or ""), COLLECTED, tracker.errors


def main():
    module = AnsibleAWSModule(
        argument_spec=dict(agent_runtime_ids=dict(type="list", elements="str", default=[])),
        supports_check_mode=True,
    )
    try:
        client = module.client("bedrock-agentcore-control", retry_decorator=AWSRetry.jittered_backoff())
    except botocore.exceptions.UnknownServiceError:
        module.fail_json(msg="boto3 has no bedrock-agentcore-control client; use an EE with boto3 >= 1.40 (AI Governance EE)")
    try:
        runtimes, status, errors = collect(client, module.params["agent_runtime_ids"])
    except botocore.exceptions.BotoCoreError as e:
        module.fail_json_aws(e, msg="Failed to list AgentCore runtimes")
    module.exit_json(changed=False, runtimes=runtimes, listing_status=status, errors=errors)


if __name__ == "__main__":
    main()
