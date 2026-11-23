# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
name: change_event_summary
short_description: Summarize an AWS change event (EventBridge "AWS API Call via CloudTrail")
version_added: "0.1.0"
description:
  - Returns the fields the governance event handling needs from an EventBridge event that carries a CloudTrail
    management event - source, event source and name, time, Region, the calling principal, the target (role, policy,
    agent runtime or agent) and any error code. Used by Capture Change Events (T3.01) and Process Change Event (T3.02).
positional: _input
options:
  _input:
    description: The event (the SQS message body), as an object.
    type: dict
    required: true
"""

EXAMPLES = r"""
summary: "{{ message.body | mlowcher61.ai_governance.change_event_summary }}"
"""

RETURN = r"""
_value:
  description: source, detail_type, event_source, event_name, event_id, event_time, region, caller, caller_type,
    target_type, target, error_code.
  type: dict
"""

import re  # noqa: E402

# Where each kind of target is in requestParameters, in order of preference
_TARGETS = (
    ("role", "roleName"),
    ("policy", "policyArn"),
    ("agent_runtime", "agentRuntimeId"),
    ("agent", "agentId"),
    ("resource", "resourceArn"),
)


def _runtime_from_arn(arn):
    m = re.search(r":runtime/([^/]+)$", arn or "")
    return m.group(1) if m else None


def change_event_summary(event):
    event = event if isinstance(event, dict) else {}
    detail = event.get("detail") or {}
    params = detail.get("requestParameters") or {}
    identity = detail.get("userIdentity") or {}
    target_type, target = None, None
    for kind, key in _TARGETS:
        if params.get(key):
            target_type, target = kind, params[key]
            break
    # Tagging calls name the runtime by ARN
    if target_type == "resource" and _runtime_from_arn(target):
        target_type, target = "agent_runtime", _runtime_from_arn(target)
    return dict(source=event.get("source"), detail_type=event.get("detail-type"), event_source=detail.get("eventSource"),
                event_name=detail.get("eventName"), event_id=detail.get("eventID"), event_time=detail.get("eventTime"),
                region=detail.get("awsRegion") or event.get("region"), caller=identity.get("arn"),
                caller_type=identity.get("type"), target_type=target_type, target=target,
                error_code=detail.get("errorCode"))


class FilterModule:
    def filters(self):
        return {"change_event_summary": change_event_summary}
