"""Unit tests for usage_queries and usage_rows (Collect Usage and Cost, T3.07)."""

from ansible_collections.mlowcher61.ai_governance.plugins.filter.usage import usage_api_queries, usage_queries, usage_rows

RT = "arn:aws:bedrock-agentcore:us-west-1:111122223333:runtime/hr_faq_agent-Hf5Rt2Wq7B"
WANTED = {"AWS/Bedrock-AgentCore": {"Invocations": "Sum", "Latency": "Average", "CPUUsed-vCPUHours": "Sum",
                                    "MemoryUsed-GBHours": "Sum"},
          "AWS/Bedrock": {"InputTokenCount": "Sum", "OutputTokenCount": "Sum"}}
METRICS = [
    # account level (skipped), runtime level (kept), endpoint level (more dimensions: dropped)
    {"namespace": "AWS/Bedrock-AgentCore", "metric_name": "CPUUsed-vCPUHours", "dimensions": {"Service": "AgentCore.Runtime"}},
    {"namespace": "AWS/Bedrock-AgentCore", "metric_name": "CPUUsed-vCPUHours", "dimensions": {"Service": "AgentCore.Runtime", "Resource": RT}},
    {"namespace": "AWS/Bedrock-AgentCore", "metric_name": "CPUUsed-vCPUHours",
     "dimensions": {"Service": "AgentCore.Runtime", "Resource": RT, "Name": "hr_faq_agent::DEFAULT"}},
    {"namespace": "AWS/Bedrock-AgentCore", "metric_name": "MemoryUsed-GBHours", "dimensions": {"Service": "AgentCore.Runtime", "Resource": RT}},
    # only one dimension set per operation: both kept and summed
    {"namespace": "AWS/Bedrock-AgentCore", "metric_name": "Invocations", "dimensions": {"Operation": "InvokeAgentRuntime", "Resource": RT}},
    {"namespace": "AWS/Bedrock-AgentCore", "metric_name": "Invocations", "dimensions": {"Operation": "InvokeAgentRuntimeCommand", "Resource": RT}},
    {"namespace": "AWS/Bedrock-AgentCore", "metric_name": "Throttles", "dimensions": {"Resource": RT}},  # not wanted
    {"namespace": "AWS/Bedrock", "metric_name": "InputTokenCount", "dimensions": {"ModelId": "amazon.nova-lite-v1:0"}},
    {"namespace": "AWS/Bedrock", "metric_name": "OutputTokenCount", "dimensions": {"ModelId": "amazon.nova-lite-v1:0"}},
    {"namespace": "AWS/Bedrock", "metric_name": "InputTokenCount", "dimensions": {"ModelId": "x", "Other": "y"}},  # not model-only
    {"namespace": "Custom/Thing", "metric_name": "Invocations", "dimensions": {"Resource": RT}},
]


def test_queries_pick_agent_and_model_series():
    qs = usage_queries(METRICS, WANTED)
    keys = [(q["metric_name"], len(q["dimensions"]), q["scope"], q["measure"]) for q in qs]
    assert keys == [("InputTokenCount", 1, "model", "input_tokens"), ("OutputTokenCount", 1, "model", "output_tokens"),
                    ("CPUUsed-vCPUHours", 2, "agent", "vcpu_hours"), ("Invocations", 2, "agent", "invocations"),
                    ("Invocations", 2, "agent", "invocations"), ("MemoryUsed-GBHours", 2, "agent", "memory_gb_hours")]
    assert [q["id"] for q in qs] == ["q0", "q1", "q2", "q3", "q4", "q5"]
    assert all(q["period"] == 86400 for q in qs) and qs[2]["scope_ref"] == RT


def _results(qs, by_metric):
    out = []
    for q in qs:
        pts = by_metric.get(q["metric_name"], [])
        out.append({"id": q["id"], "timestamps": [t for t, _v in pts], "data_values": [v for _t, v in pts]})
    return out


DATA = {"Invocations": [("2026-11-27T00:00:00Z", 5.0)], "CPUUsed-vCPUHours": [("2026-11-27T00:00:00Z", 0.5)],
        "MemoryUsed-GBHours": [("2026-11-27T00:00:00Z", 2.0)], "InputTokenCount": [("2026-11-27T00:00:00Z", 1000000.0)],
        "OutputTokenCount": [("2026-11-27T00:00:00Z", 500000.0)]}


def test_rows_sum_series_and_estimate_cost():
    qs = usage_queries(METRICS, WANTED)
    prices = {"currency": "USD", "agentcore_runtime": {"vcpu_hour": 0.1, "memory_gb_hour": 0.01},
              "models": {"amazon.nova-lite-v1:0": {"input_per_million_tokens": 1.0, "output_per_million_tokens": 4.0}}}
    out = usage_rows(qs, _results(qs, DATA), prices)
    rows = {(r["scope"], r["measure"], r["source"]): r for r in out["rows"]}
    assert rows[("agent", "invocations", "cloudwatch")]["value"] == 10.0  # two operations summed
    assert rows[("agent", "estimated_cost", "estimate")]["value"] == 0.07  # 0.5 * 0.1 + 2 * 0.01
    assert rows[("model", "estimated_cost", "estimate")]["value"] == 3.0  # 1M * 1 + 0.5M * 4 per million
    assert rows[("model", "estimated_cost", "estimate")]["unit"] == "USD"
    assert out["estimate_status"] == "priced" and out["unpriced"] == []
    assert all(r["day"] == "2026-11-27" for r in out["rows"])


def test_rows_without_prices_have_no_estimate():
    qs = usage_queries(METRICS, WANTED)
    out = usage_rows(qs, _results(qs, DATA), {"agentcore_runtime": {"vcpu_hour": None, "memory_gb_hour": None}})
    assert out["estimate_status"] == "prices_not_set"
    assert sorted(out["unpriced"]) == sorted([RT, "amazon.nova-lite-v1:0"])
    assert not [r for r in out["rows"] if r["source"] == "estimate"]


def test_partial_prices_and_no_usage():
    qs = usage_queries(METRICS, WANTED)
    out = usage_rows(qs, _results(qs, DATA), {"agentcore_runtime": {"vcpu_hour": "0.1", "memory_gb_hour": "0.01"}})
    assert out["estimate_status"] == "partial" and out["unpriced"] == ["amazon.nova-lite-v1:0"]
    only_invocations = usage_rows(qs, _results(qs, {"Invocations": [("2026-11-27T00:00:00Z", 3.0)]}), {})
    assert only_invocations["estimate_status"] == "no_usage"
    assert usage_rows([], [], None) == {"rows": [], "estimate_status": "no_usage", "unpriced": []}


def test_average_statistic_is_averaged():
    qs = [{"id": "q0", "namespace": "AWS/Bedrock-AgentCore", "metric_name": "Latency", "stat": "Average", "scope": "agent",
           "scope_ref": RT, "measure": "latency_ms"},
          {"id": "q1", "namespace": "AWS/Bedrock-AgentCore", "metric_name": "Latency", "stat": "Average", "scope": "agent",
           "scope_ref": RT, "measure": "latency_ms"}]
    res = [{"id": "q0", "timestamps": ["2026-11-27T00:00:00Z"], "data_values": [100.0]},
           {"id": "q1", "timestamps": ["2026-11-27T00:00:00Z"], "data_values": [300.0]}]
    assert usage_rows(qs, res)["rows"][0]["value"] == 200.0


def test_api_queries_keep_module_fields_only():
    qs = usage_queries(METRICS, WANTED)
    api = usage_api_queries(qs)
    assert len(api) == len(qs) and set(api[2]) == {"id", "namespace", "metric_name", "dimensions", "stat", "period"}
    assert api[2]["dimensions"] == qs[2]["dimensions"] and usage_api_queries(None) == []


def test_measure_names():
    from ansible_collections.mlowcher61.ai_governance.plugins.filter.usage import measure_of
    assert measure_of("Sessions") == "sessions" and measure_of("SessionCount") == "sessions"
    assert measure_of("Invocations") == "invocations" and measure_of("Unknown") == "Unknown"
