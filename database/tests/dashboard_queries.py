#!/usr/bin/env python3
"""Turn every SQL query in dashboards/json/*.json (panels and variables) into a psql script that runs it as
the Grafana user. A broken panel query then fails CI instead of showing an error in Grafana.

    python3 database/tests/dashboard_queries.py | psql -X -v ON_ERROR_STOP=1 -U grafana_ro -d aigov

Dashboard variables are replaced the way Grafana would: $agent with the highest-risk agent, $run with the latest
governance run, and the time-range macro $__timeFilter(column) with the last 90 days. Each query must run; with
--require-rows (after the demo data is loaded) each panel query must also return at least one row, except the panels in
EMPTY_IN_DEMO_DATA, which show remediation, change-event, sweep or tool data that the CI demo data does not contain
(those panels display a "no data" message instead; the live check in Deploy Platform Services runs them on real data).
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENT = "(SELECT agent_id FROM reporting.agent_current ORDER BY risk_rank, name LIMIT 1)"  # Grafana inserts an untyped literal
RUN = "(SELECT governance_run_id FROM reporting.governance_runs_recent ORDER BY started_at DESC LIMIT 1)"
TIME_FILTER = re.compile(r"\$__timeFilter\(([^()]*(?:\([^()]*\))?[^()]*)\)")
require_rows = "--require-rows" in sys.argv
EMPTY_IN_DEMO_DATA = {
    # Remediations (Stage 2)
    "AI Governance - Agent Detail / Remediations",
    "AI Governance - Executive Overview / Time to remediate per day, by route",
    "AI Governance - Operations / Pending approvals",
    "AI Governance - Operations / Remediations in progress",
    "AI Governance - Operations / Verified remediations per day",
    "AI Governance - Operations / Failed remediations",
    # AWS change events and Reconcile and Sweep (Stage 3)
    "AI Governance - Executive Overview / Time to detect per day",
    "AI Governance - Operations / AWS change events per day",
    "AI Governance - Operations / Configuration drift",
    "AI Governance - Agent Detail / Configuration drift",
    "AI Governance - Audit Explorer / Audit chain checks",
    # Approvals and AI explanations are not recorded by the CI data load
    "AI Governance - Audit Explorer / Human and AI actions",
    # The demo agents are AgentCore runtimes, which do not link tools or data sources
    "AI Governance - Agent Detail / Tools and data sources",
}


def queries(dashboard):
    for panel in dashboard.get("panels", []):
        for t in panel.get("targets", []):
            if t.get("rawSql"):
                yield panel["title"], t["rawSql"]
    for var in dashboard.get("templating", {}).get("list", []):
        if var.get("type") == "query":
            yield "variable " + var["name"], var["query"]


print("\\set ON_ERROR_STOP on")
for path in sorted((ROOT / "dashboards" / "json").glob("*.json")):
    dashboard = json.loads(path.read_text())
    for title, sql in queries(dashboard):
        sql = sql.replace("'$agent'", AGENT).replace("'$run'", RUN).rstrip().rstrip(";")
        sql = TIME_FILTER.sub(lambda m: f"{m.group(1)} > now() - interval '90 days'", sql)
        label = f"{dashboard['title']} / {title}".replace("'", "")
        print(f"\\echo '{label}'")
        if require_rows and label not in EMPTY_IN_DEMO_DATA:
            print(f"DO $q$ BEGIN IF (SELECT count(*) FROM ({sql}) AS q) = 0 THEN "
                  f"RAISE EXCEPTION 'panel returned no rows: {label.replace('%', '%%')}'; END IF; END $q$;")
        else:
            print(f"SELECT count(*) AS rows FROM ({sql}) AS q;")
print("\\echo 'dashboard queries: all ran'")
