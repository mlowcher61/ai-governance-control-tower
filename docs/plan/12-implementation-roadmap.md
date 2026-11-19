# 12 — Implementation Roadmap

## 1. Estimating assumptions

| Assumption | Detail |
|---|---|
| Engineer profile | Senior engineer, proficient in Ansible and AAP config-as-code, Python module development, SQL, and basic Rego and OpenShift; familiar with the AO reference repositories |
| Environment readiness | AAP 2.7 and AO (2026.8) are installed and reachable on OpenShift before T0.02 starts; a namespace for governance services is granted; a demo AWS account with admin access for setup exists; an LLM endpoint is available to AO |
| Integration access | AO admin (credentials, integrations, service accounts, SSRF allowlist); AAP organization admin; GitHub repository admin |
| Units | Engineer-days (ED) of focused work, excluding customer meetings and approval wait times |
| Contingency | Add **20%** to totals for unknowns, mainly AO behavior and Bedrock account constraints |
| AI-assisted coding | Not assumed in the estimates. If used, expect a reduction on boilerplate tasks, but not on integration and validation tasks |

**Priorities:**

- **P0:** MVP, required for the stage's success criteria.
- **P1:** strongly recommended enhancement.
- **P2:** future enhancement.

## 2. Effort summary

| Stage | P0 (MVP) | P1 | P2 | Notes |
|---|---|---|---|---|
| Stage 0 — Foundations (part of Stage 1 delivery) | 17.5 | — | — | Environment, CI, EE, config as code, platform services, AWS baseline, AO setup |
| Stage 1 — Discovery and governance | 28.5 | 2.5 | — | AgentCore is P0 (decided); the Classic adapter T1.05 is P1. |
| **Stage 1 standalone POC total** | **46.0** | 2.5 | — | **≈ 55 ED with contingency** |
| Stage 2 — Closed-loop remediation | 26.0 | 5.0 | — | |
| Stage 3 — Continuous governance | 22.5 | 7.0 | 8.0 | |
| **All stages** | **94.5** | **14.5** | **8.0** | **≈ 113 ED for P0 with contingency** |

**Calendar view (P0, with contingency):**

| Team | Stage 1 | Stage 2 | Stage 3 | Total |
|---|---|---|---|---|
| 1 engineer | ~11 weeks | ~6 weeks | ~5.5 weeks | ~22–23 weeks |
| 2 engineers | ~6–7 weeks | ~4 weeks | ~3 weeks | **~13–14 weeks** (bounded by the critical path, §4) |

## 3. Task breakdown

Column key:

- **Prereq:** environment or access prerequisites.
- **Deps:** task dependencies.

### Stage 0 — Foundations

| ID | Description | Pri | Prereq | Technology | ED | Acceptance criteria | Testing | Deps | Risks |
|---|---|---|---|---|---|---|---|---|---|
| T0.01 | **Environment validation and access checklist.** Confirm the AAP 2.7 version, AO version and operator channel, OpenShift version, namespace rights, and the hub collections list. Test `bedrock-agent:CreateAgent` in the demo account (allowlisted or not). Confirm AgentCore Region availability and the LLM endpoint | P0 | Accounts issued | AAP, AO, OCP, AWS | 1.0 | Signed checklist in `docs/plan/environment-validation.md`; Bedrock decision recorded (Classic vs AgentCore) | Manual + scripted probes | — | **Bedrock account not allowlisted** → AgentCore path (+2 ED); AO not installed |
| T0.02 | **AO reference capture and behavior spike.** Export a known-good workflow from the target AO and capture `/api_docs/v1/openapi.json` and the version. Validate a minimal throwaway workflow covering: manual trigger input expression; `aap_job_template` artifacts; `http_request` to an internal service; `agentic` with `response_schema` and `tool_selection_strategy: NONE`; `condition`/`switch` with string compares; OR-join behavior; approval `approver_users`, `fallback_decision`, timeout; agentic-failure behavior; execution-ID expression availability | P0 | AO admin; AAP integration; LLM integration | AO REST API | 2.0 | `ao_workflows/reference/` populated; `docs/plan/ao-behavior-findings.md` answers each §3.1 question in the Stage 2 plan with evidence (execution IDs) | Spike workflow executions | T0.01 | AO behaviors differ from reference repos → design fallbacks (documented in the Stage 2 plan §3.1) |
| T0.03 | **Repository scaffold and CI.** Create the layout per 07, plus pre-commit, the GitHub Actions jobs (lint, sanity, rego, contracts, sql, golden, ao-render), CODEOWNERS, and a README skeleton | P0 | GitHub repo | GitHub Actions, ansible-lint, OPA, Regal, ruff, PostgreSQL service | 2.0 | CI green on the empty scaffold; a failing sample proves each gate blocks | CI self-test | — | — |
| T0.04 | **Execution and decision environments.** Build the `ai-governance-ee` (ee-minimal-rhel9 AAP 2.7, pinned certified collections, boto3, jsonschema, opa) and `ai-governance-de` images with ansible-builder v3 | P0 | Registry credentials; `registry.redhat.io` access | ansible-builder | 1.5 | Images pushed with immutable tags; `ansible-doc` lists required modules; boto3 has `bedrock-agentcore-control` and alias invocation state | Smoke playbook in EE | T0.03 | Hub sync lag for `amazon.ai` 2.x (does not block) |
| T0.05 | **AAP config as code baseline.** Organization, teams, `svc-aigov-ao` user, custom credential types, credential placeholders, project, inventory, EE registration, RBAC, using `infra.aap_configuration` dispatch (`ansible.platform` for gateway objects) | P0 | AAP org admin token | infra.aap_configuration, ansible.platform, ansible.controller | 2.0 | `configure_aap.yml` idempotent (second run `changed=0`); `vars/customer.example.yml` documented | Run twice; ansible-lint | T0.03, T0.04 | Module routing differences between `ansible.platform` and `ansible.controller` (verified: `ansible.platform` 2.7.20260930 is gateway-only) |
| T0.06 | **Deploy governance platform services.** PostgreSQL, PostgREST, OPA, and Grafana skeleton on OpenShift with NetworkPolicies, Routes (Grafana), and Secrets (JWT secret). JT *Deploy Platform Services* | P0 | Namespace rights; OCP token credential | kubernetes.core | 3.0 | All pods ready; `GET /health` OPA OK; PostgREST responds; Grafana reachable; NetworkPolicy blocks pod-to-DB from an unauthorized pod | Smoke checks in the playbook | T0.05 | Customer image policies (community images) → mirror to an internal registry |
| T0.07 | **AWS governance roles and demo resources.** CloudFormation stacks `aigov-governance-roles` and `aigov-demo-agents` (scoped and admin execution roles, approved policy and boundary, **four AgentCore runtimes created with the AgentCore managed harness** (Q-03), runtime tags), plus a demo-reset role. Verify IAM action names and condition keys against the Service Authorization Reference | P0 | Demo AWS account admin; Bedrock model access | amazon.aws.cloudformation, IAM | 3.5 | Stacks deploy and delete cleanly; discovery role cannot write (negative test); remediation role cannot modify untagged roles (negative test) | `SimulatePrincipalPolicy` tests | T0.01 | AgentCore runtime requires a container image (ECR) — see Q-03 |
| T0.08 | **AO config as code and workflow loader.** AAP integration, LLM integration (validate plus model discovery), AO credentials, service account `aigov-trigger`, SSRF allowlist (ao-backend and ao-worker), and the loader (`apply_workflows.yml`: render, validate, create/patch, publish) | P0 | AO admin | AO REST API, ansible.builtin.uri | 2.5 | A test workflow is applied from YAML and executes; the loader is idempotent (no new version when unchanged) | Loader run twice | T0.02, T0.05 | AO API differences across builds |

### Stage 1 — Discovery and governance

| ID | Description | Pri | Prereq | Technology | ED | Acceptance criteria | Testing | Deps | Risks |
|---|---|---|---|---|---|---|---|---|---|
| T1.01 | **Database schema V001 and migration runner** (tables, indexes, audit triggers, roles) | P0 | — | PostgreSQL 16, kubernetes.core | 3.0 | Migrations apply on CI and the cluster; SQL tests pass (immutability, unique open finding, grants) | SQL tests (09 §2.3) | T0.06 | — |
| T1.02 | **API layer**: `api` schema RPC functions and views (Stage 1 set), PostgREST role switching, JWT issuance playbook writing AAP credentials | P0 | — | PostgREST, SQL | 2.5 | Each RPC callable only by its role; `record_discovery` idempotent; OpenAPI exposed | SQL + HTTP tests in component CI | T1.01 | PostgREST decision (Q-05) |
| T1.03 | **Contracts**: JSON Schemas (discovery record, policy input, policy result, aggregate, AI explanation, artifacts) and fixtures for the four demo agents | P0 | — | JSON Schema | 1.0 | Fixtures validate; schemas versioned | `check-jsonschema` | T0.03 | — |
| T1.04 | **Custom read modules**: `bedrock_agent_details_info`, `iam_role_permissions_info`, `iam_policy_simulation_info` | P0 | — | Python, boto3, amazon.aws module_utils | 3.0 | Sanity and unit tests pass; AccessDenied maps to evidence status | pytest + Stubber; ansible-test sanity | T0.03, T0.04 | IAM statement normalization edge cases |
| T1.05 | **Bedrock Agents Classic discovery** adapter (`discover_aws_bedrock_agents`) for customer estates | P1 | — | amazon.ai, amazon.aws, project modules | 2.5 | Classic fixture agents normalized correctly from recorded API responses | Unit + component tests with stubbed AWS (the demo account cannot create Classic agents) | T1.06 | No live test target |
| T1.06 | **AgentCore runtime discovery** (orchestration role `discover_ai_agents`, adapter `discover_aws_agentcore`, `agentcore_runtime_info` module) and the Discover job template | **P0** | Demo runtimes deployed (T0.07) | boto3 bedrock-agentcore-control, amazon.aws, project modules | 2.5 | 4 demo runtimes discovered with correct fields and evidence; repeat run creates no new snapshots | Unit + environment integration (09 §3.2) | T1.02, T1.03, T1.04, T0.07 | Retire the module when `amazon.ai` ≥ 2.0.0 is certified on the hub |
| T1.07 | **Governance registry as code** (owners, registrations) and the Load Registry job template | P0 | — | YAML, RPC | 1.0 | Registry loads; agents re-matched; Git SHA recorded | Component test | T1.02 | — |
| T1.08 | **Rego framework**: lib, aggregator, risk, 10 policies, `data.json`, publish job (opa check/test in EE, ConfigMap update, revision stamping) | P0 | — | OPA 1.x, kubernetes.core | 4.0 | `POST /v1/data/governance/evaluate/result` returns the contract for all fixtures; the publish job refuses failing bundles | Rego tests (T1.09); publish negative test | T0.06, T1.03 | Rego complexity in IAM normalization (kept in Python) |
| T1.09 | **Rego unit tests and golden decisions** | P0 | — | opa test, Regal | 2.0 | Coverage ≥ 90%; golden outputs match | CI | T1.08 | — |
| T1.10 | **Evaluate job**: build inputs from `api.evaluation_inputs`, query OPA, persist results, finding lifecycle (open, refresh, auto-close; insufficient evidence), sanitized findings for AI | P0 | — | ansible.builtin.uri, RPC | 2.5 | DB state matches the expected outcome per fixture agent; `findings_for_explanation` excludes free-text fields | Component + environment integration | T1.06, T1.08, T1.07 | — |
| T1.11 | **WF-01** definition (as code), AI explanation node, Record Explanations and Summary jobs; loader validation and execution evidence | P0 | LLM integration healthy | AO, agentic | 3.0 | WF-01 valid and executes end to end; explanations stored; `VERIFIED.md` entry | Workflow validation (09 §4) | T0.08, T1.10 | Array or JSON passing between AO and AAP (handled by `from_json` fallback) |
| T1.12 | **Grafana Stage 1 dashboards**: inventory and findings, agent detail; reporting views V003 (subset) | P0 | — | Grafana provisioning, SQL views | 1.5 | Dashboards provisioned from Git and show the demo data | Visual check + SQL view tests | T1.10 | — |
| T1.13 | **Demo reset, Stage 1 E2E, rehearsal, README** | P0 | — | Ansible | 2.5 | A1-1 … A1-9 pass; three consecutive reset+run cycles are identical | E2E playbook | T1.11, T1.12 | Demo account drift (mitigated by reset) |

### Stage 2 — Closed-loop remediation

| ID | Description | Pri | Prereq | Technology | ED | Acceptance criteria | Testing | Deps | Risks |
|---|---|---|---|---|---|---|---|---|---|
| T2.01 | **Remediation catalog, authz and route Rego**, policy-action mapping, tests | P0 | — | OPA | 3.0 | All authz and route table rows tested; default profile is detection-only | Rego tests | T1.08 | — |
| T2.02 | **Stage 2 DB functions** and remediation state machine | P0 | — | SQL | 2.0 | Invalid transitions rejected; concurrency conflict; `close_finding` guard | SQL tests | T1.02 | — |
| T2.03 | **Get Finding Context and Reassess Agent** jobs | P0 | — | Ansible | 1.5 | Artifacts match the contract; stale finding gives `compliant` | Component + environment | T1.10, T2.02 | — |
| T2.04 | **Plan Remediation**: pre-state capture, check-mode diff, blast radius, AI validation, OPA route, approval summary | P0 | — | amazon.aws (check mode), OPA | 2.5 | Routes correct across scenarios; summary contains all required elements | Component + environment | T2.01, T2.03 | Check-mode diff fidelity of certified modules |
| T2.05 | **Execute Remediation: IAM actions** (replace managed policy, boundary, remove inline, tag role) | P0 | Remediation role deployed | amazon.aws.iam_role / iam_policy | 3.0 | Each action idempotent; attach-then-detach ordering; `post_state` stored | Environment integration; F-09 | T2.04, T0.07 | IAM eventual consistency |
| T2.06 | **Execute Remediation: Bedrock actions** (disable action group, pause alias, governance tags) + custom write modules | P1 | Classic agents | amazon.ai, project modules | 3.0 | Each action plus its rollback works on the demo agent | Unit + environment | T2.05 | DRAFT-only semantics of action group changes |
| T2.07 | **Verify Remediation**: independent re-collection, simulation retries, regression check, optional smoke invoke | P0 | — | project modules, amazon.ai.bedrock_invoke_agent | 2.5 | Verified only when all mandatory checks pass; F-10, F-11 behave as specified | Environment; F-10/F-11 | T2.05 | Simulation and SCP interactions |
| T2.08 | **Rollback** job and approval-gated rollback path | P0 | Demo-reset or break-glass credential decision (Q-11) | amazon.aws | 2.0 | Rollback restores pre-state for supported actions; non-reversible actions are refused | F-09 rollback | T2.05 | Remediation role deny-list blocks re-attaching admin (by design) |
| T2.09 | **WF-02 definition**, all branches, loader validation, execution evidence per branch | P0 | — | AO | 4.0 | A2-1 (all 9 branches have execution IDs); `VERIFIED.md` | Workflow validation | T2.03, T2.04, T2.05, T2.07, T2.08, T0.02 | OR-join or agentic-failure behaviors (fallbacks ready) |
| T2.10 | **Approval capture, Finalize Audit and Notify** (AO API reads, notification webhook, audit completeness check) | P0 | AO service account | AO REST API | 2.0 | Approval identity and notes in the audit trail; completeness check passes for the demo run | Environment | T2.09 | Execution-ID lookup approach (T0.02) |
| T2.11 | **AAP policy-as-code guard** on Execute and Rollback templates (feature flag) | P1 | AAP admin to enable the feature flag | AAP PaC, OPA | 2.0 | F-18 denied with a violation message | F-18 | T2.05 | Feature flag availability or support status in the customer's AAP 2.7 |
| T2.12 | **Failure injection suite (F-04…F-18), Stage 2 E2E, rehearsal** | P0 | — | Ansible | 3.5 | A2-1 … A2-7 pass | E2E + failure suite | T2.09, T2.10 | Time-dependent tests (approval expiry) |

### Stage 3 — Continuous governance

| ID | Description | Pri | Prereq | Technology | ED | Acceptance criteria | Testing | Deps | Risks |
|---|---|---|---|---|---|---|---|---|---|
| T3.01 | **AWS event plumbing** (CloudFormation: EventBridge rules in the agent Region and us-east-1, SQS, DLQ, EDA principal); capture real events and freeze patterns | P0 | CloudTrail enabled | amazon.aws.cloudformation | 2.0 | Real Bedrock or AgentCore and IAM events land in SQS; patterns documented with samples | Event capture test | T0.07 | Unverified `source` and `eventSource` values for Bedrock agents |
| T3.02 | **EDA rulebook, decision environment, activation config as code, Process Change Event** job | P0 | EDA admin | ansible.eda, infra.aap_configuration | 3.0 | Self-events suppressed; throttle works; irrelevant IAM events ignored with audit | F-13, F-20 | T3.01, T2.12 | `aws_sqs_queue` event structure |
| T3.03 | **WF-03** and Trigger Remediation Workflows job | P0 | — | AO | 2.0 | Change → WF-03 → WF-02 chain demonstrated | Workflow validation | T3.02, T2.09 | — |
| T3.04 | **Reconciliation and sweep**: schedules, drift diff, missing agents, stale remediation expiry, incremental chain verification | P0 | — | AAP schedules, SQL | 2.5 | Drift and missing events produced; stale items expired; chain verification job reports | Environment; F-19 | T1.13 | — |
| T3.05 | **Reporting views**, daily compliance snapshot, MTTD and MTTR | P0 | — | SQL | 2.0 | Views return correct figures on seeded history | SQL tests | T2.02 | — |
| T3.06 | **Grafana dashboards**: Executive, Operations, Agent Detail (full), Audit Explorer | P0 | — | Grafana | 3.5 | All required panels populated (A3-3) | Visual + SQL | T3.05 | — |
| T3.07 | **Usage and cost collection**: `cloudwatch_metric_data_info`, `cost_explorer_info`, daily job | P1 | Cost Explorer enabled; tags activated | boto3 | 3.0 | Usage rows for the demo agent; cost labelled actual or estimate | Unit + environment | T1.05 | Low or no usage in the demo account; CE data delay; AgentCore metric namespace to confirm |
| T3.08 | **Compliance control catalog, report generation, evidence bucket** | P0 | Evidence bucket decision (Q-14) | ansible.builtin.template, amazon.aws.s3_object | 3.0 | A3-4: Control Evidence Pack and Remediation Evidence Record generated; manifest verifies | Report snapshot tests | T3.05 | Mapping accuracy requires compliance review |
| T3.09 | **OpenTelemetry**: Collector deployment and pipeline spans (`otel_emit`) | P1 | Red Hat build of OTel available | OTel | 3.0 | One trace per governance run visible in Grafana | Environment | T2.09 | Receiver availability in the Red Hat build |
| T3.10 | **ROI model** inputs and panel | P1 | Customer baseline inputs | Grafana, SQL | 1.0 | ROI panel shows labelled estimates | Review | T3.06 | Credibility of estimates; keep assumptions visible |
| T3.11 | **Runbooks RB-01…RB-12** and enterprise architecture refresh | P0 | — | Docs | 2.0 | Each runbook dry-run by a second engineer | Peer walkthrough | T3.04 | — |
| T3.12 | **Stage 3 E2E** (latency trials, F-19, F-20) and rehearsal | P0 | — | Ansible | 2.5 | A3-1 … A3-6 pass | E2E | T3.03, T3.06, T3.08 | Event latency variance |
| T3.13 | **Microsoft Foundry adapter** (list agents; `:disable` remediation action) | P2 | Azure subscription | Azure REST, azure.azcollection where applicable | 5.0 | Foundry agents in inventory; policies evaluate | Unit + environment | T1.05 | API maturity |
| T3.14 | **Multi-account** (StackSets, organization-driven scopes, central event bus) | P2 | AWS Organizations admin | CloudFormation StackSets | 3.0 | Two accounts discovered and evented | Environment | T3.01 | Organizational change control |

## 4. Critical path

```
T0.01 (1) → T0.03 (2) → T0.04 (1.5) → T0.05 (2) → T0.06 (3) → T1.01 (3) → T1.02 (2.5) → T1.06 (2.5)
  → T1.10 (2.5) → T1.11 (3) → T1.13 (2.5)                                     [Stage 1 CP ≈ 26 ED]
  → T2.01 (3)* → T2.04 (2.5) → T2.05 (3) → T2.07 (2.5) → T2.09 (4) → T2.12 (3.5)   [Stage 2 CP ≈ 18.5 ED]
  → T3.02 (3)** → T3.03 (2) → T3.12 (2.5)                                      [Stage 3 CP ≈ 7.5 ED]
```

\* T2.01 can start in parallel once T1.08 is done; it is shown inline for simplicity.

\*\* T3.01 runs in parallel during Stage 2.

**Tasks that gate the design (start first):** T0.01 (Bedrock allowlist, LLM availability) and T0.02 (AO behaviors). Their findings can change Stage 1 and Stage 2 implementation details. They cannot change the architecture: fallbacks are pre-designed.

**Parallelization with two engineers:**

- **Engineer A (platform and data):** T0.03 → T0.04 → T0.05 → T0.06 → T1.01 → T1.02 → T1.07 → T1.12 …
- **Engineer B (cloud and policy):** T0.07 → T1.03 → T1.04 → T1.08 → T1.09 → T1.06 …
- They converge at T1.10 and T1.11.

## 5. Milestones

> **Progress (2026-11-19):** **M0 reached.** T0.01–T0.08 are done; see [environment-validation.md](environment-validation.md). Stage 1: T1.01 is done (V001 applied on the cluster); T1.02 is next. Open environment items: give `aigov-trigger` its AO project role (`configure_ao.yml`, run by the user), and set the AO SSRF allowlist (AO admin).

| Milestone | Contents | Measurable completion criteria |
|---|---|---|
| **M0 — Foundations ready** | T0.01–T0.08 | CI green; EE published; AAP configured from code; governance services healthy; AWS stacks deployed; AO behavior findings documented; test workflow applied by the loader |
| **M1 — Stage 1 POC (standalone demo)** | T1.01–T1.13 | Acceptance A1-1 … A1-9; 10-minute Stage 1 demo rehearsed twice |
| **M2 — Closed-loop remediation demo** | T2.01–T2.12 (P0) | Acceptance A2-1 … A2-7; 15–20 minute full demo rehearsed twice, including the approval persona |
| **M3 — Continuous governance** | T3.01–T3.12 (P0) | Acceptance A3-1 … A3-6; event-driven variant of the demo working |
| **M4 — Enhancements** | P1/P2 items | Per task acceptance |

## 6. MVP versus enhancements

| MVP (P0) | Enhancements (P1/P2) |
|---|---|
| Bedrock Agents Classic **or** AgentCore discovery (whichever the account supports) | Both platforms; Microsoft Foundry and Vertex adapters; multi-account |
| 10 governance policies, deterministic risk score | Customer-specific policy packs; EU AI Act-oriented controls |
| IAM remediation actions, verification, approval-gated rollback | Bedrock containment actions (alias pause, action group disable, tags); AAP policy-as-code guard |
| WF-01, WF-02, WF-03 | ServiceNow bi-directional integration |
| Grafana dashboards from PostgreSQL | OTel traces; ROI panel; usage and cost collection |
| Compliance evidence reports | S3 Object Lock evidence; signed reports |

## 7. Recommended implementation order (first ten tasks)

1. **T0.01** Environment validation (Bedrock allowlist, LLM, AO version)
2. **T0.02** AO reference capture and behavior spike
3. **T0.07** AWS governance roles and demo resources
4. **T0.03** Repository scaffold and CI
5. **T0.04** Execution and decision environments
6. **T0.05** AAP config as code baseline
7. **T0.08** AO config as code and workflow loader
8. **T0.06** Governance platform services
9. **T1.01** Database schema and migrations
10. **T1.03 / T1.04** Contracts and custom read modules (in parallel)
