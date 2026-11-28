"""Unit tests for agentcore_runtime_invoke (botocore Stubber, no AWS calls)."""

import io
import json

import boto3
import pytest
from botocore.response import StreamingBody
from botocore.stub import Stubber

from ansible_collections.mlowcher61.ai_governance.plugins.modules import agentcore_runtime_invoke as mod

RT = "arn:aws:bedrock-agentcore:us-west-1:111122223333:runtime/hr_faq_agent-Hf5Rt2Wq7B"


@pytest.fixture
def ac():
    client = boto3.client("bedrock-agentcore", region_name="us-west-1", aws_access_key_id="x", aws_secret_access_key="x")
    with Stubber(client) as stub:
        yield client, stub


def _body(text):
    raw = text.encode("utf-8")
    return StreamingBody(io.BytesIO(raw), len(raw))


def test_session_id_is_long_enough():
    sid = mod.new_session_id()
    assert len(sid) >= 33 and sid.startswith("aigov-demo-") and sid != mod.new_session_id()


def test_invoke_counts_and_reports_errors(ac):
    client, stub = ac
    sid = mod.new_session_id()
    expected = {"agentRuntimeArn": RT, "qualifier": "DEFAULT", "runtimeSessionId": sid,
                "payload": json.dumps({"prompt": "hi"}).encode("utf-8"), "contentType": "application/json",
                "accept": "application/json"}
    stub.add_response("invoke_agent_runtime", {"statusCode": 200, "contentType": "application/json",
                                               "runtimeSessionId": sid, "response": _body('{"status": "success"}')}, expected)
    stub.add_client_error("invoke_agent_runtime", service_error_code="AccessDeniedException", http_status_code=403,
                          expected_params=expected)
    out = mod.invoke(client, RT, "DEFAULT", "hi", 2, sid)
    assert out[0] == {"status_code": 200, "response": '{"status": "success"}', "error": ""}
    assert out[1]["status_code"] == 0 and "AccessDenied" in out[1]["error"]
