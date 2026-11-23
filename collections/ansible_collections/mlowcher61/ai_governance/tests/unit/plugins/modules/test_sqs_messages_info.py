"""Unit tests for sqs_messages_info (botocore Stubber, no AWS calls)."""

import json

import boto3
import pytest
from botocore.stub import Stubber

from ansible_collections.mlowcher61.ai_governance.plugins.modules import sqs_messages_info as mod

URL = "https://sqs.us-west-1.amazonaws.com/111122223333/aigov-change-events"


@pytest.fixture
def sqs():
    client = boto3.client("sqs", region_name="us-west-1", aws_access_key_id="x", aws_secret_access_key="x")
    with Stubber(client) as stub:
        yield client, stub


def _msg(n, body):
    return {"MessageId": "m%d" % n, "ReceiptHandle": "r%d" % n, "Body": body, "Attributes": {"ApproximateReceiveCount": "2"}}


def test_parse_body():
    assert mod.parse_body('{"detail": {"eventName": "AttachRolePolicy"}}') == {"detail": {"eventName": "AttachRolePolicy"}}
    assert mod.parse_body("not json") == "not json"
    assert mod.parse_body(None) is None


def test_receive_batches_until_empty(sqs):
    client, stub = sqs
    event = json.dumps({"source": "aws.iam", "detail": {"eventName": "AttachRolePolicy"}})
    stub.add_response("receive_message", {"Messages": [_msg(1, event), _msg(2, "x")]},
                      {"QueueUrl": URL, "MaxNumberOfMessages": 5, "WaitTimeSeconds": 0, "VisibilityTimeout": 30,
                       "AttributeNames": ["ApproximateReceiveCount"]})
    stub.add_response("receive_message", {},
                      {"QueueUrl": URL, "MaxNumberOfMessages": 3, "WaitTimeSeconds": 0, "VisibilityTimeout": 30,
                       "AttributeNames": ["ApproximateReceiveCount"]})
    messages, handles = mod.receive(client, URL, 5, 0, 30)
    assert [m["message_id"] for m in messages] == ["m1", "m2"] and handles == ["r1", "r2"]
    assert messages[0]["body"]["detail"]["eventName"] == "AttachRolePolicy" and messages[0]["receive_count"] == 2


def test_receive_stops_at_max(sqs):
    client, stub = sqs
    stub.add_response("receive_message", {"Messages": [_msg(n, "{}") for n in range(2)]},
                      {"QueueUrl": URL, "MaxNumberOfMessages": 2, "WaitTimeSeconds": 1, "VisibilityTimeout": 5,
                       "AttributeNames": ["ApproximateReceiveCount"]})
    messages, handles = mod.receive(client, URL, 2, 1, 5)
    assert len(messages) == 2 and len(handles) == 2
