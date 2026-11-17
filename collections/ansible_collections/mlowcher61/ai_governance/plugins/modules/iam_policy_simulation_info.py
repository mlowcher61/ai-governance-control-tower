#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: iam_policy_simulation_info
short_description: Evaluate IAM actions for a principal with the IAM policy simulator
version_added: "0.1.0"
description:
  - Runs C(iam:SimulatePrincipalPolicy) for a list of checks (action, resource, optional context
    keys) against an IAM role or user, and reports the evaluated decision for each check.
  - Optionally compares each decision with an expected outcome so it can be used for negative
    tests (for example proving a read-only role cannot modify IAM) and remediation verification.
  - This module is read-only. It exists because no certified Ansible collection provides
    C(SimulatePrincipalPolicy) (see docs/plan/06-technical-dependencies.md).
options:
  policy_source_arn:
    description:
      - ARN of the IAM role or user whose identity-based policies (and permissions boundary) are simulated.
    type: str
    required: true
  checks:
    description:
      - The simulations to run. Each check is simulated independently.
    type: list
    elements: dict
    required: true
    suboptions:
      action:
        description: IAM action to evaluate, for example C(iam:AttachRolePolicy).
        type: str
        required: true
      resource:
        description: Resource ARN to evaluate the action against.
        type: str
        default: "*"
      context:
        description:
          - Condition context keys to supply, for example C(iam:ResourceTag/aigov:managed).
            The simulator does not read resource tags itself; tag conditions must be supplied here.
        type: list
        elements: dict
        default: []
        suboptions:
          key:
            description: Context key name.
            type: str
            required: true
          values:
            description: Context key values.
            type: list
            elements: str
            required: true
          type:
            description: Context key type.
            type: str
            default: string
            choices: [string, stringList, numeric, numericList, boolean, booleanList, ip, ipList, binary, binaryList, date, dateList]
      expected:
        description:
          - Expected outcome. C(allowed) passes only for an C(allowed) decision, C(denied) passes for
            C(implicitDeny) or C(explicitDeny). C(any) always passes.
        type: str
        default: any
        choices: [allowed, denied, any]
      description:
        description: Free-text label echoed in the results.
        type: str
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
author:
  - AI Governance Control Tower contributors
"""

EXAMPLES = r"""
- name: Prove the discovery role cannot attach IAM policies
  mlowcher61.ai_governance.iam_policy_simulation_info:
    policy_source_arn: "arn:aws:iam::111122223333:role/aigov/AIGovDiscoveryRole"
    checks:
      - action: iam:AttachRolePolicy
        resource: "arn:aws:iam::111122223333:role/aigov-agents/aigov-demo-quick-helper-bot"
        expected: denied
      - action: bedrock-agentcore:ListAgentRuntimes
        expected: allowed
  register: discovery_simulation

- name: Prove the remediation role can only change roles tagged aigov:managed=true
  mlowcher61.ai_governance.iam_policy_simulation_info:
    policy_source_arn: "arn:aws:iam::111122223333:role/aigov/AIGovRemediationRole"
    checks:
      - action: iam:DetachRolePolicy
        resource: "arn:aws:iam::111122223333:role/some-untagged-role"
        expected: denied
      - action: iam:DetachRolePolicy
        resource: "arn:aws:iam::111122223333:role/aigov-agents/aigov-demo-quick-helper-bot"
        context:
          - key: iam:ResourceTag/aigov:managed
            values: ["true"]
        expected: allowed
"""

RETURN = r"""
results:
  description: One entry per check, in input order.
  returned: always
  type: list
  elements: dict
  contains:
    action:
      description: The simulated action.
      type: str
      sample: iam:AttachRolePolicy
    resource:
      description: The simulated resource ARN.
      type: str
      sample: "*"
    decision:
      description: The simulator decision (C(allowed), C(implicitDeny) or C(explicitDeny)).
      type: str
      sample: implicitDeny
    expected:
      description: The expected outcome supplied in the check.
      type: str
      sample: denied
    passed:
      description: Whether the decision matches the expected outcome.
      type: bool
      sample: true
    matched_statement_count:
      description: Number of policy statements that matched.
      type: int
      sample: 0
    description:
      description: The check label, if provided.
      type: str
      sample: discovery role cannot attach policies
all_passed:
  description: True when every check matched its expected outcome.
  returned: always
  type: bool
  sample: true
failed_checks:
  description: The subset of results whose decision did not match the expectation.
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


def _passed(decision, expected):
    if expected == "any":
        return True
    if expected == "allowed":
        return decision == "allowed"
    return decision in ("implicitDeny", "explicitDeny")


def _context_entries(context):
    return [
        {
            "ContextKeyName": entry["key"],
            "ContextKeyValues": [str(v) for v in entry["values"]],
            "ContextKeyType": entry.get("type") or "string",
        }
        for entry in context or []
    ]


def simulate(client, policy_source_arn, check):
    params = {
        "PolicySourceArn": policy_source_arn,
        "ActionNames": [check["action"]],
        "ResourceArns": [check.get("resource") or "*"],
    }
    entries = _context_entries(check.get("context"))
    if entries:
        params["ContextEntries"] = entries
    paginator = client.get_paginator("simulate_principal_policy")
    decision = None
    matched = 0
    for page in paginator.paginate(**params).build_full_result()["EvaluationResults"]:
        decision = page.get("EvalDecision")
        matched += len(page.get("MatchedStatements", []))
    return decision, matched


def main():
    context_spec = dict(
        key=dict(type="str", required=True, no_log=False),
        values=dict(type="list", elements="str", required=True),
        type=dict(
            type="str",
            default="string",
            choices=[
                "string", "stringList", "numeric", "numericList", "boolean", "booleanList",
                "ip", "ipList", "binary", "binaryList", "date", "dateList",
            ],
        ),
    )
    check_spec = dict(
        action=dict(type="str", required=True),
        resource=dict(type="str", default="*"),
        context=dict(type="list", elements="dict", default=[], options=context_spec),
        expected=dict(type="str", default="any", choices=["allowed", "denied", "any"]),
        description=dict(type="str"),
    )
    argument_spec = dict(
        policy_source_arn=dict(type="str", required=True),
        checks=dict(type="list", elements="dict", required=True, options=check_spec),
    )

    module = AnsibleAWSModule(argument_spec=argument_spec, supports_check_mode=True)
    client = module.client("iam", retry_decorator=AWSRetry.jittered_backoff())

    results = []
    for check in module.params["checks"]:
        try:
            decision, matched = simulate(client, module.params["policy_source_arn"], check)
        except (botocore.exceptions.ClientError, botocore.exceptions.BotoCoreError) as e:
            module.fail_json_aws(e, msg="Failed to simulate {0} for {1}".format(check["action"], module.params["policy_source_arn"]))
        results.append(
            dict(
                action=check["action"],
                resource=check.get("resource") or "*",
                decision=decision,
                expected=check["expected"],
                passed=_passed(decision, check["expected"]),
                matched_statement_count=matched,
                description=check.get("description"),
            )
        )

    failed = [r for r in results if not r["passed"]]
    module.exit_json(changed=False, results=results, all_passed=not failed, failed_checks=failed)


if __name__ == "__main__":
    main()
