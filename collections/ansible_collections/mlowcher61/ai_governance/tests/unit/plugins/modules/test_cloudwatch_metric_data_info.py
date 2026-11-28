"""Unit tests for cloudwatch_metric_data_info (botocore Stubber, no AWS calls)."""

import datetime

import boto3
import pytest
from botocore.stub import ANY, Stubber

from ansible_collections.mlowcher61.ai_governance.plugins.modules import cloudwatch_metric_data_info as mod

RT = "arn:aws:bedrock-agentcore:us-west-1:111122223333:runtime/hr_faq_agent-Hf5Rt2Wq7B"
UTC = datetime.timezone.utc


@pytest.fixture
def cw():
    client = boto3.client("cloudwatch", region_name="us-west-1", aws_access_key_id="x", aws_secret_access_key="x")
    with Stubber(client) as stub:
        yield client, stub


def test_parse_time():
    assert mod.parse_time("2026-11-28T00:00:00Z") == datetime.datetime(2026, 11, 28, tzinfo=UTC)
    assert mod.parse_time("2026-11-28T00:00:00") == datetime.datetime(2026, 11, 28, tzinfo=UTC)
    assert mod.iso(datetime.datetime(2026, 11, 28, 1, 2, 3, tzinfo=UTC)) == "2026-11-28T01:02:03Z"


def test_list_metrics_filters_names_and_flattens_dimensions(cw):
    client, stub = cw
    stub.add_response("list_metrics", {"Metrics": [
        {"Namespace": "AWS/Bedrock-AgentCore", "MetricName": "Invocations", "Dimensions": [{"Name": "Resource", "Value": RT}]},
        {"Namespace": "AWS/Bedrock-AgentCore", "MetricName": "Throttles", "Dimensions": []}]},
        {"Namespace": "AWS/Bedrock-AgentCore"})
    out = mod.list_metrics(client, ["AWS/Bedrock-AgentCore"], ["Invocations"])
    assert out == [{"namespace": "AWS/Bedrock-AgentCore", "metric_name": "Invocations", "dimensions": {"Resource": RT}}]


def test_get_metric_data_merges_pages(cw):
    client, stub = cw
    q = {"id": "q0", "namespace": "AWS/Bedrock-AgentCore", "metric_name": "Invocations", "dimensions": {"Resource": RT},
         "stat": "Sum", "period": 86400}
    start, end = datetime.datetime(2026, 11, 26, tzinfo=UTC), datetime.datetime(2026, 11, 28, tzinfo=UTC)
    stub.add_response("get_metric_data", {"MetricDataResults": [
        {"Id": "q0", "StatusCode": "PartialData", "Timestamps": [datetime.datetime(2026, 11, 26, tzinfo=UTC)], "Values": [3.0]}],
        "NextToken": "t"}, {"MetricDataQueries": ANY, "StartTime": start, "EndTime": end, "ScanBy": "TimestampAscending"})
    stub.add_response("get_metric_data", {"MetricDataResults": [
        {"Id": "q0", "StatusCode": "Complete", "Timestamps": [datetime.datetime(2026, 11, 27, tzinfo=UTC)], "Values": [5.0]}]},
        {"MetricDataQueries": ANY, "StartTime": start, "EndTime": end, "ScanBy": "TimestampAscending", "NextToken": "t"})
    out = mod.get_metric_data(client, [q], start, end)
    assert out == [{"id": "q0", "status": "Complete", "timestamps": ["2026-11-26T00:00:00Z", "2026-11-27T00:00:00Z"],
                    "data_values": [3.0, 5.0]}]


def test_to_api_query():
    api = mod.to_api_query({"id": "q1", "namespace": "N", "metric_name": "M", "dimensions": {"b": 2, "a": "1"}, "stat": "Average"})
    assert api["MetricStat"]["Metric"]["Dimensions"] == [{"Name": "a", "Value": "1"}, {"Name": "b", "Value": "2"}]
    assert api["MetricStat"]["Period"] == 86400 and api["MetricStat"]["Stat"] == "Average" and api["ReturnData"] is True
