"""Unit tests for agentcore_runtime_info with botocore Stubber (no AWS calls)."""

import datetime

import boto3
import pytest
from botocore.stub import Stubber

from ansible_collections.mlowcher61.ai_governance.plugins.modules import agentcore_runtime_info as mod

ACCT, REGION = "111122223333", "us-west-1"
NOW = datetime.datetime(2026, 11, 16, 22, 40, tzinfo=datetime.timezone.utc)


def _arn(rid):
    return f"arn:aws:bedrock-agentcore:{REGION}:{ACCT}:runtime/{rid}"


def _summary(rid, name):
    return {"agentRuntimeArn": _arn(rid), "agentRuntimeId": rid, "agentRuntimeVersion": "1", "agentRuntimeName": name,
            "description": "demo", "lastUpdatedAt": NOW, "status": "READY"}


def _get(rid, name, role):
    return {"agentRuntimeArn": _arn(rid), "agentRuntimeName": name, "agentRuntimeId": rid, "agentRuntimeVersion": "1",
            "createdAt": NOW, "lastUpdatedAt": NOW, "roleArn": role, "status": "READY", "description": "demo",
            "lifecycleConfiguration": {"idleRuntimeSessionTimeout": 900, "maxLifetime": 28800},
            "networkConfiguration": {"networkMode": "PUBLIC"}, "protocolConfiguration": {"serverProtocol": "HTTP"},
            "agentRuntimeArtifact": {"codeConfiguration": {"code": {"s3": {"bucket": "b", "prefix": "p"}},
                                                           "runtime": "PYTHON_3_13", "entryPoint": ["main.py"]}},
            "environmentVariables": {"DB_PASSWORD": "hunter2-secret"},
            "workloadIdentityDetails": {"workloadIdentityArn": f"arn:aws:bedrock-agentcore:{REGION}:{ACCT}:workload-identity/x"}}


@pytest.fixture
def stub():
    client = boto3.client("bedrock-agentcore-control", region_name=REGION, aws_access_key_id="x", aws_secret_access_key="x")
    with Stubber(client) as s:
        yield client, s


def _endpoints(s, rid):
    s.add_response("list_agent_runtime_endpoints", {"runtimeEndpoints": [{
        "name": "DEFAULT", "liveVersion": "1", "agentRuntimeEndpointArn": _arn(rid) + "/runtime-endpoint/DEFAULT",
        "agentRuntimeArn": _arn(rid), "status": "READY", "id": "DEFAULT", "createdAt": NOW, "lastUpdatedAt": NOW}]},
        {"agentRuntimeId": rid})


def test_lists_runtimes_with_details_and_no_environment_variables(stub):
    client, s = stub
    s.add_response("list_agent_runtimes", {"agentRuntimes": [_summary("quick_helper_bot-Qh3Zk8Lm1N", "quick_helper_bot"),
                                                             _summary("hr_faq_agent-Hf5Rt2Wq7B", "hr_faq_agent")]}, {})
    for rid, name in (("quick_helper_bot-Qh3Zk8Lm1N", "quick_helper_bot"), ("hr_faq_agent-Hf5Rt2Wq7B", "hr_faq_agent")):
        s.add_response("get_agent_runtime", _get(rid, name, f"arn:aws:iam::{ACCT}:role/aigov-agents/{name}"), {"agentRuntimeId": rid})
        _endpoints(s, rid)
        s.add_response("list_tags_for_resource", {"tags": {"DataClassification": "restricted"}}, {"resourceArn": _arn(rid)})

    runtimes, status, errors = mod.collect(client)
    s.assert_no_pending_responses()
    assert status == "collected" and errors == []
    assert [r["name"] for r in runtimes] == ["hr_faq_agent", "quick_helper_bot"]  # sorted
    r = runtimes[1]
    assert (r["role_arn"], r["network_mode"], r["protocol"], r["code_runtime"], r["authorizer"]) == (
        f"arn:aws:iam::{ACCT}:role/aigov-agents/quick_helper_bot", "PUBLIC", "HTTP", "PYTHON_3_13", None)
    assert r["endpoints"] == [{"name": "DEFAULT", "status": "READY", "live_version": "1"}]
    assert r["evidence_status"] == {"agent": "collected", "tags": "collected"}
    assert "hunter2-secret" not in str(runtimes) and "DB_PASSWORD" not in str(runtimes)


def test_listing_access_denied_is_reported_not_raised(stub):
    client, s = stub
    s.add_client_error("list_agent_runtimes", service_error_code="AccessDeniedException", http_status_code=403)
    runtimes, status, errors = mod.collect(client)
    assert (runtimes, status) == ([], "access_denied") and errors[0]["operation"] == "ListAgentRuntimes"


def test_tags_denied_marks_only_tags(stub):
    client, s = stub
    rid = "research_runtime-Rr9Yx4Kd6C"
    s.add_response("list_agent_runtimes", {"agentRuntimes": [_summary(rid, "research_runtime")]}, {})
    s.add_response("get_agent_runtime", _get(rid, "research_runtime", "arn:aws:iam::1:role/r"), {"agentRuntimeId": rid})
    _endpoints(s, rid)
    s.add_client_error("list_tags_for_resource", service_error_code="AccessDeniedException", http_status_code=403)
    runtimes, _status, _errors = mod.collect(client)
    assert runtimes[0]["evidence_status"] == {"agent": "collected", "tags": "access_denied"}
    assert runtimes[0]["tags"] == {}


def test_filter_by_runtime_id(stub):
    client, s = stub
    s.add_response("list_agent_runtimes", {"agentRuntimes": [_summary("a-1234567890", "a"), _summary("b-1234567890", "b")]}, {})
    s.add_response("get_agent_runtime", _get("b-1234567890", "b", "arn:aws:iam::1:role/b"), {"agentRuntimeId": "b-1234567890"})
    _endpoints(s, "b-1234567890")
    s.add_response("list_tags_for_resource", {"tags": {}}, {"resourceArn": _arn("b-1234567890")})
    runtimes, _status, _errors = mod.collect(client, ["b-1234567890"])
    assert [r["id"] for r in runtimes] == ["b-1234567890"]
