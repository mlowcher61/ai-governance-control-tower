#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: agentcore_runtime_invoke
short_description: Invoke an Amazon Bedrock AgentCore runtime (demo traffic)
version_added: "0.1.0"
description:
  - Sends O(count) requests, each a JSON body with O(prompt) in its C(prompt) field, to an AgentCore runtime endpoint in
    one runtime session, and returns the HTTP status of each.
  - Used only by Generate Demo Agent Traffic (task T3.07) so the demo agents have usage metrics to collect. Each run
    uses one new session, which keeps the runtime cost of a demo run small.
  - In check mode nothing is invoked.
options:
  agent_runtime_arn:
    description: ARN of the agent runtime.
    type: str
    required: true
  qualifier:
    description: Endpoint name.
    type: str
    default: DEFAULT
  prompt:
    description: Text sent as C(prompt) in each request.
    type: str
    default: AI governance demo traffic
  count:
    description: Number of requests (1-50).
    type: int
    default: 1
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
notes:
  - Requires bedrock-agentcore:InvokeAgentRuntime on the runtime (and its endpoint).
author:
  - AI Governance Control Tower contributors (@mlowcher61)
"""

EXAMPLES = r"""
- name: Five requests to the HR demo agent
  mlowcher61.ai_governance.agentcore_runtime_invoke:
    agent_runtime_arn: arn:aws:bedrock-agentcore:us-west-1:111122223333:runtime/hr_faq_agent-Hf5Rt2Wq7B
    count: 5
"""

RETURN = r"""
session_id:
  description: The runtime session used for all requests.
  returned: always
  type: str
invocations:
  description: One entry per request.
  returned: always
  type: list
  elements: dict
  contains:
    status_code:
      description: HTTP status returned by the agent (0 when the call failed before reaching it).
      type: int
    response:
      description: The agent's response, at most 300 characters.
      type: str
    error:
      description: The error, when the call failed.
      type: str
succeeded:
  description: Requests that returned HTTP 2xx.
  returned: always
  type: int
"""

import json
import uuid

try:
    import botocore
except ImportError:
    pass  # Handled by AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule
from ansible_collections.amazon.aws.plugins.module_utils.retries import AWSRetry


def new_session_id():
    """AgentCore needs a session ID of at least 33 characters."""
    return "aigov-demo-" + uuid.uuid4().hex


def read_body(resp):
    body = resp.get("response")
    raw = body.read() if hasattr(body, "read") else (body or b"")
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")
    return str(raw)[:300]


def invoke(client, arn, qualifier, prompt, count, session_id):
    """Send count requests in one session; errors are reported per request, not raised."""
    out = []
    payload = json.dumps({"prompt": prompt}).encode("utf-8")
    for _attempt in range(count):
        try:
            resp = client.invoke_agent_runtime(agentRuntimeArn=arn, qualifier=qualifier, runtimeSessionId=session_id,
                                               payload=payload, contentType="application/json", accept="application/json")
            out.append(dict(status_code=int(resp.get("statusCode", 200)), response=read_body(resp), error=""))
        except (botocore.exceptions.ClientError, botocore.exceptions.BotoCoreError) as e:
            out.append(dict(status_code=0, response="", error=str(e)[:300]))
    return out


def main():
    module = AnsibleAWSModule(
        argument_spec=dict(
            agent_runtime_arn=dict(type="str", required=True),
            qualifier=dict(type="str", default="DEFAULT"),
            prompt=dict(type="str", default="AI governance demo traffic"),
            count=dict(type="int", default=1),
        ),
        supports_check_mode=True,
    )
    p = module.params
    if not 1 <= p["count"] <= 50:
        module.fail_json(msg="count must be between 1 and 50")
    session_id = new_session_id()
    if module.check_mode:
        module.exit_json(changed=True, session_id=session_id, invocations=[], succeeded=0)
    client = module.client("bedrock-agentcore", retry_decorator=AWSRetry.jittered_backoff())
    invocations = invoke(client, p["agent_runtime_arn"], p["qualifier"], p["prompt"], p["count"], session_id)
    succeeded = sum(1 for i in invocations if 200 <= i["status_code"] < 300)
    module.exit_json(changed=True, session_id=session_id, invocations=invocations, succeeded=succeeded)


if __name__ == "__main__":
    main()
