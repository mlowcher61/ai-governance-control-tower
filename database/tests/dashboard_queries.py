#!/usr/bin/env python3
"""Turn every SQL query in dashboards/json/*.json (panels and variables) into a psql script that runs it as
the Grafana user. A broken panel query then fails CI instead of showing an error in Grafana.

    python3 database/tests/dashboard_queries.py | psql -X -v ON_ERROR_STOP=1 -U grafana_ro -d aigov

The $agent dashboard variable is replaced with the highest-risk agent in the database. Each query must run;
with --require-rows (after the demo data is loaded) each panel query must also return at least one row.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENT = "(SELECT agent_id FROM reporting.agent_current ORDER BY risk_rank, name LIMIT 1)"  # Grafana inserts an untyped literal
require_rows = "--require-rows" in sys.argv


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
        sql = sql.replace("'$agent'", AGENT).rstrip().rstrip(";")
        label = f"{dashboard['title']} / {title}".replace("'", "")
        print(f"\\echo '{label}'")
        if require_rows:
            print(f"DO $q$ BEGIN IF (SELECT count(*) FROM ({sql}) AS q) = 0 THEN "
                  f"RAISE EXCEPTION 'panel returned no rows: {label}'; END IF; END $q$;")
        else:
            print(f"SELECT count(*) AS rows FROM ({sql}) AS q;")
print("\\echo 'dashboard queries: all ran'")
