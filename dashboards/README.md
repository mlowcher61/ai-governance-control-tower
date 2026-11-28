# Grafana dashboards

The governance dashboards are provisioned from this folder. **AI Governance - Deploy Platform Services** loads every
`json/*.json` file into Grafana (folder *AI Governance*, read-only in the UI) and checks them live. The Grafana URL is
printed by that job; the admin password is in the Kubernetes Secret `<namespace>/grafana-admin`.

| Dashboard | What it shows |
|---|---|
| **AI Governance - Inventory and Findings** | How many AI agents exist; how many are compliant, noncompliant or unknown; unregistered (shadow) agents; critical findings; evidence coverage; agents by risk; findings by policy; the agent list (select an agent to drill down); open findings with the policy explanation and the AI explanation; the compliance trend; recent assessment runs |
| **AI Governance - Agent Detail** | One agent (choose it at the top): what discovery and the registry know, compliance and risk, every policy result with its explanation and the controls it covers, risk factors, the execution role's policies (flagged when a policy cited them), configuration history, and the audit timeline |

Reporting views added for Stage 3 (V016):

| View | What it gives |
|---|---|
| `reporting.compliance_trend` | One row per day from the daily compliance snapshot (captured by the hourly Reconcile and Sweep): agents by status, `compliant_pct`, open findings by severity, open remediations, pending approvals |
| `reporting.mttd_daily` / `reporting.findings_event_attributed` | Time to detect: minutes from an AWS change (CloudTrail event time) to the finding it led to |
| `reporting.mttr_daily` / `reporting.findings_remediated` | Time to remediate: minutes from detection to a verified fix, overall, automatic and after approval |
| `reporting.remediations` | Every remediation with status group (open, verified, failed, closed), route, age, approver, AO execution and AAP jobs |
| `reporting.pending_approvals` | Remediations waiting for a decision and for how long |
| `reporting.remediation_funnel` | Planned → approved or automatic → executed → verified |
| `reporting.change_events_daily` | AWS change events per day: received, mapped, ignored, suppressed, re-assessments started, delivery delay |
| `reporting.drift_events` | Configuration drift explained by the sweep, attributed to a change event or not |

Rules:

- **Panels query only `reporting.*` views** (migrations `database/migrations/V005__reporting_views.sql` and
  `V016__reporting_stage3.sql`), never the tables. Grafana connects as `grafana_ro`, which can read nothing else.
  A new view needs its own `GRANT SELECT ... TO grafana_ro, aigov_auditor` in its migration.
- **The AI explanation is labelled advisory.** The policy explanation decides.

To change a dashboard, edit the JSON (or build it in Grafana, export it with *Share → Export*, and replace the file),
commit, sync the AAP project, and re-run **Deploy Platform Services**. CI runs every panel query as `grafana_ro`
against a test database with the demo data (`database/tests/dashboard_queries.py`), so a broken query fails the build.
