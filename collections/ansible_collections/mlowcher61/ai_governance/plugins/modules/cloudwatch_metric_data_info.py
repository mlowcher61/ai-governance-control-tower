#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: cloudwatch_metric_data_info
short_description: List Amazon CloudWatch metrics and read their data points (read-only)
version_added: "0.1.0"
description:
  - With O(namespaces), lists the metrics (name and dimensions) that exist in those namespaces. CloudWatch lists a
    metric only if it received data in the past two weeks.
  - With O(queries), reads the data points of each query for the time window (GetMetricData, paginated, up to 500
    queries per request).
  - Used by Collect Usage and Cost (task T3.07) for Amazon Bedrock AgentCore, Bedrock Agents and Bedrock model metrics.
    The certified amazon.aws collection has no module that returns metric data.
options:
  namespaces:
    description: Namespaces whose metrics to list, for example C(AWS/Bedrock-AgentCore).
    type: list
    elements: str
    default: []
  metric_names:
    description: Only list these metric names (all when empty).
    type: list
    elements: str
    default: []
  queries:
    description: Metric data queries.
    type: list
    elements: dict
    default: []
    suboptions:
      id:
        description: Query ID (starts with a lowercase letter; letters, digits, underscores).
        type: str
        required: true
      namespace:
        description: Metric namespace.
        type: str
        required: true
      metric_name:
        description: Metric name.
        type: str
        required: true
      dimensions:
        description: Dimension names and values.
        type: dict
        default: {}
      stat:
        description: Statistic, for example C(Sum) or C(Average).
        type: str
        default: Sum
      period:
        description: Period in seconds.
        type: int
        default: 86400
  start_time:
    description: Start of the window (ISO 8601, UTC). Required with O(queries).
    type: str
  end_time:
    description: End of the window (ISO 8601, UTC). Required with O(queries).
    type: str
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
notes:
  - Requires cloudwatch:ListMetrics and cloudwatch:GetMetricData. Never changes anything.
author:
  - AI Governance Control Tower contributors (@mlowcher61)
"""

EXAMPLES = r"""
- name: List the AgentCore metrics
  mlowcher61.ai_governance.cloudwatch_metric_data_info:
    namespaces: [AWS/Bedrock-AgentCore]
  register: listed

- name: Daily invocations of one runtime
  mlowcher61.ai_governance.cloudwatch_metric_data_info:
    queries:
      - id: q0
        namespace: AWS/Bedrock-AgentCore
        metric_name: Invocations
        dimensions: {Resource: "arn:aws:bedrock-agentcore:us-west-1:111122223333:runtime/hr_faq_agent-Hf5Rt2Wq7B"}
        stat: Sum
    start_time: "2026-11-14T00:00:00Z"
    end_time: "2026-11-28T00:00:00Z"
  register: data
"""

RETURN = r"""
metrics:
  description: The listed metrics.
  returned: always
  type: list
  elements: dict
  contains:
    namespace:
      description: Namespace.
      type: str
    metric_name:
      description: Metric name.
      type: str
    dimensions:
      description: Dimension names and values.
      type: dict
results:
  description: One entry per query.
  returned: always
  type: list
  elements: dict
  contains:
    id:
      description: The query ID.
      type: str
    status:
      description: Complete, PartialData or InternalError (the last status CloudWatch returned).
      type: str
    timestamps:
      description: Data point times (ISO 8601, UTC), oldest first.
      type: list
      elements: str
    data_values:
      description: Values, in the same order as the timestamps.
      type: list
      elements: float
"""

import datetime

try:
    import botocore
except ImportError:
    pass  # Handled by AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule
from ansible_collections.amazon.aws.plugins.module_utils.retries import AWSRetry

MAX_QUERIES = 500


def parse_time(text):
    """ISO 8601 (a trailing Z is accepted) to an aware UTC datetime."""
    value = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    if value.tzinfo is None:
        value = value.replace(tzinfo=datetime.timezone.utc)
    return value.astimezone(datetime.timezone.utc)


def iso(value):
    return value.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def list_metrics(client, namespaces, metric_names):
    """Metrics (namespace, name, dimensions as a dict) in the namespaces, optionally only the given names."""
    wanted = set(metric_names or [])
    out = []
    paginator = client.get_paginator("list_metrics")
    for namespace in namespaces:
        for page in paginator.paginate(Namespace=namespace):
            for m in page.get("Metrics", []):
                if wanted and m["MetricName"] not in wanted:
                    continue
                out.append(dict(namespace=m["Namespace"], metric_name=m["MetricName"],
                                dimensions={d["Name"]: d["Value"] for d in m.get("Dimensions", [])}))
    out.sort(key=lambda m: (m["namespace"], m["metric_name"], sorted(m["dimensions"].items())))
    return out


def to_api_query(q):
    return dict(Id=q["id"], ReturnData=True,
                MetricStat=dict(Metric=dict(Namespace=q["namespace"], MetricName=q["metric_name"],
                                            Dimensions=[dict(Name=k, Value=str(v)) for k, v in sorted((q.get("dimensions") or {}).items())]),
                                Period=int(q.get("period") or 86400), Stat=q.get("stat") or "Sum"))


def get_metric_data(client, queries, start, end):
    """Data points per query ID, oldest first, across pages and batches of 500 queries."""
    merged = {q["id"]: dict(id=q["id"], status="Complete", points={}) for q in queries}
    for i in range(0, len(queries), MAX_QUERIES):
        kwargs = dict(MetricDataQueries=[to_api_query(q) for q in queries[i:i + MAX_QUERIES]],
                      StartTime=start, EndTime=end, ScanBy="TimestampAscending")
        while True:
            resp = client.get_metric_data(**kwargs)
            for r in resp.get("MetricDataResults", []):
                entry = merged[r["Id"]]
                entry["status"] = r.get("StatusCode", entry["status"])
                for ts, val in zip(r.get("Timestamps", []), r.get("Values", [])):
                    entry["points"][iso(ts)] = float(val)
            if not resp.get("NextToken"):
                break
            kwargs["NextToken"] = resp["NextToken"]
    results = []
    for q in queries:
        entry = merged[q["id"]]
        stamps = sorted(entry["points"])
        results.append(dict(id=q["id"], status=entry["status"], timestamps=stamps, data_values=[entry["points"][t] for t in stamps]))
    return results


def main():
    module = AnsibleAWSModule(
        argument_spec=dict(
            namespaces=dict(type="list", elements="str", default=[]),
            metric_names=dict(type="list", elements="str", default=[]),
            queries=dict(type="list", elements="dict", default=[], options=dict(
                id=dict(type="str", required=True),
                namespace=dict(type="str", required=True),
                metric_name=dict(type="str", required=True),
                dimensions=dict(type="dict", default={}),
                stat=dict(type="str", default="Sum"),
                period=dict(type="int", default=86400),
            )),
            start_time=dict(type="str"),
            end_time=dict(type="str"),
        ),
        supports_check_mode=True,
    )
    p = module.params
    client = module.client("cloudwatch", retry_decorator=AWSRetry.jittered_backoff())
    metrics, results = [], []
    try:
        if p["namespaces"]:
            metrics = list_metrics(client, p["namespaces"], p["metric_names"])
        if p["queries"]:
            if not (p["start_time"] and p["end_time"]):
                module.fail_json(msg="start_time and end_time are required with queries")
            results = get_metric_data(client, p["queries"], parse_time(p["start_time"]), parse_time(p["end_time"]))
    except ValueError as e:
        module.fail_json(msg="Invalid time: {0}".format(e))
    except (botocore.exceptions.ClientError, botocore.exceptions.BotoCoreError) as e:
        module.fail_json_aws(e, msg="Failed to read CloudWatch metrics")
    module.exit_json(changed=False, metrics=metrics, results=results)


if __name__ == "__main__":
    main()
