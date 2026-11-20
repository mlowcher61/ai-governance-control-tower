"""Unit tests for iam_role_managed_policies and agentcore_runtime_tags (botocore Stubber, no AWS calls)."""

import boto3
import pytest
from botocore.stub import Stubber

from ansible_collections.mlowcher61.ai_governance.plugins.modules import agentcore_runtime_tags as tags_mod
from ansible_collections.mlowcher61.ai_governance.plugins.modules import iam_role_managed_policies as pol_mod

ADMIN = "arn:aws:iam::aws:policy/AdministratorAccess"
APPROVED = "arn:aws:iam::111122223333:policy/aigov/aigov-approved-agentcore-runtime-basic"
BOUNDARY = "arn:aws:iam::111122223333:policy/aigov/boundary"
ROLE = "aigov-demo-quick-helper-bot"


@pytest.fixture
def iam():
    client = boto3.client("iam", region_name="us-east-1", aws_access_key_id="x", aws_secret_access_key="x")
    with Stubber(client) as stub:
        yield client, stub


def _attached(stub, arns):
    stub.add_response("list_attached_role_policies",
                      {"AttachedPolicies": [{"PolicyArn": a, "PolicyName": a.rsplit("/", 1)[-1]} for a in arns], "IsTruncated": False},
                      {"RoleName": ROLE})


def test_remediated_role_is_put_back_to_admin_and_boundary_removed(iam):
    client, stub = iam
    _attached(stub, [APPROVED])
    stub.add_response("get_role", {"Role": {"Path": "/aigov-agents/", "RoleName": ROLE, "RoleId": "AROAEXAMPLEEXAMPLE01",
                                            "Arn": f"arn:aws:iam::111122223333:role/aigov-agents/{ROLE}",
                                            "CreateDate": "2026-11-01T00:00:00Z",
                                            "PermissionsBoundary": {"PermissionsBoundaryType": "Policy", "PermissionsBoundaryArn": BOUNDARY}}},
                      {"RoleName": ROLE})
    attach, detach, before, after = pol_mod.plan(client, ROLE, [ADMIN], True, "")
    assert (attach, detach, before, after) == ([ADMIN], [APPROVED], BOUNDARY, None)
    stub.add_response("attach_role_policy", {}, {"RoleName": ROLE, "PolicyArn": ADMIN})
    stub.add_response("detach_role_policy", {}, {"RoleName": ROLE, "PolicyArn": APPROVED})
    stub.add_response("delete_role_permissions_boundary", {}, {"RoleName": ROLE})
    pol_mod.apply(client, ROLE, attach, detach, before, after, True)
    stub.assert_no_pending_responses()


def test_baseline_role_needs_no_change_and_boundary_untouched_when_omitted(iam):
    client, stub = iam
    _attached(stub, [ADMIN])
    assert pol_mod.plan(client, ROLE, [ADMIN], True, None) == ([], [], None, None)
    stub.assert_no_pending_responses()  # get_role not called when the boundary is not managed


def test_no_purge_keeps_extra_policies(iam):
    client, stub = iam
    _attached(stub, [ADMIN, APPROVED])
    attach, detach, _before, _after = pol_mod.plan(client, ROLE, [ADMIN], False, None)
    assert (attach, detach) == ([], [])


def test_runtime_tags_plan():
    current = {"DataClassification": "internal", "Owner": "x@example.com", "aigov:demo": "true"}
    wanted = {"DataClassification": "restricted", "CreatedBy": "dev-sandbox", "aigov:demo": True}
    to_add, to_remove = tags_mod.plan(current, wanted, True)
    assert to_add == {"DataClassification": "restricted", "CreatedBy": "dev-sandbox"}
    assert to_remove == ["Owner"]
    assert tags_mod.plan(current, wanted, False)[1] == []
    assert tags_mod.plan({"aigov:demo": "true"}, {"aigov:demo": "true"}, True) == ({}, [])
