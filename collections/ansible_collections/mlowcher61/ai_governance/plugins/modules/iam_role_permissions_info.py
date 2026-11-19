#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: iam_role_permissions_info
short_description: Read the complete permission picture of an IAM role
version_added: "0.1.0"
description:
  - Returns everything that decides what an IAM role (for example an AI agent's execution role) may do,
    namely the trust policy, tags, the B(documents) of attached managed policies (default version), inline
    policy documents, and the permissions boundary document.
  - Every policy is normalized to the contract shape in C(schemas/common.v1.json) (lists only), and the
    result is returned in the discovery record C(identity) shape (C(schemas/discovery-record.v1.json)).
  - Reports an evidence status instead of failing when access is denied. C(access_denied) and C(error)
    mean the permission picture is incomplete, so policies must return C(unknown), never C(pass).
  - Read-only. It exists because no certified module returns managed policy documents or the permissions
    boundary (see docs/plan/03 section 4.2).
options:
  role_arn:
    description: ARN of the role. Mutually exclusive with O(role_name).
    type: str
  role_name:
    description: Name of the role. Mutually exclusive with O(role_arn).
    type: str
  fail_on_error:
    description:
      - Fail the task when the role cannot be read completely.
      - The default V(false) reports the problem in RV(evidence_status) and RV(errors), which is what
        discovery needs (one unreadable role must not stop the inventory).
    type: bool
    default: false
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
notes:
  - Supports check mode. The module never changes anything.
  - "IAM permissions used: iam:GetRole, iam:ListAttachedRolePolicies, iam:GetPolicy, iam:GetPolicyVersion,
    iam:ListRolePolicies, iam:GetRolePolicy (GetRole also returns the role tags)."
author:
  - AI Governance Control Tower contributors (@mlowcher61)
"""

EXAMPLES = r"""
- name: Read the execution role of an AI agent (as the read-only discovery role)
  mlowcher61.ai_governance.iam_role_permissions_info:
    role_arn: "arn:aws:iam::111122223333:role/aigov-agents/aigov-demo-quick-helper-bot"
    access_key: "{{ aigov_session.sts_creds.access_key }}"
    secret_key: "{{ aigov_session.sts_creds.secret_key }}"
    session_token: "{{ aigov_session.sts_creds.session_token }}"
  register: aigov_role

- name: Use it as the identity of a discovery record
  ansible.builtin.set_fact:
    aigov_identity: "{{ aigov_role.identity }}"
    aigov_identity_evidence: "{{ aigov_role.evidence_status }}"
"""

RETURN = r"""
identity:
  description: The role in the discovery record identity shape. Partial when evidence_status is not collected.
  returned: always
  type: dict
  contains:
    principal_ref:
      description: Role ARN.
      type: str
    permissions_boundary_ref:
      description: ARN of the permissions boundary policy, or null.
      type: str
    trust_policy:
      description: The trust (assume role) policy document.
      type: dict
    tags:
      description: Role tags as a dict.
      type: dict
    policies:
      description: >-
        Attached managed policies (type aws_managed or customer_managed), inline policies (type inline) and
        the permissions boundary (type boundary), each with normalized statements.
      type: list
      elements: dict
evidence_status:
  description: collected, access_denied or error (schemas/common.v1.json evidence_value).
  returned: always
  type: str
  sample: collected
errors:
  description: Every AWS call that failed, with the operation, target, error code and evidence status.
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
from ansible_collections.mlowcher61.ai_governance.plugins.module_utils.evidence import EvidenceTracker
from ansible_collections.mlowcher61.ai_governance.plugins.module_utils.iam_normalize import (
    managed_policy_type,
    normalize_statements,
    parse_document,
    role_name_from_arn,
)

DOMAIN = "identity"


def _managed_policy(client, tracker, policy_arn, policy_type, name=None):
    """A managed policy with the statements of its default version, or None if it could not be read."""
    try:
        policy = client.get_policy(PolicyArn=policy_arn)["Policy"]
        version_id = policy["DefaultVersionId"]
        version = client.get_policy_version(PolicyArn=policy_arn, VersionId=version_id)["PolicyVersion"]
    except botocore.exceptions.ClientError as e:
        tracker.failed(DOMAIN, "GetPolicyVersion", e, policy_arn)
        return None
    return dict(
        type=policy_type,
        ref=policy_arn,
        name=name or policy.get("PolicyName"),
        default_version=version_id,
        statements=normalize_statements(version.get("Document")),
    )


def collect(client, role_name):
    """Return (identity, tracker) for a role. Never raises for AWS client errors."""
    tracker = EvidenceTracker(DOMAIN)
    identity = dict(principal_ref=None, permissions_boundary_ref=None, trust_policy=None, tags={}, policies=[])

    try:
        role = client.get_role(RoleName=role_name)["Role"]
    except botocore.exceptions.ClientError as e:
        tracker.failed(DOMAIN, "GetRole", e, role_name)
        return identity, tracker

    identity["principal_ref"] = role["Arn"]
    identity["trust_policy"] = parse_document(role.get("AssumeRolePolicyDocument"))
    identity["tags"] = dict((t["Key"], t["Value"]) for t in role.get("Tags", []))
    boundary = (role.get("PermissionsBoundary") or {}).get("PermissionsBoundaryArn")
    identity["permissions_boundary_ref"] = boundary

    try:
        paginator = client.get_paginator("list_attached_role_policies")
        attached = paginator.paginate(RoleName=role_name).build_full_result()["AttachedPolicies"]
    except botocore.exceptions.ClientError as e:
        tracker.failed(DOMAIN, "ListAttachedRolePolicies", e, role_name)
        attached = []
    for item in sorted(attached, key=lambda p: p["PolicyArn"]):
        arn = item["PolicyArn"]
        policy = _managed_policy(client, tracker, arn, managed_policy_type(arn), item.get("PolicyName"))
        if policy:
            identity["policies"].append(policy)

    try:
        paginator = client.get_paginator("list_role_policies")
        inline_names = paginator.paginate(RoleName=role_name).build_full_result()["PolicyNames"]
    except botocore.exceptions.ClientError as e:
        tracker.failed(DOMAIN, "ListRolePolicies", e, role_name)
        inline_names = []
    for name in sorted(inline_names):
        try:
            doc = client.get_role_policy(RoleName=role_name, PolicyName=name)["PolicyDocument"]
        except botocore.exceptions.ClientError as e:
            tracker.failed(DOMAIN, "GetRolePolicy", e, "{0}/{1}".format(role_name, name))
            continue
        identity["policies"].append(
            dict(type="inline", ref=name, name=name, default_version=None, statements=normalize_statements(doc))
        )

    if boundary:
        policy = _managed_policy(client, tracker, boundary, "boundary")
        if policy:
            identity["policies"].append(policy)

    return identity, tracker


def main():
    argument_spec = dict(
        role_arn=dict(type="str"),
        role_name=dict(type="str"),
        fail_on_error=dict(type="bool", default=False),
    )
    module = AnsibleAWSModule(
        argument_spec=argument_spec,
        mutually_exclusive=[("role_arn", "role_name")],
        required_one_of=[("role_arn", "role_name")],
        supports_check_mode=True,
    )
    client = module.client("iam", retry_decorator=AWSRetry.jittered_backoff())
    role_name = module.params["role_name"] or role_name_from_arn(module.params["role_arn"])

    try:
        identity, tracker = collect(client, role_name)
    except botocore.exceptions.BotoCoreError as e:
        module.fail_json_aws(e, msg="Failed to read role {0}".format(role_name))

    status = tracker.status[DOMAIN]
    if module.params["fail_on_error"] and tracker.errors:
        module.fail_json(msg="Could not read role {0} completely ({1})".format(role_name, status),
                         identity=identity, evidence_status=status, errors=tracker.errors)
    module.exit_json(changed=False, identity=identity, evidence_status=status, errors=tracker.errors)


if __name__ == "__main__":
    main()
