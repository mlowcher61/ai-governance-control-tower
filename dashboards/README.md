# Grafana dashboards

The governance dashboards are provisioned from this folder. **AI Governance - Deploy Platform Services** loads every
`json/*.json` file into Grafana (folder *AI Governance*, read-only in the UI) and checks them live. The Grafana URL is
printed by that job; the admin password is in the Kubernetes Secret `<namespace>/grafana-admin`.

| Dashboard | Who it is for | What it shows |
|---|---|---|
| **AI Governance - Executive Overview** | Leadership, risk owners | Agents discovered, % compliant, noncompliant and unregistered agents, **mean time to detect** (AWS change to finding) and **mean time to remediate** (finding to verified fix); compliance status; agents by risk and by platform; violations by policy; open findings by severity; evidence coverage; the compliance trend; time to detect and to remediate per day (automatic and after approval); AI usage (invocations, sessions, tokens) and the **estimated** cost per day |
| **AI Governance - Operations** | The governance team | Open findings, remediations in progress, pending approvals (with how long they have waited; automation orchestrator expires them after 60 minutes), verified and failed remediations, dead-letter events; open findings by severity and age; verified remediations per day; the remediation funnel; AWS change events per day and the event pipeline; configuration drift; recent governance runs |
| **AI Governance - Agent Detail** | Anyone looking at one agent | One agent (choose it at the top): what discovery and the registry know, compliance and risk, every policy result with its explanation and the controls it covers, risk factors, the execution role's policies, tools and data sources, configuration history and drift, remediations, invocations and the estimated cost per day, and the audit timeline |
| **AI Governance - Audit Explorer** | Auditors | Audit hash-chain status (last check by Reconcile and Sweep); one governance run (choose it at the top) with every audit event in chain order, actors shown as ⚙️ service, 📜 policy, 🤖 AI, 👤 human; human and AI actions; the policy bundle revisions in use (linked to their Git commits); every chain check |
| **AI Governance - Inventory and Findings** | Analysts (Stage 1) | The agent list (select an agent to drill down), open findings with the policy and AI explanations, the compliance trend, recent assessment runs |

**Links.** Tables link to the automation orchestrator execution, the AAP job, the Git commit of a policy revision, the
Agent Detail of an agent and the Audit Explorer of a run. The dashboards hold placeholders (`__AIGOV_AAP_URL__`,
`__AIGOV_AO_URL__`, `__AIGOV_REPO_URL__`, in hidden constant variables) that **Deploy Platform Services** fills in from
config as code (`aigov_aap_hostname`, `aigov_ao_url`, `aigov_project_scm_url` in `aap_config/vars/customer.yml`).

**Colors.** One meaning per color across all dashboards: green good (compliant, pass, verified, intact), yellow
warning (unknown, awaiting approval, medium), orange serious (high), red critical (noncompliant, fail, critical,
failed), gray neutral. Status is always written as text too, never color alone. Series use blue, orange and aqua, a
palette checked for color-blind separation on Grafana's dark and light themes.

Reporting views added for Stage 3 (V016, V017 and V018):

| View | What it gives |
|---|---|
| `reporting.compliance_trend` | One row per day from the daily compliance snapshot (captured by the hourly Reconcile and Sweep): agents by status, `compliant_pct`, open findings by severity, open remediations, pending approvals |
| `reporting.mttd_daily` / `reporting.findings_event_attributed` | Time to detect: minutes from an AWS change (CloudTrail event time) to the finding the event-triggered re-assessment (WF-03) opened |
| `reporting.mttr_daily` / `reporting.findings_remediated` | Time to remediate: minutes from detection to a verified fix, overall, automatic and after approval |
| `reporting.remediations` | Every remediation with status group (open, verified, failed, closed), route, age, approver, AO execution and AAP jobs |
| `reporting.pending_approvals` | Remediations waiting for a decision and for how long |
| `reporting.remediation_funnel` | Planned → approved or automatic → executed → verified |
| `reporting.change_events_daily` | AWS change events per day: received, mapped, ignored, suppressed, re-assessments started, delivery delay |
| `reporting.drift_events` | Configuration drift explained by the sweep, attributed to a change event or not |
| `reporting.compliance_history` | One row per day: the snapshot where one exists, otherwise the day derived from assessments |
| `reporting.audit_chain_status` / `reporting.audit_chain_checks` | The last audit hash-chain check, events since, last sweep, dead-letter count; every check |
| `reporting.audit_timeline` | Every audit event with agent, finding and a short subject (Audit Explorer) |
| `reporting.bundle_revisions` | Policy bundle revisions evaluations used, and which are in use |
| `reporting.agent_resources` | Tools and data sources per agent, with approval of high-risk tools |
| `reporting.usage_daily` / `usage_agent_daily` / `usage_summary_daily` | AI usage from CloudWatch per day (invocations, sessions, errors, tokens, vCPU-hours, GB-hours) and the estimated cost (usage x unit prices; `cost_kind` estimate) |

Rules:

- **Panels query only `reporting.*` views** (migrations `database/migrations/V005__reporting_views.sql` and
  `V016__reporting_stage3.sql`), never the tables. Grafana connects as `grafana_ro`, which can read nothing else.
  A new view needs its own `GRANT SELECT ... TO grafana_ro, aigov_auditor` in its migration.
- **The AI explanation is labelled advisory.** The policy explanation decides.

To change a dashboard, edit the JSON (or build it in Grafana, export it with *Share → Export*, and replace the file),
commit, sync the AAP project, and re-run **Deploy Platform Services**. CI runs every panel query as `grafana_ro`
against a test database with the demo data (`database/tests/dashboard_queries.py`), so a broken query fails the build.
Panels about remediations, change events, the sweep or tools have no rows in that data; they are listed in
`EMPTY_IN_DEMO_DATA` and must still run. The live check in Deploy Platform Services runs every panel through Grafana
and lists the panels with no data on your platform.

Grafana tips that matter here: a stat panel shows only numeric fields unless `reduceOptions.fields` selects the text
field; a table's `noValue` also fills empty cells, so explain an empty table in its description instead.
