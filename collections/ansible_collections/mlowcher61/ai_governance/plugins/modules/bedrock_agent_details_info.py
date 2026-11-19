#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: bedrock_agent_details_info
short_description: Read the governance details of an Amazon Bedrock Agents Classic agent
version_added: "0.1.0"
description:
  - Returns the details of a Bedrock Agents Classic agent that the certified C(amazon.ai) 1.0.1 modules do
    not return, namely tags, guardrail, KMS key, orchestration type, knowledge bases with their S3 data
    sources (and the data classification tag of each bucket), and multi-agent collaborators.
  - Data sources and collaborators are normalized to the contract shapes in C(schemas/common.v1.json)
    (C(data_source) and C(tool)), ready for a discovery record.
  - Reports an evidence status per domain (C(agent), C(tags), C(data_sources), C(collaborators)) instead of
    failing. C(access_denied) and C(error) mean the evidence is incomplete, so policies return C(unknown).
  - Read-only. Action groups come from C(amazon.ai.bedrock_agent_info) (certified).
options:
  agent_id:
    description: The agent ID (10 characters).
    type: str
    required: true
  agent_version:
    description: Agent version whose knowledge bases and collaborators are read.
    type: str
    default: DRAFT
  collect_bucket_tags:
    description: Read the tags of each data source S3 bucket to find its data classification.
    type: bool
    default: true
  classification_tag_key:
    description: Bucket tag that holds the data classification.
    type: str
    default: DataClassification
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
notes:
  - Supports check mode. The module never changes anything.
  - "Permissions used: bedrock:GetAgent, bedrock:ListTagsForResource, bedrock:ListAgentKnowledgeBases,
    bedrock:GetKnowledgeBase, bedrock:ListDataSources, bedrock:GetDataSource, bedrock:ListAgentCollaborators,
    s3:GetBucketTagging."
  - The agent instruction (its prompt) is never returned.
author:
  - AI Governance Control Tower contributors (@mlowcher61)
"""

EXAMPLES = r"""
- name: Read the governance details of a Classic agent
  mlowcher61.ai_governance.bedrock_agent_details_info:
    agent_id: QX7ZK2LMNA
    region: us-east-1
  register: aigov_agent

- name: Use the normalized data sources in a discovery record
  ansible.builtin.set_fact:
    aigov_data_sources: "{{ aigov_agent.data_sources }}"
    aigov_data_sources_evidence: "{{ aigov_agent.evidence_status.data_sources }}"
"""

RETURN = r"""
agent:
  description: Agent attributes (no instruction text). Empty when the agent could not be read.
  returned: always
  type: dict
  contains:
    agent_id:
      description: Agent ID.
      type: str
    name:
      description: Agent name.
      type: str
    arn:
      description: Agent ARN.
      type: str
    status:
      description: Agent status, for example C(PREPARED).
      type: str
    foundation_model:
      description: Foundation model ID.
      type: str
    role_arn:
      description: Execution role ARN.
      type: str
    customer_encryption_key_arn:
      description: KMS key ARN, or null when AWS-owned keys are used.
      type: str
    orchestration_type:
      description: C(DEFAULT) or C(CUSTOM_ORCHESTRATION).
      type: str
    collaboration:
      description: C(DISABLED), C(SUPERVISOR) or C(SUPERVISOR_ROUTER).
      type: str
tags:
  description: Agent tags.
  returned: always
  type: dict
guardrail:
  description: The attached guardrail (identifier and version), or null when none is attached.
  returned: always
  type: dict
knowledge_bases:
  description: Associated knowledge bases with their status, storage type and data sources.
  returned: always
  type: list
  elements: dict
data_sources:
  description: >-
    Contract data_source entries. One knowledge_base entry per knowledge base and one s3_data_source entry per
    S3 data source, with storage_ref (bucket ARN) and the bucket's classification.
  returned: always
  type: list
  elements: dict
collaborators:
  description: Contract tool entries of type collaborator (executor_ref is the collaborator alias ARN).
  returned: always
  type: list
  elements: dict
evidence_status:
  description: Evidence status per domain (agent, tags, data_sources, collaborators).
  returned: always
  type: dict
  sample: {agent: collected, tags: collected, data_sources: access_denied, collaborators: collected}
errors:
  description: Every AWS call that failed, with domain, operation, target, error code and status.
  returned: always
  type: list
  elements: dict
"""

try:
    import botocore
except ImportError:
    pass  # Handled by AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule
from ansible_collections.amazon.aws.plugins.module_utils.retries import AWSRetry
from ansible_collections.mlowcher61.ai_governance.plugins.module_utils.evidence import (
    NOT_COLLECTED,
    EvidenceTracker,
    error_code,
    status_for,
)

DOMAINS = ("agent", "tags", "data_sources", "collaborators")


def _iso(value):
    return value.isoformat() if hasattr(value, "isoformat") else value


def _paginate(client, operation, result_key, **params):
    return client.get_paginator(operation).paginate(**params).build_full_result().get(result_key, [])


def agent_summary(agent):
    return dict(
        agent_id=agent.get("agentId"),
        name=agent.get("agentName"),
        arn=agent.get("agentArn"),
        version=agent.get("agentVersion"),
        status=agent.get("agentStatus"),
        foundation_model=agent.get("foundationModel"),
        role_arn=agent.get("agentResourceRoleArn"),
        customer_encryption_key_arn=agent.get("customerEncryptionKeyArn"),
        orchestration_type=agent.get("orchestrationType"),
        collaboration=agent.get("agentCollaboration"),
        idle_session_ttl_seconds=agent.get("idleSessionTTLInSeconds"),
        memory_enabled=bool((agent.get("memoryConfiguration") or {}).get("enabledMemoryTypes")),
        description=agent.get("description"),
        created_at=_iso(agent.get("createdAt")),
        updated_at=_iso(agent.get("updatedAt")),
        prepared_at=_iso(agent.get("preparedAt")),
    )


def bucket_name(bucket_arn):
    return (bucket_arn or "").split(":::", 1)[-1] or None


def bucket_classification(s3, tracker, bucket_arn, tag_key, cache):
    """(classification, source) for a bucket; (None, "none") when untagged or unreadable."""
    name = bucket_name(bucket_arn)
    if not name:
        return None, "none"
    if name not in cache:
        try:
            tags = s3.get_bucket_tagging(Bucket=name).get("TagSet", [])
            cache[name] = dict((t["Key"], t["Value"]) for t in tags).get(tag_key)
        except botocore.exceptions.ClientError as e:
            if (e.response.get("Error") or {}).get("Code") == "NoSuchTagSet":
                cache[name] = None
            else:
                # The data source is known; only its classification is not. Policies see a null
                # classification and return unknown for sensitivity, so the domain stays collected.
                tracker.errors.append(dict(domain="data_sources", operation="GetBucketTagging", target=name,
                                           code=error_code(e), status=status_for(e), message=str(e)[:500]))
                cache[name] = None
    value = cache[name]
    return (value.lower(), "s3_tag") if value else (None, "none")


def collect(client, s3, agent_id, agent_version="DRAFT", collect_bucket_tags=True, tag_key="DataClassification"):
    """Return the module result dict. Never raises for AWS client errors."""
    tracker = EvidenceTracker(*DOMAINS)
    result = dict(agent={}, tags={}, guardrail=None, knowledge_bases=[], data_sources=[], collaborators=[])

    try:
        agent = client.get_agent(agentId=agent_id)["agent"]
    except botocore.exceptions.ClientError as e:
        tracker.failed("agent", "GetAgent", e, agent_id)
        for domain in DOMAINS[1:]:
            tracker.set(domain, NOT_COLLECTED)
        return _finish(result, tracker)

    result["agent"] = agent_summary(agent)
    guardrail = agent.get("guardrailConfiguration") or {}
    if guardrail.get("guardrailIdentifier"):
        result["guardrail"] = dict(identifier=guardrail["guardrailIdentifier"], version=guardrail.get("guardrailVersion"))

    try:
        result["tags"] = client.list_tags_for_resource(resourceArn=agent["agentArn"]).get("tags", {})
    except botocore.exceptions.ClientError as e:
        tracker.failed("tags", "ListTagsForResource", e, agent["agentArn"])

    bucket_cache = {}
    try:
        kb_summaries = _paginate(client, "list_agent_knowledge_bases", "agentKnowledgeBaseSummaries",
                                 agentId=agent_id, agentVersion=agent_version)
    except botocore.exceptions.ClientError as e:
        tracker.failed("data_sources", "ListAgentKnowledgeBases", e, agent_id)
        kb_summaries = []
    for summary in sorted(kb_summaries, key=lambda k: k["knowledgeBaseId"]):
        kb_id = summary["knowledgeBaseId"]
        kb_entry = dict(knowledge_base_id=kb_id, state=summary.get("knowledgeBaseState"), data_sources=[])
        try:
            kb = client.get_knowledge_base(knowledgeBaseId=kb_id)["knowledgeBase"]
            kb_entry.update(name=kb.get("name"), arn=kb.get("knowledgeBaseArn"), status=kb.get("status"),
                            role_arn=kb.get("roleArn"),
                            storage_type=(kb.get("storageConfiguration") or {}).get("type"))
        except botocore.exceptions.ClientError as e:
            tracker.failed("data_sources", "GetKnowledgeBase", e, kb_id)
        try:
            ds_summaries = _paginate(client, "list_data_sources", "dataSourceSummaries", knowledgeBaseId=kb_id)
        except botocore.exceptions.ClientError as e:
            tracker.failed("data_sources", "ListDataSources", e, kb_id)
            ds_summaries = []
        buckets = []
        for ds_summary in sorted(ds_summaries, key=lambda d: d["dataSourceId"]):
            ds_id = ds_summary["dataSourceId"]
            try:
                ds = client.get_data_source(knowledgeBaseId=kb_id, dataSourceId=ds_id)["dataSource"]
            except botocore.exceptions.ClientError as e:
                tracker.failed("data_sources", "GetDataSource", e, "{0}/{1}".format(kb_id, ds_id))
                continue
            config = ds.get("dataSourceConfiguration") or {}
            s3_config = config.get("s3Configuration") or {}
            bucket_arn = s3_config.get("bucketArn")
            classification, source = (None, "none")
            if bucket_arn and collect_bucket_tags:
                classification, source = bucket_classification(s3, tracker, bucket_arn, tag_key, bucket_cache)
            kb_entry["data_sources"].append(dict(data_source_id=ds_id, name=ds.get("name"), status=ds.get("status"),
                                                 type=config.get("type"), bucket_arn=bucket_arn))
            if bucket_arn:
                buckets.append((bucket_arn, classification, source))
                result["data_sources"].append(dict(
                    type="s3_data_source", external_id="{0}/{1}".format(kb_id, ds_id), name=ds.get("name"),
                    state=ds.get("status"), storage_ref=bucket_arn, classification=classification,
                    classification_source=source,
                    attributes=dict(knowledge_base_id=kb_id, inclusion_prefixes=s3_config.get("inclusionPrefixes") or [],
                                    bucket_owner_account_id=s3_config.get("bucketOwnerAccountId"))))
        result["knowledge_bases"].append(kb_entry)
        # The knowledge base carries the most sensitive classification of its buckets.
        ranked = [b for b in buckets if b[1]]
        order = ["restricted", "confidential", "internal", "public"]
        ranked.sort(key=lambda b: order.index(b[1]) if b[1] in order else len(order))
        top = ranked[0] if ranked else (buckets[0] if buckets else (None, None, "none"))
        result["data_sources"].append(dict(
            type="knowledge_base", external_id=kb_id, name=kb_entry.get("name"), state=summary.get("knowledgeBaseState"),
            storage_ref=top[0], classification=top[1], classification_source=top[2],
            attributes=dict(status=kb_entry.get("status"), storage_type=kb_entry.get("storage_type"),
                            data_source_count=len(kb_entry["data_sources"]))))

    if agent.get("agentCollaboration") in (None, "DISABLED"):
        collaborators = []
    else:
        try:
            collaborators = _paginate(client, "list_agent_collaborators", "agentCollaboratorSummaries",
                                      agentId=agent_id, agentVersion=agent_version)
        except botocore.exceptions.ClientError as e:
            tracker.failed("collaborators", "ListAgentCollaborators", e, agent_id)
            collaborators = []
    for c in sorted(collaborators, key=lambda c: c["collaboratorId"]):
        result["collaborators"].append(dict(
            type="collaborator", external_id=c["collaboratorId"], name=c.get("collaboratorName"), state=None,
            executor_ref=(c.get("agentDescriptor") or {}).get("aliasArn"), parent_signature=None,
            attributes=dict(relay_conversation_history=c.get("relayConversationHistory"))))

    return _finish(result, tracker)


def _finish(result, tracker):
    result["evidence_status"] = tracker.status
    result["errors"] = tracker.errors
    return result


def main():
    argument_spec = dict(
        agent_id=dict(type="str", required=True),
        agent_version=dict(type="str", default="DRAFT"),
        collect_bucket_tags=dict(type="bool", default=True),
        classification_tag_key=dict(type="str", default="DataClassification", no_log=False),
    )
    module = AnsibleAWSModule(argument_spec=argument_spec, supports_check_mode=True)
    retry = AWSRetry.jittered_backoff()
    client = module.client("bedrock-agent", retry_decorator=retry)
    s3 = module.client("s3", retry_decorator=retry) if module.params["collect_bucket_tags"] else None
    try:
        result = collect(client, s3, module.params["agent_id"], module.params["agent_version"],
                         module.params["collect_bucket_tags"], module.params["classification_tag_key"])
    except botocore.exceptions.BotoCoreError as e:
        module.fail_json_aws(e, msg="Failed to read agent {0}".format(module.params["agent_id"]))
    module.exit_json(changed=False, **result)


if __name__ == "__main__":
    main()
