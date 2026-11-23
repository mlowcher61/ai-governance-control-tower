"""Unit tests for change_event_summary."""

from ansible_collections.mlowcher61.ai_governance.plugins.filter.events import change_event_summary

IAM = {
    "source": "aws.iam", "detail-type": "AWS API Call via CloudTrail", "region": "us-east-1",
    "detail": {"eventSource": "iam.amazonaws.com", "eventName": "AttachRolePolicy", "eventID": "e1", "awsRegion": "us-east-1",
               "eventTime": "2026-11-23T10:00:00Z",
               "userIdentity": {"type": "AssumedRole", "arn": "arn:aws:sts::111122223333:assumed-role/AIGovRemediationRole/aigov-x"},
               "requestParameters": {"roleName": "aigov-demo-quick-helper-bot", "policyArn": "arn:aws:iam::aws:policy/AdministratorAccess"}},
}
TAG = {
    "source": "aws.bedrock-agentcore", "detail-type": "AWS API Call via CloudTrail",
    "detail": {"eventSource": "bedrock-agentcore.amazonaws.com", "eventName": "TagResource", "awsRegion": "us-west-1",
               "userIdentity": {"type": "IAMUser", "arn": "arn:aws:iam::111122223333:user/dev"},
               "requestParameters": {"resourceArn": "arn:aws:bedrock-agentcore:us-west-1:111122223333:runtime/quick_helper_bot-AbC123"}},
}


def test_iam_event():
    s = change_event_summary(IAM)
    assert s["event_name"] == "AttachRolePolicy" and s["target_type"] == "role" and s["target"] == "aigov-demo-quick-helper-bot"
    assert s["caller"].endswith("AIGovRemediationRole/aigov-x") and s["region"] == "us-east-1" and s["error_code"] is None


def test_tag_event_names_the_runtime():
    s = change_event_summary(TAG)
    assert s["target_type"] == "agent_runtime" and s["target"] == "quick_helper_bot-AbC123" and s["event_source"] == "bedrock-agentcore.amazonaws.com"


def test_failed_call_and_garbage():
    s = change_event_summary({"detail": {"eventName": "DetachRolePolicy", "errorCode": "AccessDenied", "requestParameters": None}})
    assert s["error_code"] == "AccessDenied" and s["target"] is None
    assert change_event_summary("not an event")["event_name"] is None
