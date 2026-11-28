# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
name: usage_queries
short_description: Turn listed CloudWatch metrics into one daily query per metric and AI agent or model
version_added: "0.1.0"
description:
  - Input is the RV(mlowcher61.ai_governance.cloudwatch_metric_data_info#module:metrics) list. Keeps the wanted metrics
    and assigns each to what it measures - an AgentCore runtime (dimension C(Resource)), a Bedrock agent alias
    (C(AgentAliasArn)) or a foundation model (C(ModelId)). Account-level series are skipped (they repeat the agents).
  - When a metric exists for the same agent with several dimension sets (for example per runtime and per endpoint), the
    smallest set is kept and its series are summed, so nothing is counted twice.
  - Used by Collect Usage and Cost (task T3.07), with usage_rows.
positional: _input
options:
  _input:
    description: Listed metrics (namespace, metric_name, dimensions).
    type: list
    elements: dict
    required: true
  wanted:
    description: "Namespace to a mapping of metric name to statistic, for example C(AWS/Bedrock-AgentCore) to C(Invocations) - C(Sum)."
    type: dict
    required: true
  period:
    description: Period in seconds.
    type: int
    default: 86400
"""

EXAMPLES = r"""
queries: "{{ listed.metrics | mlowcher61.ai_governance.usage_queries(aigov_usage_metrics) }}"
rows: "{{ queries | mlowcher61.ai_governance.usage_rows(data.results, prices) }}"
"""

RETURN = r"""
_value:
  description: Queries for cloudwatch_metric_data_info (id, namespace, metric_name, dimensions, stat, period) with
    scope (agent or model), scope_ref and measure.
  type: list
  elements: dict
"""

# Which dimension names an AI agent or model, per namespace
_SCOPE_DIMENSION = {
    "AWS/Bedrock-AgentCore": ("agent", "Resource"),
    "AWS/Bedrock/Agents": ("agent", "AgentAliasArn"),
    "AWS/Bedrock": ("model", "ModelId"),
}

# Common names for the measures the dashboards show
_MEASURE = {
    "Invocations": "invocations", "InvocationCount": "invocations",
    "SessionCount": "sessions",
    "SystemErrors": "errors", "UserErrors": "errors", "Throttles": "errors",
    "InvocationServerErrors": "errors", "InvocationClientErrors": "errors", "InvocationThrottles": "errors",
    "InputTokenCount": "input_tokens", "OutputTokenCount": "output_tokens",
    "ModelInvocationCount": "model_invocations",
    "Latency": "latency_ms", "TotalTime": "latency_ms",
    "CPUUsed-vCPUHours": "vcpu_hours", "MemoryUsed-GBHours": "memory_gb_hours",
}


def measure_of(metric_name):
    return _MEASURE.get(metric_name, metric_name)


def usage_queries(metrics, wanted, period=86400):
    groups = {}
    for m in metrics or []:
        ns, name, dims = m.get("namespace"), m.get("metric_name"), m.get("dimensions") or {}
        stat = (wanted.get(ns) or {}).get(name)
        if not stat or ns not in _SCOPE_DIMENSION:
            continue
        scope, dim = _SCOPE_DIMENSION[ns]
        ref = dims.get(dim)
        if not ref:
            continue  # account-level series
        if scope == "model" and set(dims) != {"ModelId"}:
            continue
        groups.setdefault((ns, name, ref), []).append(dims)
    queries = []
    for (ns, name, ref), dim_sets in sorted(groups.items()):
        smallest = min(len(d) for d in dim_sets)
        scope = _SCOPE_DIMENSION[ns][0]
        for dims in sorted((d for d in dim_sets if len(d) == smallest), key=lambda d: sorted(d.items())):
            queries.append(dict(id="q%d" % len(queries), namespace=ns, metric_name=name, dimensions=dims,
                                stat=wanted[ns][name], period=int(period), scope=scope, scope_ref=ref,
                                measure=measure_of(name)))
    return queries


_API_KEYS = ("id", "namespace", "metric_name", "dimensions", "stat", "period")


def usage_api_queries(queries):
    """The queries with only the fields cloudwatch_metric_data_info accepts."""
    return [{k: q[k] for k in _API_KEYS if k in q} for q in queries or []]


def _price(value):
    try:
        return None if value is None or value == "" else float(value)
    except (TypeError, ValueError):
        return None


def usage_rows(queries, results, prices=None):
    """Daily rows (summed across the series of one metric and agent or model) plus estimated cost rows.

    Returns {rows, estimate_status, unpriced}. estimate_status: priced (every usage with a cost has a price),
    partial, prices_not_set (usage with a cost exists but no price applies), no_usage (nothing to price).
    """
    prices = prices or {}
    by_id = {r["id"]: r for r in results or []}
    agg = {}
    for q in queries or []:
        r = by_id.get(q["id"]) or {}
        for ts, val in zip(r.get("timestamps", []), r.get("data_values", [])):
            key = (ts[:10], q["namespace"], q["metric_name"], q["stat"], q["scope"], q["scope_ref"])
            entry = agg.setdefault(key, dict(sum=0.0, n=0, measure=q["measure"]))
            entry["sum"] += float(val)
            entry["n"] += 1
    rows = []
    for (day, ns, name, stat, scope, ref), e in sorted(agg.items()):
        value = e["sum"] if stat == "Sum" else e["sum"] / e["n"]
        rows.append(dict(day=day, namespace=ns, metric=name, measure=e["measure"], statistic=stat, value=round(value, 6),
                         scope=scope, scope_ref=ref, source="cloudwatch", unit=""))

    currency = prices.get("currency") or "USD"
    runtime = prices.get("agentcore_runtime") or {}
    vcpu_price, mem_price = _price(runtime.get("vcpu_hour")), _price(runtime.get("memory_gb_hour"))
    models = prices.get("models") or {}
    per = {}
    for row in rows:
        per.setdefault((row["day"], row["scope"], row["scope_ref"]), {})[row["measure"]] = row["value"]
    estimates, priced, unpriced = [], 0, set()
    for (day, scope, ref), m in sorted(per.items()):
        cost, has_costed_usage, missing = 0.0, False, False
        if "vcpu_hours" in m or "memory_gb_hours" in m:
            has_costed_usage = True
            if vcpu_price is None or mem_price is None:
                missing = True
            else:
                cost += m.get("vcpu_hours", 0.0) * vcpu_price + m.get("memory_gb_hours", 0.0) * mem_price
        if scope == "model" and ("input_tokens" in m or "output_tokens" in m):
            has_costed_usage = True
            model = models.get(ref) or {}
            p_in, p_out = _price(model.get("input_per_million_tokens")), _price(model.get("output_per_million_tokens"))
            if p_in is None or p_out is None:
                missing = True
            else:
                cost += (m.get("input_tokens", 0.0) * p_in + m.get("output_tokens", 0.0) * p_out) / 1000000.0
        if not has_costed_usage:
            continue
        if missing:
            unpriced.add(ref)
        if not missing or cost > 0:
            priced += 1
            estimates.append(dict(day=day, namespace="", metric="estimated_cost", measure="estimated_cost",
                                  statistic="Sum", value=round(cost, 6), scope=scope, scope_ref=ref, source="estimate",
                                  unit=currency))
    if not priced and not unpriced:
        status = "no_usage"
    elif not unpriced:
        status = "priced"
    elif priced:
        status = "partial"
    else:
        status = "prices_not_set"
    return dict(rows=rows + estimates, estimate_status=status, unpriced=sorted(unpriced))


class FilterModule:
    def filters(self):
        return {"usage_queries": usage_queries, "usage_api_queries": usage_api_queries, "usage_rows": usage_rows}
