# AI Governance Control Tower

### Powered by Red Hat Ansible Automation Platform automation orchestrator

> **Status: Stage 0 (foundations) and Stage 1 (discovery and governance) complete; all Stage 1 acceptance criteria pass (2026-11-20). Stage 2 (closed-loop remediation) is in progress: T2.01 to T2.05 and T2.07 to T2.10 are done.** The plan was approved on 2026-11-17. The current environment is cluster **mk6hb**. It was rebuilt from config as code only. Implemented so far:
> - AAP config as code (`aap_config/`)
> - AWS governance roles and demo AgentCore runtimes (CloudFormation)
> - Governance platform services on OpenShift: PostgreSQL, the Inventory API (PostgREST), OPA, and Grafana (`playbooks/platform/`, `platform/`)
> - Database schema (V001) and the Inventory API layer (V002): role-scoped RPC functions and views, with one JWT per role stored in AAP credentials
> - **AI agent discovery** for Amazon Bedrock AgentCore: the four demo agents are in the inventory (`playbooks/discovery/`)
> - **Governance registry as code** (`inventory/registry/`): owners and agent registrations, loaded from Git
> - **Governance policies** in OPA/Rego: 10 per-agent policies, risk scoring, golden decisions, and a publish job that refuses failing bundles (`policies/`)
> - **Policy evaluation**: every agent is judged by OPA, the results and findings are stored, and the findings for the AI step are sanitized (`playbooks/evaluation/`)
> - **WF-01, the AI Governance Assessment workflow** in automation orchestrator: discover, evaluate, AI explanation (advisory), record, summary (`ao_workflows/definitions/`)
> - **Grafana dashboards** from Git: Inventory and Findings, Agent Detail (`dashboards/`)
> - **Demo reset and the Stage 1 end-to-end test**: three reset + assessment cycles end in the same state (`playbooks/demo/`, `playbooks/e2e/`)
> - Data contracts (JSON Schemas) and reference fixtures for the four demo agents (`schemas/`, `policies/fixtures/`)
> - automation orchestrator config as code and the workflow loader (`ao_workflows/`)
> - Environment check and least-privilege verification playbooks
> - CI: lint, unit tests, SQL tests, and HTTP tests through PostgREST
>
> See [Implementation status](#implementation-status) and the detailed [progress log](docs/progress-log.md).

---

## What is this?

Companies are rolling out AI agents quickly: chatbots and assistants built on platforms like **Amazon Bedrock**, Microsoft Foundry, or Google Vertex AI. Each agent:

- runs with a **machine identity**: an IAM role that says what it is allowed to do in your cloud;
- can call **tools** such as APIs and Lambda functions, which can change real systems;
- can read **company data** from knowledge bases;
- often has **no owner**, **no risk review**, and **far too many permissions**.

The **AI Governance Control Tower** finds these agents, checks them against your security rules, explains problems in plain language, and, with a human's approval, **fixes them automatically** using Ansible. Then it **proves** the fix worked and keeps a tamper-evident record of everything.

It is built on tools many enterprises already own, **Red Hat Ansible Automation Platform (AAP)** and its **automation orchestrator (AO)**, plus open standards: **Open Policy Agent (OPA)** for rules, **PostgreSQL** for the inventory, **Grafana** for dashboards, and **OpenTelemetry** for telemetry.

### The idea in one sentence

> **AI explains, policy decides, humans approve, Ansible executes, and the platform verifies and records everything.**

## How it works (the short version)

```
 ┌────────────┐   ┌────────────┐   ┌────────────┐   ┌─────────────┐   ┌──────────┐   ┌───────────┐   ┌──────────┐
 │  DISCOVER  │──▶│  EVALUATE  │──▶│  EXPLAIN   │──▶│  AUTHORIZE  │──▶│ APPROVE  │──▶│ REMEDIATE │──▶│  VERIFY  │
 │ AAP + AWS  │   │ OPA policy │   │ AO AI agent│   │ OPA policy  │   │  Human   │   │ AAP job   │   │ Re-check │
 │ (read-only)│   │ + risk     │   │ (advisory) │   │(deterministic)│ │ in AO    │   │ (scoped)  │   │ + audit  │
 └────────────┘   └────────────┘   └────────────┘   └─────────────┘   └──────────┘   └───────────┘   └──────────┘
```

1. **Discover.** AAP jobs read every AI agent in your AWS account: its model, tools, data sources, tags, and the exact permissions of its IAM role. This uses a read-only role.
2. **Evaluate.** OPA checks each agent against governance rules written in **Rego** (for example: "agents must not have administrator permissions"). It returns a decision, severity, evidence, and a risk score. **Missing information is never treated as "compliant".**
3. **Explain.** An AI task agent in automation orchestrator rewrites each finding in plain language. It is **advisory only**: it cannot change any decision.
4. **Authorize.** OPA decides whether a fix is allowed, which fix to use, and whether a human must approve it.
5. **Approve.** A named security approver reviews the exact planned change and approves or rejects it in AO.
6. **Remediate.** AAP runs an Ansible playbook with a separate, tightly scoped role. For example, it replaces `AdministratorAccess` with an approved least-privilege policy.
7. **Verify.** The workflow re-reads the agent, asks AWS's policy simulator whether the risky permissions are really gone, and re-runs the policy. Only then is the issue closed.

Everything is linked by one correlation ID and written to a hash-chained audit log. Grafana dashboards show posture, trends, and the full audit history.

## Three stages

| Stage | What you get | Plan |
|---|---|---|
| **1. Discovery and Governance** | Inventory of AI agents, OPA policy findings, risk scores, AI explanations, dashboard. **Useful on its own.** | [03-stage-one-plan.md](docs/plan/03-stage-one-plan.md) |
| **2. Closed-Loop Remediation** | Approval-gated, verified, auditable remediation through AAP. **The main demo.** | [04-stage-two-plan.md](docs/plan/04-stage-two-plan.md) |
| **3. Continuous Governance** | Real-time change detection (CloudTrail → EventBridge → SQS → Event-Driven Ansible), drift reconciliation, compliance reports, cost and ROI | [05-stage-three-plan.md](docs/plan/05-stage-three-plan.md) |

## Planning documents

| # | Document | What it covers |
|---|---|---|
| 01 | [Executive overview](docs/plan/01-executive-overview.md) | Business problem, solution, target customers, positioning |
| 02 | [Solution architecture](docs/plan/02-solution-architecture.md) | Components, integrations, topology, authentication, security boundaries, data flows, design decisions |
| 03 | [Stage one plan](docs/plan/03-stage-one-plan.md) | Discovery design, Bedrock APIs, database schema, OPA policy architecture, example policies, WF-01 |
| 04 | [Stage two plan](docs/plan/04-stage-two-plan.md) | WF-02 node-by-node, API contracts, job templates, remediation playbooks, authorization policy, approvals, verification and rollback |
| 05 | [Stage three plan](docs/plan/05-stage-three-plan.md) | Event-driven architecture, EDA rulebook, monitoring, OpenTelemetry, dashboards, compliance evidence, ROI, runbooks, enterprise deployment |
| 06 | [Technical dependencies](docs/plan/06-technical-dependencies.md) | Versions, collections (verified against your private hub), APIs, credentials, cloud resources |
| 07 | [Repository structure](docs/plan/07-repository-structure.md) | Layout, conventions, CI validation |
| 08 | [Security and governance](docs/plan/08-security-and-governance.md) | Threat model, secrets, least privilege, policy authority, approvals, audit |
| 09 | [Testing and validation](docs/plan/09-testing-and-validation.md) | Unit, integration, workflow validation, failure scenarios, acceptance criteria |
| 10 | [Competitive analysis](docs/plan/10-competitive-analysis.md) | ServiceNow AI Control Tower comparison, advantages, gaps |
| 11 | [Customer demo](docs/plan/11-customer-demo.md) | 15–20 minute demonstration script with talking points |
| 12 | [Implementation roadmap](docs/plan/12-implementation-roadmap.md) | Tasks, estimates, critical path, milestones |
| 13 | [Open questions](docs/plan/13-open-questions.md) | Decisions needed, assumptions, licensing, unverified items |
| — | [Progress log](docs/progress-log.md) | What each task built and proved, problems found and fixed, decisions, open items |
| — | [Environment validation](docs/plan/environment-validation.md) | Read-only checks of the target AAP, AO, and AWS environment (2026-11-17) |

## Key terms for new Ansible users

| Term | Meaning |
|---|---|
| **AAP** | Red Hat Ansible Automation Platform: runs Ansible playbooks as **job templates** with stored **credentials** and role-based access |
| **automation orchestrator (AO)** | AAP add-on for visual, multi-step workflows that combine AAP jobs, AI task agents, REST calls, decisions, and human approvals |
| **Event-Driven Ansible (EDA)** | Listens for events (here, AWS changes delivered through SQS) and launches automation in response |
| **OPA / Rego** | Open Policy Agent, an open-source policy engine. Rego is its rule language. Rules live in Git and are unit-tested |
| **Config as code** | AAP, AO, EDA, OPA, Grafana, and the database are all configured from files in this repository, so a new environment can be set up by running playbooks |
| **Certified / validated content** | Red Hat–supported Ansible collections from automation hub. This project prefers them over community content |

## Implementation status

| Task | Status |
|---|---|
| T0.01 Environment validation | Done (read-only checks): see [environment-validation.md](docs/plan/environment-validation.md) |
| T0.02 AO reference capture | Done: OpenAPI 1.3.0 spec plus a runtime-proven reference workflow export; expression syntax resolved |
| T0.03 Repository and CI | Done |
| T0.05 AAP config as code (Stage 0 subset) | Done: `aap_config/` |
| T0.07 AWS governance roles and demo agents | Done in us-west-1. Governance roles deployed. Full verification on the new EE (AAP job 1271): 19/19 least-privilege checks passed, and all 4 AgentCore runtimes are listed READY through the read-only discovery role |
| T0.04 Execution environment | Done: `quay.io/locust61/ai-governance-ee:0.1.0` (public; amd64; boto3 1.43 with AgentCore clients), registered in AAP as `ai-governance-ee` and used by all governance job templates |
| T0.06 Governance platform services | Done (AAP job 1289): PostgreSQL 16, PostgREST v16.6, OPA 1.22.4 (2 replicas), and Grafana 13.3.1 in namespace `ai-governance`. Default-deny NetworkPolicies are proven (a labelled pod reaches the database; an unlabelled pod is blocked). AAP job pods reach OPA and the Inventory API |
| T1.01 Database schema and migrations | Done: `database/migrations/V001__baseline.sql`, applied by **AI Governance - Apply Database Migrations** (t5d26: jobs 1295/1297; mk6hb: job 49, re-run job 51 `changed=0`). Hash-chained, append-only audit log. SQL tests run in CI (`database/tests/run_local.sh` runs them locally) |
| T1.02 Inventory API layer | Done: `database/migrations/V002__api_stage1.sql` adds the Stage 1 `api` functions: discovery runs and records, registry load, evaluation inputs and results, the finding lifecycle, AI explanations, and audit append. It also adds the read-only views. Each function can be run only by its own PostgreSQL role. **AI Governance - Issue API Tokens** signs one JWT per role and stores it in the AAP credential *AI Governance - Inventory API (&lt;role&gt;)*. On mk6hb: V002 applied (job 55); tokens issued and checked (job 56, 15/15 HTTP checks). See [The Inventory API](#the-inventory-api) |
| T1.03 Contracts | Done: nine versioned JSON Schemas in [`schemas/`](schemas/README.md) cover discovery records, the registry, policy inputs and results, evaluation results, the findings sent to the AI, AI explanations, and job artifacts. Key rules are written into the schemas themselves: no silent compliance, explicit evidence, and the AI cannot set decisions. `policies/fixtures/` holds the four demo agents (discovery records, registry, policy inputs). CI validates every fixture and example (56 tests), and a database test proves the Inventory API turns the discovery fixtures into exactly the policy-input fixtures |
| T1.04 Custom read modules | Done: `iam_role_permissions_info`, `bedrock_agent_details_info`, and an evidence mode for `iam_policy_simulation_info` (see the [collection README](collections/ansible_collections/mlowcher61/ai_governance/README.md)). An access-denied error becomes the evidence status `access_denied`, never "nothing found". There are 37 unit tests (botocore Stubber), and the full `ansible-test sanity` suite is clean; both run in CI. Live check on mk6hb: **Verify AWS Baseline** (job 94) reads the four demo execution roles through the discovery role and confirms that AdministratorAccess, and allowed administrator actions, appear only on `quick_helper_bot` |
| T1.06 AgentCore discovery | Done: **AI Governance - Discover AI Agents** works through a read-only discovery role. For each runtime it reads the details, the execution role (with policy documents) and a policy simulation, builds a discovery record, checks it against the contract, and records it through the Inventory API. Environment variables are never collected. On mk6hb: job 98 found and recorded the 4 demo agents; the repeat run (job 99) reported all 4 `unchanged`, so no new history was written. **AI Governance - Check Inventory** (job 103) confirmed 4 agents, all evidence collected, every policy input valid, and AdministratorAccess only on `quick_helper_bot`. Unit tests rebuild the 4 demo fixtures exactly from module outputs |
| T1.07 Governance registry as code | Done: owners and agent registrations live in [`inventory/registry/`](inventory/registry/). **AI Governance - Load Governance Registry** checks them against the contract, for duplicates and for unknown owners. It then loads them, re-matches every agent, and records the Git commit (from AAP's `PROJECT_REVISION`). On mk6hb: job 106 registered 3 agents and left `quick_helper_bot` as the unregistered shadow agent; job 108 recorded commit `9ae5d1c` and re-matched 0 agents (stable). A later discovery run (job 111) kept the registrations, and **Check Inventory** (jobs 110 and 113) confirmed them |
| T1.08 Rego framework and policies | Done: the shared library, 10 policies, risk scoring, and the entry point `governance.evaluate` (see [policies/README.md](policies/README.md)). There are 55 unit tests (99.2% coverage), and golden decisions for the 4 demo agents are checked against the contract in CI. Control IDs follow [rego_policy_libraries](https://github.com/ynotbhatc/rego_policy_libraries) @ `9d26ac4` (for example, IAM-001 automates CIS AWS v7 7.1.3). **AI Governance - Publish Governance Policies** on mk6hb: job 141 published and verified the golden decisions live; job 143, the negative self-test, was refused (`FAIL: 1/56`) without touching the live policies; job 145 needed no restart |
| T1.10 Evaluate job | Done: **AI Governance - Evaluate Governance Policies** reads each agent's policy input, asks OPA, checks the answer against the contract, and records it. Recording opens, refreshes or closes findings and writes the audit log. The findings handed to the AI step come from a new view, `api.findings_for_explanation` (migration V003). It holds structured fields only: values the agent owner controls are masked, only safe characters are kept, length is limited, and next steps come from the policy's own remediation text. On mk6hb: job 154 evaluated 4 agents (1 compliant, 2 noncompliant, 1 unknown) and published 9 sanitized findings; the repeat run (job 156) opened no duplicates; **Check Inventory** (job 157) confirmed compliance, risk and the exact open findings per agent. The CI database test now runs the whole chain, from fixtures to policy inputs to golden decisions to findings |
| T1.11 WF-01 Governance Assessment | Done: [`wf01_governance_assessment.yml`](ao_workflows/definitions/wf01_governance_assessment.yml) chains Discover → Evaluate → *findings to explain?* → AI explanation (advisory) → **Record AI Explanations** → **Publish Assessment Summary**. The summary job closes the governance run with an audit entry (migration V004). On mk6hb (see [VERIFIED.md](ao_workflows/reference/VERIFIED.md)): execution `98433f4f` explained and recorded all 9 findings; execution `c559f2d6` took the nothing-to-explain branch. Along the way I fixed config as code wiping the AO trigger credential; `configure_ao.yml` now re-issues it when needed and disables the orphaned one |
| T1.12 Grafana dashboards | Done: **AI Governance - Inventory and Findings** and **AI Governance - Agent Detail** are provisioned from [`dashboards/json/`](dashboards/README.md) and query only the reporting views from migration V005, as the read-only `grafana_ro` user. **Deploy Platform Services** (job 182 on mk6hb) published them and checked them live: each dashboard is loaded once, and all 24 panel queries ran through Grafana. CI runs every panel query as `grafana_ro` on the demo data |
| T1.13 Demo reset, Stage 1 E2E, rehearsal | Done: **AI Governance - Reset Demo Environment** is an AAP workflow: Reset Demo Agents → Load Governance Registry → Publish Governance Policies. Reset Demo Agents restores the demo baseline in AWS through the restricted demo reset role (new modules `iam_role_managed_policies` and `agentcore_runtime_tags`), and marks the demo findings `demo_reset` with an audit entry (migration V006). It is idempotent. **AI Governance - Stage 1 End-to-End Test**, job 224 on mk6hb: acceptance **A1-1 to A1-9 passed in 3 consecutive reset + WF-01 cycles with an identical end state** (WF-01 executions `7b566ad7`, `9e7d1c45`, `d68ce050`). The demo script now uses the real workflow and dashboard names |
| T2.01 Remediation authorization policies | Done: the action catalog, the policy-to-action map, `governance.remediation.authz` and `governance.remediation.route` (see [policies/README.md](policies/README.md#remediation-authorization-stage-2)), 29 new tests. **Remediation stays off in the committed settings**; the demo profile enables it for one account at publish time. Published on mk6hb (job 259: 84/84 tests, golden decisions live, detection-only) |
| T2.02 Remediation lifecycle (database) | Done: migration V007 adds the remediation functions and their state machine. The database itself enforces the rules: only OPA's chosen action for an eligible violation, no approval bypass, no execution in dry runs, approved rollback only, verification before a finding is resolved, one active remediation per finding, cooldowns, and full audit. Applied on mk6hb (job 261) |
| T2.03 Get Finding Context and Reassess Agent | Done: **Get Finding Context** publishes a finding's remediation context; an unknown finding reports `not_found`. **Reassess Agent** re-collects the agent live from AWS (read-only) and asks OPA, without changing findings, then reports `compliant` (stale), `noncompliant`, `missing_evidence` or `error`. On mk6hb: jobs 266 and 268 (context), and 274/275/277/278 (noncompliant, missing evidence, noncompliant, error) |
| T2.04 Plan Remediation | Done: **Plan Remediation** captures the pre-state read-only (execution role, runtime tags) and asks OPA which action is allowed. It **dry-runs** the action with the real modules in check mode, checks the AI recommendation against its contract (advisory only), and works out the blast radius (shared role or other trusted principals). OPA then picks the route: `auto`, `approval`, `simulate` or `halt`. The job records the remediation with OPA's action (never the AI's) and writes a plain approval summary for the approver. Any problem gives `halt` with the reason. On mk6hb: default settings give `halt` (job 285). With the demo profile (job 288), `quick_helper_bot` IAM-001 gets `approval`: attach the approved policy, detach AdministratorAccess, role not shared, rollback available, AI agrees (job 291). A second plan halts (294), and AWS is unchanged (295) |
| T2.05 Execute Remediation (IAM) | Done: **Execute Remediation** acts only on a recorded remediation that a human approved. Before changing anything, it requires the remediation to be approved and in enforce mode, the role unchanged since the plan (drift check), and OPA to authorize the same action again; otherwise it refuses and changes nothing. Actions: replace managed policy (attach the approved policy, then detach admin), permissions boundary, remove inline admin policies, AgentCore governance tags. The post-state is recorded. **Record Approval Decision** (interim until T2.10) records a named approver's decision; the database refuses the agent owner. On mk6hb: refused before approval (315), approved by a human (316), executed: approved policy attached, AdministratorAccess detached (318), second run refused (320), reassessment: IAM-001 passes (321), finding `verifying` (322) |
| T2.07 Verify Remediation | Done: **Verify Remediation** proves the fix independently of the job that made it. For IAM actions it waits (up to 6 × 10 s) until the administrator probes are denied in IAM policy simulation. It then re-collects the agent with the read-only discovery role and asks OPA. The database decides (`api.record_verification`): the finding's policy passes, no other policy regressed from pass to fail, the probes are denied, and the agent is READY. Only then is the finding resolved as `remediated`; otherwise `verification_failed`. On mk6hb: `quick_helper_bot` IAM-001 verified and resolved (job 327), the first full closed loop. A second run makes no decision (329) |
| T2.08 Rollback Remediation | Done: **Rollback Remediation** restores the pre-state of a remediation that failed or failed verification. It runs only after a human approves the rollback (Record Approval Decision with `aigov_approval_kind: rollback`). It works out the steps from the pre-state and what AWS shows now. When every step is allowed to the remediation role, it runs them, re-reads AWS and confirms the pre-state (`rolled_back`). When a step would re-attach a non-approved policy such as AdministratorAccess, restore another boundary, or recreate an inline policy, the role is denied it **by design** (Q-11): nothing changes, and the job lists and audits the steps for a person (`manual_required`). On mk6hb: quarantine tags for the shadow agent were approved and executed (338, 340) and verification failed honestly (341). Rollback was refused without approval (343), then approved (344) and rolled back, removing exactly the three tags (346). A second rollback (348) and a rollback of a verified fix (349) are refused |
| T2.09 WF-02 Closed-Loop Remediation | Done: the automation orchestrator workflow **AI Governance - WF-02 Closed-Loop Remediation** (`ao_workflows/definitions/wf02_closed_loop_remediation.yml`), loaded from YAML. For one finding it runs: live reassessment → AI recommendation (advisory) → Plan (OPA decides) → **approval in AO** → Execute → independent Verify → outcome → **rollback approval in AO** → Rollback. **Record Approval Decision** reads each decision from the AO approvals API, so the approver identity is never typed in. Every switch reads deterministic results only, and anything unexpected halts. On mk6hb the full approved path ran end to end with the user's approvals in AO (execution `292eac34`). The assessment-error, missing-evidence and halted branches also ran. See [VERIFIED.md](ao_workflows/reference/VERIFIED.md) |
| T2.10 Approval capture, Finalize Audit and Notify | Done: approvals are captured from AO (T2.09). Every WF-02 branch now ends by **finalizing the run**: the database checks that the audit trail holds every event the run implies (planned, human approval, execution, verification, resolution, rollback approval and rollback, outcome) and that the hash chain is intact (`api.audit_completeness`, V012). It then opens, updates or resolves a **ServiceNow incident** per finding (certified `servicenow.itsm`, credential **AI Governance - ServiceNow**). Neither step can fail the run. On mk6hb: without ServiceNow the notification was skipped and audited (job 455). With ServiceNow, incident **INC0011650** was created (459) and updated with a work note on the next run (463), with the audit trail complete each time |
| T0.08 AO config as code and loader | Done. On mk6hb: `configure_ao.yml` created `aigov-trigger` (`project-user`) and stored its credential in AAP; **Apply AO Workflows** (job 62) published both workflows; the loader test (execution `fed0b761`, which ran AAP job 65) and the LLM smoke test (`63ba65dd`) completed. AO administrator items are listed in [ao_workflows/README.md](ao_workflows/README.md#items-only-an-ao-administrator-can-do) |

### Open items (2026-11-19, cluster mk6hb)

None. The AO SSRF allowlist is set by **AI Governance - Configure AO Network Allowlist** (see below).
If another tool rewrites the `ao-admin-settings` ConfigMap in the AO namespace (for example the sales.demos
"Configure Automation Orchestrator" job), run that job template again afterwards.

## The Inventory API

Playbooks never connect to PostgreSQL directly. They call the **Governance Inventory API**, a PostgREST
service at `http://governance-api.ai-governance.svc:3000`. The API is reachable only from inside the cluster,
by AAP job pods and the AO worker. Each request is a JSON `POST /rpc/<function>` (or a `GET` on a view)
with a bearer token. The token decides which PostgreSQL role runs the request, and each role may call only its
own functions:

| AAP credential | Role | May call |
|---|---|---|
| AI Governance - Inventory API (discovery) | `aigov_discovery` | `start_discovery_run`, `record_discovery`, `complete_discovery_run`, `append_audit_event` |
| AI Governance - Inventory API (registry) | `aigov_registry` | `load_registry`, `append_audit_event` |
| AI Governance - Inventory API (evaluator) | `aigov_evaluator` | read `evaluation_inputs`; `record_evaluation`, `record_explanations`, `append_audit_event` |
| AI Governance - Inventory API (remediator) | `aigov_remediator` | `append_audit_event` now; the Stage 2 remediation functions later |
| AI Governance - Inventory API (reader) | `aigov_reader` | read `agent_overview`, `findings_open` |
| AI Governance - Inventory API (auditor) | `aigov_auditor` | `whoami` (the audit reports arrive in a later task) |

A job template gets the API by attaching one of these credentials. That injects the extra vars
`aigov_api_url` and `aigov_api_token`, and a task calls the API like this:

```yaml
- name: Start a discovery run
  ansible.builtin.uri:
    url: "{{ aigov_api_url }}/rpc/start_discovery_run"
    method: POST
    headers:
      Authorization: "Bearer {{ aigov_api_token }}"
    body_format: json
    body:
      scope: {provider: aws, account_ref: "{{ aigov_aws_account_id }}", regions: ["{{ aigov_aws_region }}"]}
  register: aigov_run
  no_log: true   # keeps the token out of the job output
```

Rules that the API enforces itself:

- `record_discovery` is idempotent: sending the same agent twice writes nothing new. A changed agent gets a new
  history snapshot and an `agent.config_drift` audit event.
- An access-denied answer from AWS never erases what is already known. Permissions, tools, and data sources
  are replaced only when that evidence was actually collected.
- Agents that disappear are marked `missing_since`, and only by a fully successful run. They are never deleted.
- A `fail` decision opens a *violation* finding; an `unknown` decision opens an *insufficient evidence* finding.
  Unknown evidence never closes a violation.
- AI explanations are stored as advisory text only, trimmed and limited to four fields. They cannot change a decision.
- Every write appends to the hash-chained audit log, with the caller taken from the token.

Tokens last 90 days (`aigov_api_token_ttl_days`). Re-run **Issue API Tokens** to rotate them.

## Getting started

The configuration-as-code entry points are:
1. **[aap_config/README.md](aap_config/README.md)**: configure AAP from code. This creates the organization, credential types and credentials, project, inventory, and job templates.
2. In AAP, run **AI Governance - Check Environment**, then **Deploy AWS Governance Roles**, **Deploy Demo Agents**, and **Verify AWS Baseline**.
3. **AI Governance - Deploy Platform Services**: PostgreSQL, the Inventory API, OPA, and Grafana on OpenShift. This needs `aigov_openshift_credential`, the name of an existing AAP credential of type "OpenShift or Kubernetes API Bearer Token". The Grafana URL and the location of its admin password are printed at the end of the job.
   Then run **AI Governance - Apply Database Migrations** (creates the schema and the API functions) and **AI Governance - Issue API Tokens** (needs `aigov_aap_credential`, an existing AAP credential of type "Red Hat Ansible Automation Platform"). The second job puts one API token per role into the *AI Governance - Inventory API (…)* credentials.
4. **[ao_workflows/README.md](ao_workflows/README.md)**: configure automation orchestrator (**AI Governance - Configure Automation Orchestrator**) and load the governance workflows (**AI Governance - Apply AO Workflows**).
5. **AI Governance - Configure AO Network Allowlist**: AO blocks calls to cluster-internal addresses by default. This job adds the AAP gateway, OPA and the Inventory API to AO's allowlist (`APP_INTEGRATION_URL_ALLOWED_HOSTS`). It writes them into the `ao-admin-settings` ConfigMap that every AO component loads, keeps any hosts already listed, restarts AO only when the list changed, and checks the value inside a running ao-worker pod. It uses the OpenShift credential, so no AO administrator role is needed. Set `aigov_ao_namespace` in `customer.yml` if AO is not in `automation-orchestrator`.


6. **Open Grafana** (URL printed by Deploy Platform Services; admin password in the Secret `<namespace>/grafana-admin`): folder *AI Governance* has the **Inventory and Findings** and **Agent Detail** dashboards. They fill up once discovery and evaluation have run.
7. **AI Governance - Load Governance Registry**: loads who owns each agent and what is approved (business purpose, data classification, declared model, risk assessment, sensitive data approval) from [`inventory/registry/`](inventory/registry/). Edit those two files for your own agents, commit, sync the project, and run the job. An agent that matches no registration is reported as an **unregistered (shadow) agent**.
8. **AI Governance - Publish Governance Policies**: tests the governance rules in [`policies/`](policies/README.md) and publishes them to OPA. Your settings (approved models, required tags, risk weights) are in `policies/data/governance/config/data.json`.
9. **AI Governance - Discover AI Agents**: finds every AI agent in your AWS account (Amazon Bedrock AgentCore runtimes) with the read-only discovery role and records it in the inventory. Run it again at any time: unchanged agents are not rewritten. **AI Governance - Check Inventory** shows what was found and checks it.
10. **AI Governance - Evaluate Governance Policies**: judges every discovered agent against the published policies and records the results and findings. Check Inventory then shows each agent's compliance, risk score and open findings.
11. **Run the assessment in automation orchestrator**: start the workflow **AI Governance - WF-01 Governance Assessment** (AO UI, or `ansible-playbook ao_workflows/run_workflow.yml -e 'aigov_ao_workflow_name="AI Governance - WF-01 Governance Assessment"'`). It runs discovery and evaluation, asks the AI to explain new findings in plain language, records the explanations, and publishes a summary.
12. **Closed-loop remediation (Stage 2).** Remediation is off in the committed settings. To demonstrate it, run
    **AI Governance - Publish Governance Policies** with `aigov_policy_profile: demo`; that allows remediation in the
    `aigov_aws_account_id` account only. Then start **AI Governance - WF-02 Closed-Loop Remediation** in automation
    orchestrator with a `finding_id`. OPA decides whether and how to fix it. Changes that need a person stop at an
    **approval in AO**: approve or reject there, and the workflow records your decision. It then executes, verifies
    independently, and offers an approval-gated rollback if the fix did not work.
13. **Notifications (optional):** fill in the AAP credential **AI Governance - ServiceNow** (instance URL, an account
    with the `itil` role, optional assignment group). Every WF-02 outcome that needs a person opens or updates one
    ServiceNow incident per finding, and a verified fix resolves it. Without an instance, notifications are skipped and
    only audited.

Credentials are entered into AAP (or pulled from your secret manager). **No secrets are ever stored in this repository.**

## Running the Stage 1 demo

Once the steps above are done, a demo takes three actions. The full script with talking points is in
[docs/plan/11-customer-demo.md](docs/plan/11-customer-demo.md).

1. **Before the demo:** run the AAP workflow **AI Governance - Reset Demo Environment** (about 4 minutes). It puts the
   four demo agents back to their baseline. `quick_helper_bot` is unregistered, has `AdministratorAccess` and
   restricted data. It also resets their findings, then reloads the registry and the policies from Git.
2. **During the demo:** start **AI Governance - WF-01 Governance Assessment** in automation orchestrator and show it run:
   discovery, policy evaluation, the AI explanations, and the summary.
3. **Show the result** in Grafana (**Inventory and Findings**, then **Agent Detail** for `quick_helper_bot`): 4 agents,
   1 compliant, 2 noncompliant, 1 unknown. `quick_helper_bot` is critical (risk 100) with 7 open findings, each with the policy's
   explanation and the AI's plain-language explanation.

**Prove it is repeatable:** **AI Governance - Stage 1 End-to-End Test** runs reset + WF-01 three times and checks
every Stage 1 acceptance criterion (A1-1 to A1-9 in [docs/plan/09](docs/plan/09-testing-and-validation.md#61-stage-1)),
including that all three cycles end in the same state.

## Repository

`github.com/mlowcher61/ai-governance-control-tower` (private for now)
