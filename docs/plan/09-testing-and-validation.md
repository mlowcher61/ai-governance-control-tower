# 09 — Testing and Validation

This document covers unit tests, integration tests, workflow validation, failure scenarios, and acceptance criteria for all stages.

---

## 1. Test pyramid

| Level | Scope | Where it runs | Frequency |
|---|---|---|---|
| L1 Static | YAML, Ansible lint, Rego fmt/check/lint, Python lint, JSON Schema of fixtures | GitHub Actions | Every PR |
| L2 Unit | Rego policies; custom modules (botocore Stubber); filters; SQL functions on ephemeral PostgreSQL | GitHub Actions | Every PR |
| L3 Contract | Discovery record → policy input → OPA output golden files; AO rendered JSON structure; artifact schemas | GitHub Actions | Every PR |
| L4 Component integration | Real OPA plus PostgREST plus PostgreSQL in CI containers; playbooks run with `ansible-playbook` against them, with AWS stubbed via recorded fixtures | GitHub Actions (service containers) | Every PR (≤ 10 min) |
| L5 Environment integration | AAP jobs against the demo AWS account and the deployed governance services | AAP (manual or scheduled) | Before each demo or release |
| L6 Workflow | AO `/workflows/validate` plus scripted executions of WF-01, WF-02, and WF-03 | Target AO | Before each demo or release |
| L7 End to end and failure injection | Scenario playbooks with DB and AWS assertions | AAP | Release gate per stage |

## 2. Unit tests

### 2.1 Rego (target ≥ 90% line coverage; CI blocking)

| Suite | Cases |
|---|---|
| `lib_test.rego` | Effective environment (known, unknown with `assume_production`, unknown with `unknown`); evidence status defaults |
| Per policy (`*_test.rego`) | `pass`, `fail`, `unknown` (each non-collected evidence status), `not_applicable`; assumption propagation; boundary conditions (expiry exactly at `evaluated_at`); explanation content mentions the key evidence |
| `iam_001_test.rego` | Admin managed policy; `*:*` inline; `iam:*` on `*`; NotAction on `*`; Allow `*` with a resource restriction (pass); a boundary with simulation proving denial (pass); a boundary without simulation evidence (fail) |
| `data_001_test.rego` | Sensitive KB with and without approval; expired approval; unclassified source gives `unknown`; sensitive agent tag |
| `evaluate_test.rego` | Aggregate precedence (`error` > `noncompliant` > `unknown` > `compliant`); invalid schema version; summary counts |
| `risk_test.rego` | Each factor; cap at 100; category thresholds; unknown cap at 15 |
| `authz_test.rego` | Disabled gives `detect_only`; `mode=detect_only`; account not allowlisted gives `denied`; insufficient evidence gives `denied`; max attempts; cooldown; exempt; production gives approval; low-impact auto-eligible in non-prod gives `auto_remediation_permitted=yes`; platform filters actions; unknown policy gives `selected_action=none` and `denied` |
| `route_test.rego` | Each row of the route table (Stage 2 §7.2) |
| `default_profile_test.rego` | The committed default `data.json` has `remediation.enabled == false` and `mode == "detect_only"` |

### 2.2 Custom modules (pytest + `botocore.stub.Stubber`)

| Module | Cases |
|---|---|
| `bedrock_agent_details_info` | Pagination of KBs and data sources; AccessDenied on tags gives evidence `access_denied` with no exception; agent without guardrail; collaborators empty |
| `iam_role_permissions_info` | Managed policy default version retrieval; URL-encoded inline documents; string versus list `Action`/`Resource`; `NotAction`; `Condition` flag; boundary present or absent; role not found |
| `iam_policy_simulation_info` | Decisions mapped `allowed`/`implicitDeny`/`explicitDeny`; throttling retry |
| `bedrock_agent_alias_state` | Check mode reports a change without calling Update; idempotent when already in the desired state; required `agentAliasName` passthrough |
| `bedrock_agent_tags` | Add, update, and remove; `purge_tags: false` preserves others; check mode diff |
| `agentcore_runtime_info` | List and get; tags; model evidence `not_supported` |

### 2.3 SQL

- Migrations apply cleanly from empty, and re-running the runner is a no-op.
- `record_discovery` is idempotent: same hash means no new snapshot, and a changed hash means a new snapshot plus a drift event.
- `record_evaluation` opens, refreshes, and auto-closes findings correctly. An `unknown` result opens an `insufficient_evidence` finding.
- `begin_remediation` raises a conflict on a second active remediation for a finding.
- `close_finding` is refused without a verification evaluation with target `pass`.
- `audit_events`: UPDATE and DELETE are rejected, and chain verification detects a manual tamper performed with the superuser in the test.
- Role grants: `grafana_ro` cannot insert; `aigov_discovery` cannot call remediation functions.

## 3. Integration tests

### 3.1 Component (CI, no cloud)

`tests/component/` starts OPA, PostgreSQL, and PostgREST as service containers. It loads the policies and migrations, then runs:

1. Discovery normalization with recorded AWS responses (`tests/fixtures/aws/*.json`) injected via a `aigov_discovery_fixture_mode` variable that replaces module calls with fixture lookups. Fixture mode is **refused** when running inside AAP, which is detected through the `tower_job_id` / `awx_job_id` variables.
2. Evaluate, then assert the DB state for the four demo agents.
3. A remediation plan against fixtures, then assert the route for each scenario.

### 3.2 Environment (demo account)

Each test case below runs as an AAP job.

| Test | Assertion |
|---|---|
| Discovery of fixture agents | 4 agents; expected evidence statuses; no AccessDenied |
| Repeat discovery | No new snapshots; `last_seen_at` updated |
| Registry reload | `quick_helper_bot` stays unregistered; registering it changes REG-001 to `pass` on the next evaluation |
| IAM change detection (Stage 3) | Attach a test policy to the scoped role; within 5 minutes a `change_events` row exists and WF-03 runs |
| Remediation dry-run | `mode=dry_run` gives the `simulate` route; AWS is unchanged (verified by re-read) |

## 4. Workflow validation (AO)

| Step | Pass criterion |
|---|---|
| Reference capture (T0.02) | The target AO version, `openapi.json`, and one exported known-good workflow are stored in `ao_workflows/reference/` |
| Structural check | Rendered JSON matches the structural schema derived from the reference (top-level keys, node shape, edge shape, port names) |
| API validation | `POST /api/v1/workflows/validate` returns `is_valid: true`, `error_count: 0` |
| Create / patch / publish | Workflow is created or updated with `expected_version` and published |
| Expression smoke run | Each node can be executed with "Run step" or mock data (🟡 AO supports step testing). This is required because `/validate` does not catch boolean-literal and expression errors 🟡 |
| Full execution | WF-01, WF-02 (each branch), and WF-03 executions reach their expected terminal node (asserted via `GET /executions/{id}` and `/activities`) |
| Importability statement | Only after all the above pass on the target version; recorded in `ao_workflows/reference/VERIFIED.md` with the version, date, and execution IDs |

## 5. Failure scenarios (failure injection catalog)

Each scenario has a playbook in `tests/failure_injection/` that sets up the condition, triggers the workflow, and asserts the outcome and audit events.

| ID | Scenario | Injection | Expected behavior |
|---|---|---|---|
| F-01 | Discovery AccessDenied on tags | Temporarily remove `bedrock:ListTagsForResource` from the discovery role | Evidence `tags=access_denied`; TAG-001 `unknown`; agent `unknown` (not compliant); run `partial` |
| F-02 | OPA down | Scale OPA to 0 | Evaluate job marks results `error`; no findings auto-closed; WF-02 `activity_authz` fails, so there is no remediation and the sweep flags the run |
| F-03 | OPA undefined path | Publish a bundle missing `governance.evaluate` | Callers detect no `result`, so `error`; the publish job should have failed first (test asserts that the publish job blocks it) |
| F-04 | AI step failure | Invalid LLM credential | WF-01: deterministic explanations remain; WF-02: if AO continues, `ai_agrees=unknown` forces approval; if AO aborts, the run is flagged by the sweep (behavior documented after T2.09) |
| F-05 | AI disagrees or returns an invalid action | Prompt fixture or mocked LLM returning `recommended_action: delete_agent` | Validation rejects it; `ai_recommendation_accepted=false`; route `approval`; approval summary shows the disagreement |
| F-06 | Prompt injection in agent instruction | Demo agent with a malicious `instruction` | Instruction text is absent from the AI prompt (asserted from stored prompt inputs); decisions unchanged |
| F-07 | Approval rejected | Approver rejects | Finding open; cooldown set; `approval.decided` with notes; owner notified |
| F-08 | Approval expired | No decision (shortened timeout in the test environment if configurable; otherwise a manual cancel test) | Treated as rejected |
| F-09 | Remediation failure (partial) | Deny `iam:DetachRolePolicy` mid-run | Attach succeeded, detach failed; `status=failed`; `post_state` recorded; rollback offered through approval |
| F-10 | Verification failure | Inject a second admin inline policy between execute and verify | IAM-001 still `fail`; `verification_failed`; finding not resolved; escalation |
| F-11 | IAM propagation delay | (natural) | Simulation retries; verification passes within the retry window |
| F-12 | Concurrent remediation | Start WF-02 twice for the same finding | Second `begin_remediation` gets a conflict; second run records `skipped` |
| F-13 | Remediation loop | Remediation emits IAM events | EDA suppresses events from `AIGovRemediationRole`; no second WF-02 |
| F-14 | Max attempts / cooldown | Three failed attempts | Authz returns `denied` with the reason |
| F-15 | Account not allowlisted | Agent in a second account | `denied`; detection continues |
| F-16 | Detection-only default | Fresh install profile | WF-02 ends in `detect_only` |
| F-17 | Stale finding | Owner fixes the issue before WF-02 starts | Reassess gives `compliant` and the finding is resolved `no_longer_detected` without remediation |
| F-18 | Direct template launch bypass | An operator launches Execute Remediation directly | AAP RBAC denies; with the PaC guard, launch is denied with a violation message |
| F-19 | Audit tamper | Superuser updates an audit row | Chain verification gives `audit.chain_broken` and an alert |
| F-20 | EDA activation down | Stop the activation; generate events | Events wait in SQS; after restart they are processed; nightly reconciliation catches anything older than retention |

## 6. Acceptance criteria

### 6.1 Stage 1 (POC acceptance)

| # | Criterion | Measure |
|---|---|---|
| A1-1 | An authorized agent is discovered and inventoried | E2E assertion: `payments_dispute_assistant` is `registered` and `compliant` |
| A1-2 | An unauthorized agent is identified | `quick_helper_bot`: `unregistered`, `noncompliant`, `critical`, REG-001 and IAM-001 open |
| A1-3 | OPA evaluates ≥ 5 policies | 10 policies evaluated per agent; Rego coverage ≥ 90% |
| A1-4 | AO retrieves and interprets policy results | WF-01 condition branches on `explain_count`; AI step executes |
| A1-5 | Findings persisted | Rows in `policy_evaluations`, `policy_results`, and `findings` correlated by `governance_run_id` |
| A1-6 | Clear explanation per finding | Grafana shows the deterministic explanation for 100% of findings and the AI explanation for ≥ 90% of explained findings |
| A1-7 | Unknown handling | `research_runtime` shows `unknown` (not compliant), with the reason visible |
| A1-8 | Repeatability | Reset plus WF-01 three times in a row gives identical end state |
| A1-9 | WF-01 importability evidence | `VERIFIED.md` entry for WF-01 |

### 6.2 Stage 2

| # | Criterion | Measure |
|---|---|---|
| A2-1 | All 9 required branches exercised | Execution IDs recorded for compliant, noncompliant, missing evidence, auto, approval, rejected, remediation failed, verification failed, and success |
| A2-2 | Demo scenario end to end | `quick_helper_bot` admin policy replaced; verification passes; finding resolved |
| A2-3 | Safety | F-04 through F-18 pass |
| A2-4 | Audit completeness | The audit timeline for the demo run contains every mandatory event; the hash chain verifies |
| A2-5 | Timing | Demo run (excluding human approval time) completes in ≤ 6 minutes |
| A2-6 | Rollback | F-09 rollback path restores the pre-state, verified by re-read |
| A2-7 | WF-02 importability evidence | `VERIFIED.md` entry |

### 6.3 Stage 3

| # | Criterion | Measure |
|---|---|---|
| A3-1 | Change detection latency | A demo IAM change is reflected as a finding in ≤ 5 minutes (P95 over 10 trials) |
| A3-2 | Reconciliation | Nightly run completes; drift and missing detection demonstrated |
| A3-3 | Dashboards | All required panels populated with demo data; MTTD and MTTR computed |
| A3-4 | Reporting | Control Evidence Pack generated with all controls and the disclaimer; manifest hashes verify |
| A3-5 | Usage and cost | Usage metrics collected for the demo agent; estimates clearly labelled |
| A3-6 | Event pipeline resilience | F-20 passes |

## 7. Demo readiness checklist (run before every customer demo)

1. Run **AI Governance - Reset Demo Environment**, then check that the Stage 1 E2E assertions pass.
2. Confirm the published policy bundle revision equals the expected Git tag.
3. Confirm the AO workflows are published at the expected versions and the LLM integration is healthy (integration validate).
4. Confirm approvers can log in to AO and see the Approvals page.
5. Confirm Grafana dashboards load with the expected baseline (4 agents).
6. Confirm the EDA activation is running and the SQS DLQ is empty (Stage 3).
7. Prepare a fallback recording of a successful run in case of an environment outage.

## 8. AI explanation quality checks

These checks are non-blocking and are recorded per release.

- A rubric review of 10 sampled explanations: accurate (matches the deterministic finding), understandable to a non-expert, no invented facts, stays within allowed next steps.
- A regression set of fixed finding inputs, with outputs compared manually when the model or prompt changes.
