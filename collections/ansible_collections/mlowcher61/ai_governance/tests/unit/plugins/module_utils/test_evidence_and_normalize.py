"""Unit tests for the shared evidence and IAM normalization helpers."""

import json

from botocore.exceptions import ClientError

from ansible_collections.mlowcher61.ai_governance.plugins.module_utils import evidence as ev
from ansible_collections.mlowcher61.ai_governance.plugins.module_utils import iam_normalize as norm


def _err(code):
    return ClientError({"Error": {"Code": code, "Message": "m"}}, "Op")


def test_access_denied_codes_map_to_access_denied():
    for code in ("AccessDenied", "AccessDeniedException", "UnauthorizedOperation"):
        assert ev.status_for(_err(code)) == "access_denied"


def test_other_errors_map_to_error():
    assert ev.status_for(_err("ThrottlingException")) == "error"
    assert ev.status_for(_err("NoSuchEntity")) == "error"


def test_worst_status_wins():
    assert ev.worst("collected", "access_denied") == "access_denied"
    assert ev.worst("access_denied", "error") == "error"
    assert ev.worst() == "not_collected"


def test_tracker_records_error_and_degrades_domain():
    t = ev.EvidenceTracker("identity", "tags")
    t.failed("identity", "GetPolicyVersion", _err("AccessDenied"), "arn:p")
    assert t.status == {"identity": "access_denied", "tags": "collected"}
    assert t.errors[0]["operation"] == "GetPolicyVersion" and t.errors[0]["code"] == "AccessDenied"


def test_normalize_single_statement_and_strings():
    doc = {"Statement": {"Effect": "Allow", "Action": "*", "Resource": "*"}}
    assert norm.normalize_statements(doc) == [
        {"sid": "", "effect": "Allow", "actions": ["*"], "not_actions": [], "resources": ["*"],
         "not_resources": [], "has_conditions": False}
    ]


def test_normalize_lists_conditions_and_not_fields():
    doc = {"Statement": [{"Sid": "A", "Effect": "Deny", "NotAction": ["iam:*", "sts:*"], "NotResource": "arn:x",
                          "Condition": {"Bool": {"aws:SecureTransport": "false"}}}]}
    st = norm.normalize_statements(doc)[0]
    assert st["not_actions"] == ["iam:*", "sts:*"] and st["not_resources"] == ["arn:x"]
    assert st["actions"] == [] and st["has_conditions"] is True and st["effect"] == "Deny"


def test_parse_url_encoded_and_json_text():
    doc = {"Version": "2012-10-17", "Statement": []}
    assert norm.parse_document(json.dumps(doc)) == doc
    assert norm.parse_document("%7B%22Statement%22%3A%20%5B%5D%7D") == {"Statement": []}


def test_managed_policy_type_and_role_name():
    assert norm.managed_policy_type("arn:aws:iam::aws:policy/AdministratorAccess") == "aws_managed"
    assert norm.managed_policy_type("arn:aws-us-gov:iam::aws:policy/ReadOnlyAccess") == "aws_managed"
    assert norm.managed_policy_type("arn:aws:iam::111122223333:policy/aigov/x") == "customer_managed"
    assert norm.role_name_from_arn("arn:aws:iam::1:role/aigov-agents/my-role") == "my-role"
