#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: iam_role_managed_policies
short_description: Set exactly which managed policies (and permissions boundary) an existing IAM role has
version_added: "0.1.0"
description:
  - Makes the attached managed policies of an existing role equal to O(managed_policies), and optionally sets or
    removes its permissions boundary. Nothing else about the role is read or changed.
  - Used by the demo reset with the least-privilege C(AIGovDemoResetRole). The certified
    C(amazon.aws.iam_role) module also manages instance profiles, paths and role settings, which needs IAM
    permissions that the reset role deliberately does not have.
options:
  role_name:
    description: Name of the role (not the ARN).
    type: str
    required: true
  managed_policies:
    description: ARNs of the managed policies the role must have.
    type: list
    elements: str
    required: true
  purge_policies:
    description: Detach attached managed policies that are not in O(managed_policies).
    type: bool
    default: true
  permissions_boundary:
    description:
      - ARN of the permissions boundary the role must have. An empty string removes the boundary.
        Omit it to leave the boundary unchanged.
    type: str
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
notes:
  - Supports check mode.
  - "Permissions used: iam:GetRole, iam:ListAttachedRolePolicies, iam:AttachRolePolicy, iam:DetachRolePolicy,
    iam:PutRolePermissionsBoundary, iam:DeleteRolePermissionsBoundary."
author:
  - AI Governance Control Tower contributors (@mlowcher61)
"""

EXAMPLES = r"""
- name: Restore the demo baseline (AdministratorAccess only)
  mlowcher61.ai_governance.iam_role_managed_policies:
    role_name: aigov-demo-quick-helper-bot
    managed_policies: [arn:aws:iam::aws:policy/AdministratorAccess]
    permissions_boundary: ""
"""

RETURN = r"""
attached:
  description: Policy ARNs that were (or in check mode would be) attached.
  returned: always
  type: list
  elements: str
detached:
  description: Policy ARNs that were (or would be) detached.
  returned: always
  type: list
  elements: str
boundary_before:
  description: The permissions boundary before the change, or null.
  returned: always
  type: str
boundary_after:
  description: The permissions boundary after the change, or null.
  returned: always
  type: str
"""

try:
    import botocore
except ImportError:
    pass  # Handled by AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule
from ansible_collections.amazon.aws.plugins.module_utils.retries import AWSRetry


def plan(client, role_name, wanted, purge, boundary):
    """Return (attached, detached, boundary_before, boundary_after) without changing anything."""
    pages = client.get_paginator("list_attached_role_policies").paginate(RoleName=role_name)
    current = [p["PolicyArn"] for p in pages.build_full_result()["AttachedPolicies"]]
    attach = sorted(set(wanted) - set(current))
    detach = sorted(set(current) - set(wanted)) if purge else []
    before = None
    after = None
    if boundary is not None:
        role = client.get_role(RoleName=role_name)["Role"]
        before = (role.get("PermissionsBoundary") or {}).get("PermissionsBoundaryArn")
        after = boundary or None
    return attach, detach, before, after


def apply(client, role_name, attach, detach, before, after, boundary_managed):
    for arn in attach:
        client.attach_role_policy(RoleName=role_name, PolicyArn=arn)
    for arn in detach:
        client.detach_role_policy(RoleName=role_name, PolicyArn=arn)
    if boundary_managed and before != after:
        if after:
            client.put_role_permissions_boundary(RoleName=role_name, PermissionsBoundary=after)
        else:
            client.delete_role_permissions_boundary(RoleName=role_name)


def main():
    module = AnsibleAWSModule(
        argument_spec=dict(
            role_name=dict(type="str", required=True),
            managed_policies=dict(type="list", elements="str", required=True),
            purge_policies=dict(type="bool", default=True),
            permissions_boundary=dict(type="str"),
        ),
        supports_check_mode=True,
    )
    client = module.client("iam", retry_decorator=AWSRetry.jittered_backoff())
    p = module.params
    try:
        attach, detach, before, after = plan(client, p["role_name"], p["managed_policies"], p["purge_policies"],
                                             p["permissions_boundary"])
        boundary_managed = p["permissions_boundary"] is not None
        changed = bool(attach or detach or (boundary_managed and before != after))
        if changed and not module.check_mode:
            apply(client, p["role_name"], attach, detach, before, after, boundary_managed)
    except (botocore.exceptions.ClientError, botocore.exceptions.BotoCoreError) as e:
        module.fail_json_aws(e, msg="Failed to set the managed policies of role {0}".format(p["role_name"]))
    module.exit_json(changed=changed, attached=attach, detached=detach, boundary_before=before,
                     boundary_after=after if boundary_managed else before)


if __name__ == "__main__":
    main()
