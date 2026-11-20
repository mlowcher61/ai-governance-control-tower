#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: agentcore_runtime_tags
short_description: Set the tags of an Amazon Bedrock AgentCore runtime
version_added: "0.1.0"
description:
  - Makes the tags of an AgentCore runtime equal to O(tags) (with O(purge_tags)), or adds them.
  - AWS system tags (keys starting with C(aws:), for example the C(aws:cloudformation:*) tags) are never changed or removed.
  - Used by the demo reset to restore the demo baseline tags. No certified collection manages AgentCore tags yet.
options:
  resource_arn:
    description: ARN of the runtime.
    type: str
    required: true
  tags:
    description: Tags the runtime must have.
    type: dict
    required: true
  purge_tags:
    description: Remove tags that are not in O(tags).
    type: bool
    default: true
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
notes:
  - Supports check mode.
  - "Permissions used: bedrock-agentcore:ListTagsForResource, bedrock-agentcore:TagResource, bedrock-agentcore:UntagResource."
author:
  - AI Governance Control Tower contributors (@mlowcher61)
"""

EXAMPLES = r"""
- name: Restore the demo baseline tags
  mlowcher61.ai_governance.agentcore_runtime_tags:
    resource_arn: "{{ runtime_arn }}"
    tags: {DataClassification: restricted, CreatedBy: dev-sandbox, "aigov:demo": "true"}
"""

RETURN = r"""
added:
  description: Tags that were (or in check mode would be) added or changed.
  returned: always
  type: dict
removed:
  description: Tag keys that were (or would be) removed.
  returned: always
  type: list
  elements: str
"""

try:
    import botocore
except ImportError:
    pass  # Handled by AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule
from ansible_collections.amazon.aws.plugins.module_utils.retries import AWSRetry


def tag_value(value):
    """Tag values are strings; a YAML boolean becomes "true"/"false" (IAM conditions compare "true", not "True")."""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def system_tag(key):
    """AWS-managed tags (for example aws:cloudformation:stack-name) cannot be changed or removed."""
    return key.lower().startswith("aws:")


def plan(current, wanted, purge):
    """Return (to_add, to_remove) for the current and wanted tag dicts. aws: system tags are never touched."""
    wanted = dict((k, tag_value(v)) for k, v in wanted.items() if not system_tag(k))
    to_add = dict((k, v) for k, v in wanted.items() if current.get(k) != v)
    to_remove = sorted(k for k in current if k not in wanted and not system_tag(k)) if purge else []
    return to_add, to_remove


def main():
    module = AnsibleAWSModule(
        argument_spec=dict(
            resource_arn=dict(type="str", required=True),
            tags=dict(type="dict", required=True),
            purge_tags=dict(type="bool", default=True),
        ),
        supports_check_mode=True,
    )
    try:
        client = module.client("bedrock-agentcore-control", retry_decorator=AWSRetry.jittered_backoff())
    except botocore.exceptions.UnknownServiceError:
        module.fail_json(msg="boto3 has no bedrock-agentcore-control client; use an EE with boto3 >= 1.40 (AI Governance EE)")
    arn = module.params["resource_arn"]
    try:
        current = client.list_tags_for_resource(resourceArn=arn).get("tags", {})
        to_add, to_remove = plan(current, module.params["tags"], module.params["purge_tags"])
        if not module.check_mode:
            if to_remove:
                client.untag_resource(resourceArn=arn, tagKeys=to_remove)
            if to_add:
                client.tag_resource(resourceArn=arn, tags=to_add)
    except (botocore.exceptions.ClientError, botocore.exceptions.BotoCoreError) as e:
        module.fail_json_aws(e, msg="Failed to set the tags of {0}".format(arn))
    module.exit_json(changed=bool(to_add or to_remove), added=to_add, removed=to_remove)


if __name__ == "__main__":
    main()
