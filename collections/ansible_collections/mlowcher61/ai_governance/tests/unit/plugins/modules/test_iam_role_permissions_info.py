"""Unit tests for iam_role_permissions_info with botocore Stubber (no AWS calls)."""

import datetime
import json
import pathlib

import boto3
import pytest
from botocore.stub import Stubber

from ansible_collections.mlowcher61.ai_governance.plugins.modules import iam_role_permissions_info as mod

ACCT = "111122223333"
ROLE = "aigov-demo-quick-helper-bot"
ROLE_ARN = f"arn:aws:iam::{ACCT}:role/aigov-agents/{ROLE}"
ADMIN = "arn:aws:iam::aws:policy/AdministratorAccess"
BOUNDARY = f"arn:aws:iam::{ACCT}:policy/aigov/aigov-agentcore-runtime-boundary"
NOW = datetime.datetime(2026, 11, 17, tzinfo=datetime.timezone.utc)
TRUST = {"Version": "2012-10-17",
         "Statement": [{"Effect": "Allow", "Principal": {"Service": "bedrock-agentcore.amazonaws.com"}, "Action": "sts:AssumeRole"}]}


@pytest.fixture
def iam():
    client = boto3.client("iam", region_name="us-east-1", aws_access_key_id="x", aws_secret_access_key="x")
    with Stubber(client) as stub:
        yield client, stub


def _role(boundary=None):
    role = {"Path": "/aigov-agents/", "RoleName": ROLE, "RoleId": "AROAEXAMPLEEXAMPLE01", "Arn": ROLE_ARN, "CreateDate": NOW,
            "AssumeRolePolicyDocument": json.dumps(TRUST), "Tags": [{"Key": "aigov:managed", "Value": "true"}]}
    if boundary:
        role["PermissionsBoundary"] = {"PermissionsBoundaryType": "Policy", "PermissionsBoundaryArn": boundary}
    return {"Role": role}


def _policy(arn, name, doc, stub):
    stub.add_response("get_policy", {"Policy": {"PolicyName": name, "Arn": arn, "DefaultVersionId": "v3"}}, {"PolicyArn": arn})
    stub.add_response("get_policy_version", {"PolicyVersion": {"Document": json.dumps(doc), "VersionId": "v3", "IsDefaultVersion": True}},
                      {"PolicyArn": arn, "VersionId": "v3"})


def test_full_picture_with_inline_and_boundary(iam):
    client, stub = iam
    stub.add_response("get_role", _role(BOUNDARY), {"RoleName": ROLE})
    stub.add_response("list_attached_role_policies", {"AttachedPolicies": [{"PolicyName": "AdministratorAccess", "PolicyArn": ADMIN}],
                                                      "IsTruncated": False}, {"RoleName": ROLE})
    _policy(ADMIN, "AdministratorAccess", {"Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]}, stub)
    stub.add_response("list_role_policies", {"PolicyNames": ["extra"], "IsTruncated": False}, {"RoleName": ROLE})
    stub.add_response("get_role_policy", {"RoleName": ROLE, "PolicyName": "extra",
                                          "PolicyDocument": json.dumps({"Statement": [{"Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "*"}]})},
                      {"RoleName": ROLE, "PolicyName": "extra"})
    _policy(BOUNDARY, "aigov-agentcore-runtime-boundary", {"Statement": [{"Effect": "Allow", "NotAction": "iam:*", "Resource": "*"}]}, stub)

    identity, tracker = mod.collect(client, ROLE)
    stub.assert_no_pending_responses()
    assert tracker.status == {"identity": "collected"} and tracker.errors == []
    assert identity["principal_ref"] == ROLE_ARN and identity["permissions_boundary_ref"] == BOUNDARY
    assert identity["tags"] == {"aigov:managed": "true"} and identity["trust_policy"] == TRUST
    assert [(p["type"], p["name"]) for p in identity["policies"]] == [
        ("aws_managed", "AdministratorAccess"), ("inline", "extra"), ("boundary", "aigov-agentcore-runtime-boundary")]
    assert identity["policies"][0]["statements"][0]["actions"] == ["*"]
    assert identity["policies"][0]["default_version"] == "v3"
    assert identity["policies"][2]["statements"][0]["not_actions"] == ["iam:*"]


def test_access_denied_on_policy_document_is_partial_access_denied(iam):
    client, stub = iam
    stub.add_response("get_role", _role(), {"RoleName": ROLE})
    stub.add_response("list_attached_role_policies", {"AttachedPolicies": [{"PolicyName": "AdministratorAccess", "PolicyArn": ADMIN}],
                                                      "IsTruncated": False}, {"RoleName": ROLE})
    stub.add_client_error("get_policy", service_error_code="AccessDenied", http_status_code=403, expected_params={"PolicyArn": ADMIN})
    stub.add_response("list_role_policies", {"PolicyNames": [], "IsTruncated": False}, {"RoleName": ROLE})

    identity, tracker = mod.collect(client, ROLE)
    assert tracker.status["identity"] == "access_denied"
    assert tracker.errors[0]["operation"] == "GetPolicyVersion" and tracker.errors[0]["target"] == ADMIN
    assert identity["policies"] == []  # never reported as "no policies" with evidence collected


def test_missing_role_is_error_not_failure(iam):
    client, stub = iam
    stub.add_client_error("get_role", service_error_code="NoSuchEntity", http_status_code=404, expected_params={"RoleName": ROLE})
    identity, tracker = mod.collect(client, ROLE)
    assert tracker.status["identity"] == "error" and identity["principal_ref"] is None


def test_output_matches_the_discovery_record_contract(iam):
    """The identity this module returns must be a valid discovery-record identity."""
    jsonschema = pytest.importorskip("jsonschema")
    referencing = pytest.importorskip("referencing")
    client, stub = iam
    stub.add_response("get_role", _role(), {"RoleName": ROLE})
    stub.add_response("list_attached_role_policies", {"AttachedPolicies": [{"PolicyName": "AdministratorAccess", "PolicyArn": ADMIN}],
                                                      "IsTruncated": False}, {"RoleName": ROLE})
    _policy(ADMIN, "AdministratorAccess", {"Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]}, stub)
    stub.add_response("list_role_policies", {"PolicyNames": [], "IsTruncated": False}, {"RoleName": ROLE})
    identity, tracker = mod.collect(client, ROLE)

    schemas_dir = pathlib.Path(__file__).resolve().parents[8] / "schemas"
    if not schemas_dir.is_dir():
        pytest.skip("schemas/ not found next to the collection")
    docs = [json.loads(p.read_text()) for p in schemas_dir.glob("*.v1.json")]
    registry = referencing.Registry().with_resources((d["$id"], referencing.Resource.from_contents(d)) for d in docs)
    validator = jsonschema.Draft202012Validator(
        {"$ref": "https://github.com/mlowcher61/ai-governance-control-tower/schemas/discovery-record.v1.json"}, registry=registry)
    record = json.loads((schemas_dir.parent / "policies/fixtures/discovery/quick_helper_bot.json").read_text())
    record["identity"] = dict(identity, simulation={})
    record["evidence_status"]["identity"] = tracker.status["identity"]
    errors = [e.message for e in validator.iter_errors(record)]
    assert not errors, errors
