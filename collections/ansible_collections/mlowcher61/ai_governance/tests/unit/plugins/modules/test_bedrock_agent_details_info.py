"""Unit tests for bedrock_agent_details_info with botocore Stubber (no AWS calls).

Bedrock Agents Classic cannot be created in the demo account (maintenance mode), so these stubbed
responses are the test target (docs/plan/12 T1.05).
"""

import datetime

import boto3
import pytest
from botocore.stub import Stubber

from ansible_collections.mlowcher61.ai_governance.plugins.modules import bedrock_agent_details_info as mod

AID = "QX7ZK2LMNA"
ARN = f"arn:aws:bedrock:us-east-1:111122223333:agent/{AID}"
NOW = datetime.datetime(2026, 11, 16, 22, 40, tzinfo=datetime.timezone.utc)


def _agent(collaboration="DISABLED", guardrail=True):
    agent = {"agentId": AID, "agentName": "quick_helper_bot", "agentArn": ARN, "agentVersion": "DRAFT",
             "agentStatus": "PREPARED",
             "foundationModel": "anthropic.claude-3-haiku-20240307-v1:0", "orchestrationType": "DEFAULT",
             "agentResourceRoleArn": "arn:aws:iam::111122223333:role/quick_helper_bot-role", "idleSessionTTLInSeconds": 600,
             "createdAt": NOW, "updatedAt": NOW, "agentCollaboration": collaboration,
             "instruction": "SECRET PROMPT TEXT that must never leave the module output."}
    if guardrail:
        agent["guardrailConfiguration"] = {"guardrailIdentifier": "gr-123", "guardrailVersion": "1"}
    return {"agent": agent}


@pytest.fixture
def clients():
    kw = dict(region_name="us-east-1", aws_access_key_id="x", aws_secret_access_key="x")
    agent, s3 = boto3.client("bedrock-agent", **kw), boto3.client("s3", **kw)
    with Stubber(agent) as a, Stubber(s3) as s:
        yield agent, s3, a, s


def _kb(a, kb_id="KB12345", buckets=("customer-exports",)):
    a.add_response("list_agent_knowledge_bases", {"agentKnowledgeBaseSummaries": [
        {"knowledgeBaseId": kb_id, "knowledgeBaseState": "ENABLED", "updatedAt": NOW}]}, {"agentId": AID, "agentVersion": "DRAFT"})
    a.add_response("get_knowledge_base", {"knowledgeBase": {
        "knowledgeBaseId": kb_id, "name": "exports-kb", "knowledgeBaseArn": f"arn:aws:bedrock:us-east-1:111122223333:knowledge-base/{kb_id}",
        "roleArn": "arn:aws:iam::111122223333:role/kb-role", "status": "ACTIVE", "createdAt": NOW, "updatedAt": NOW,
        "knowledgeBaseConfiguration": {"type": "VECTOR"}, "storageConfiguration": {"type": "OPENSEARCH_SERVERLESS"}}},
        {"knowledgeBaseId": kb_id})
    a.add_response("list_data_sources", {"dataSourceSummaries": [
        {"knowledgeBaseId": kb_id, "dataSourceId": f"DS{i:08d}", "name": f"ds-{b}", "status": "AVAILABLE", "updatedAt": NOW}
        for i, b in enumerate(buckets)]}, {"knowledgeBaseId": kb_id})
    for i, b in enumerate(buckets):
        a.add_response("get_data_source", {"dataSource": {
            "knowledgeBaseId": kb_id, "dataSourceId": f"DS{i:08d}", "name": f"ds-{b}", "status": "AVAILABLE", "createdAt": NOW, "updatedAt": NOW,
            "dataSourceConfiguration": {"type": "S3", "s3Configuration": {"bucketArn": f"arn:aws:s3:::{b}", "inclusionPrefixes": ["exports/"]}}}},
            {"knowledgeBaseId": kb_id, "dataSourceId": f"DS{i:08d}"})


def test_full_details_with_classified_bucket(clients):
    agent, s3, a, s = clients
    a.add_response("get_agent", _agent(), {"agentId": AID})
    a.add_response("list_tags_for_resource", {"tags": {"CreatedBy": "dev-sandbox"}}, {"resourceArn": ARN})
    _kb(a)
    s.add_response("get_bucket_tagging", {"TagSet": [{"Key": "DataClassification", "Value": "Restricted"}]}, {"Bucket": "customer-exports"})

    r = mod.collect(agent, s3, AID)
    a.assert_no_pending_responses()
    assert r["evidence_status"] == {"agent": "collected", "tags": "collected", "data_sources": "collected", "collaborators": "collected"}
    assert r["guardrail"] == {"identifier": "gr-123", "version": "1"}
    assert r["tags"] == {"CreatedBy": "dev-sandbox"}
    assert "SECRET PROMPT TEXT" not in str(r), "the agent instruction must never be returned"
    kb = next(d for d in r["data_sources"] if d["type"] == "knowledge_base")
    s3ds = next(d for d in r["data_sources"] if d["type"] == "s3_data_source")
    assert (kb["external_id"], kb["classification"], kb["classification_source"], kb["storage_ref"]) == (
        "KB12345", "restricted", "s3_tag", "arn:aws:s3:::customer-exports")
    assert s3ds["external_id"] == "KB12345/DS00000000" and s3ds["attributes"]["inclusion_prefixes"] == ["exports/"]
    assert r["collaborators"] == []  # collaboration DISABLED: not called


def test_kb_takes_most_sensitive_bucket_and_untagged_bucket_is_none(clients):
    agent, s3, a, s = clients
    a.add_response("get_agent", _agent(guardrail=False), {"agentId": AID})
    a.add_response("list_tags_for_resource", {"tags": {}}, {"resourceArn": ARN})
    _kb(a, buckets=("public-docs", "hr-files", "untagged"))
    s.add_response("get_bucket_tagging", {"TagSet": [{"Key": "DataClassification", "Value": "public"}]}, {"Bucket": "public-docs"})
    s.add_response("get_bucket_tagging", {"TagSet": [{"Key": "DataClassification", "Value": "confidential"}]}, {"Bucket": "hr-files"})
    s.add_client_error("get_bucket_tagging", service_error_code="NoSuchTagSet", http_status_code=404, expected_params={"Bucket": "untagged"})

    r = mod.collect(agent, s3, AID)
    assert r["guardrail"] is None
    kb = next(d for d in r["data_sources"] if d["type"] == "knowledge_base")
    assert kb["classification"] == "confidential" and kb["attributes"]["data_source_count"] == 3
    untagged = next(d for d in r["data_sources"] if d["storage_ref"] == "arn:aws:s3:::untagged" and d["type"] == "s3_data_source")
    assert (untagged["classification"], untagged["classification_source"]) == (None, "none")
    assert r["errors"] == [] and r["evidence_status"]["data_sources"] == "collected"


def test_access_denied_on_knowledge_bases_marks_only_that_domain(clients):
    agent, s3, a, _s = clients
    a.add_response("get_agent", _agent(collaboration="SUPERVISOR"), {"agentId": AID})
    a.add_response("list_tags_for_resource", {"tags": {}}, {"resourceArn": ARN})
    a.add_client_error("list_agent_knowledge_bases", service_error_code="AccessDeniedException", http_status_code=403)
    a.add_response("list_agent_collaborators", {"agentCollaboratorSummaries": [{
        "agentId": AID, "agentVersion": "DRAFT", "collaboratorId": "COLLAB0001", "collaboratorName": "refunds",
        "agentDescriptor": {"aliasArn": "arn:aws:bedrock:us-east-1:111122223333:agent-alias/ABCDEFGHIJ/TSTALIASID"},
        "collaborationInstruction": "Handle refund questions for card disputes.", "relayConversationHistory": "DISABLED",
        "createdAt": NOW, "lastUpdatedAt": NOW}]},
        {"agentId": AID, "agentVersion": "DRAFT"})

    r = mod.collect(agent, s3, AID)
    assert r["evidence_status"] == {"agent": "collected", "tags": "collected", "data_sources": "access_denied", "collaborators": "collected"}
    assert r["data_sources"] == [] and r["errors"][0]["operation"] == "ListAgentKnowledgeBases"
    assert r["collaborators"][0]["type"] == "collaborator" and r["collaborators"][0]["executor_ref"].endswith("TSTALIASID")


def test_bucket_tag_denied_keeps_source_but_no_classification(clients):
    agent, s3, a, s = clients
    a.add_response("get_agent", _agent(), {"agentId": AID})
    a.add_response("list_tags_for_resource", {"tags": {}}, {"resourceArn": ARN})
    _kb(a)
    s.add_client_error("get_bucket_tagging", service_error_code="AccessDenied", http_status_code=403,
                       expected_params={"Bucket": "customer-exports"})

    r = mod.collect(agent, s3, AID)
    s3ds = next(d for d in r["data_sources"] if d["type"] == "s3_data_source")
    assert s3ds["classification"] is None and s3ds["classification_source"] == "none"
    assert r["errors"][0]["operation"] == "GetBucketTagging" and r["errors"][0]["status"] == "access_denied"


def test_unreadable_agent_leaves_other_domains_not_collected(clients):
    agent, s3, a, _s = clients
    a.add_client_error("get_agent", service_error_code="AccessDeniedException", http_status_code=403)
    r = mod.collect(agent, s3, AID)
    assert r["evidence_status"] == {"agent": "access_denied", "tags": "not_collected", "data_sources": "not_collected",
                                    "collaborators": "not_collected"}
    assert r["agent"] == {}
