#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: sqs_messages_info
short_description: Read messages from an Amazon SQS queue (and optionally delete them)
version_added: "0.1.0"
description:
  - Receives up to O(max_messages) messages from a queue and returns them with their bodies parsed as JSON when possible,
    plus the queue's approximate message counts.
  - Used to capture real change events (task T3.01) and to check the dead-letter queue. The certified amazon.aws
    collection has no SQS module.
  - Without O(delete) the messages become visible again after O(visibility_timeout) seconds.
options:
  queue_url:
    description: URL of the queue.
    type: str
    required: true
  max_messages:
    description: Maximum number of messages to return (received in batches of up to 10).
    type: int
    default: 10
  wait_seconds:
    description: Long-poll wait per receive call (0-20).
    type: int
    default: 2
  visibility_timeout:
    description: Seconds the received messages stay hidden from other readers.
    type: int
    default: 30
  delete:
    description: Delete the returned messages from the queue.
    type: bool
    default: false
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
notes:
  - Requires sqs:ReceiveMessage and sqs:GetQueueAttributes, and sqs:DeleteMessage with O(delete).
author:
  - AI Governance Control Tower contributors (@mlowcher61)
"""

EXAMPLES = r"""
- name: Peek at the captured change events
  mlowcher61.ai_governance.sqs_messages_info:
    queue_url: https://sqs.us-west-1.amazonaws.com/111122223333/aigov-change-events
    max_messages: 20
  register: events
"""

RETURN = r"""
messages:
  description: The received messages.
  returned: always
  type: list
  elements: dict
  contains:
    message_id:
      description: SQS message ID.
      type: str
    body:
      description: The body, parsed as JSON when it is JSON, otherwise the raw text.
      type: raw
    receive_count:
      description: How many times the message was received (ApproximateReceiveCount).
      type: int
approximate_messages:
  description: ApproximateNumberOfMessages before receiving.
  returned: always
  type: int
approximate_not_visible:
  description: ApproximateNumberOfMessagesNotVisible before receiving.
  returned: always
  type: int
deleted:
  description: Number of messages deleted.
  returned: always
  type: int
"""

import json

try:
    import botocore
except ImportError:
    pass  # Handled by AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule
from ansible_collections.amazon.aws.plugins.module_utils.retries import AWSRetry


def parse_body(text):
    """JSON bodies (EventBridge events) are returned as objects; anything else as text."""
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return text


def receive(client, queue_url, max_messages, wait_seconds, visibility_timeout):
    """Return (messages, receipt_handles), receiving in batches of up to 10 until max_messages or the queue is empty."""
    messages, handles = [], []
    while len(messages) < max_messages:
        batch = client.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=min(10, max_messages - len(messages)),
                                       WaitTimeSeconds=wait_seconds, VisibilityTimeout=visibility_timeout,
                                       AttributeNames=["ApproximateReceiveCount"]).get("Messages", [])
        if not batch:
            break
        for m in batch:
            messages.append(dict(message_id=m["MessageId"], body=parse_body(m.get("Body")),
                                 receive_count=int((m.get("Attributes") or {}).get("ApproximateReceiveCount", 1))))
            handles.append(m["ReceiptHandle"])
    return messages, handles


def main():
    module = AnsibleAWSModule(
        argument_spec=dict(
            queue_url=dict(type="str", required=True),
            max_messages=dict(type="int", default=10),
            wait_seconds=dict(type="int", default=2),
            visibility_timeout=dict(type="int", default=30),
            delete=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )
    client = module.client("sqs", retry_decorator=AWSRetry.jittered_backoff())
    p = module.params
    try:
        attrs = client.get_queue_attributes(QueueUrl=p["queue_url"],
                                            AttributeNames=["ApproximateNumberOfMessages",
                                                            "ApproximateNumberOfMessagesNotVisible"])["Attributes"]
        messages, handles = receive(client, p["queue_url"], p["max_messages"], p["wait_seconds"], p["visibility_timeout"])
        deleted = 0
        if p["delete"] and handles and not module.check_mode:
            for i in range(0, len(handles), 10):
                entries = [dict(Id=str(n), ReceiptHandle=h) for n, h in enumerate(handles[i:i + 10])]
                resp = client.delete_message_batch(QueueUrl=p["queue_url"], Entries=entries)
                deleted += len(resp.get("Successful", []))
    except (botocore.exceptions.ClientError, botocore.exceptions.BotoCoreError) as e:
        module.fail_json_aws(e, msg="Failed to read queue {0}".format(p["queue_url"]))
    module.exit_json(changed=deleted > 0, messages=messages, deleted=deleted,
                     approximate_messages=int(attrs.get("ApproximateNumberOfMessages", 0)),
                     approximate_not_visible=int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0)))


if __name__ == "__main__":
    main()
