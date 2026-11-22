# Progress log

What was built, what it proved, what went wrong and how it was fixed, and what was decided, task by task.
The README's *Implementation status* table has the one-line summary; this log has the detail. Environment
facts are in [plan/environment-validation.md](plan/environment-validation.md), verified automation orchestrator
executions in [../ao_workflows/reference/VERIFIED.md](../ao_workflows/reference/VERIFIED.md), and decisions in
[plan/13-open-questions.md](plan/13-open-questions.md).

**Stage 1 is complete (2026-11-20).** Stage 0 and T1.01 were built on cluster **t5d26** (2026-11-17 to 2026-11-19); see environment-validation.md
sections 1-7. Everything below runs on cluster **mk6hb**.

---

## 2026-11-19 - Move to cluster mk6hb, rebuilt from config as code only

**What happened.** Work moved to mk6hb (AAP controller 4.8.13; AO API 1.3.2; a separate, empty AWS sandbox,
account 505889097019). The environment was rebuilt with the repository's config as code only, which also tested
the new-user steps.

**Results.** Check Environment (job 40) found the AWS account; governance roles (43) and demo agents (44)
deployed; Verify AWS Baseline (46) passed with all four AgentCore runtimes `READY`; Deploy Platform Services (48)
passed every acceptance check; V001 applied (49) and the re-run changed nothing (51).

**Problems found and fixed.**
- `~/.ansible/collections` on the workstation contains ansible-lint *mock* modules (empty stubs) for
  `ansible.controller`, `kubernetes.core` and others, so config as code failed. Real collections were installed into
  the repository's git-ignored `./collections`, which `ansible.cfg` searches first. The home directory was not
  changed; reinstall those collections there if other projects need them.
- `customer.example.yml` now starts with the prebuilt public EE (`quay.io/locust61/ai-governance-ee:0.1.0`), which
  is what made a fresh cluster work immediately.

## 2026-11-19 - T1.02 Inventory API layer

**Built.** Migration V002: the Stage 1 `api` functions (discovery runs and records, registry load, evaluation
inputs and results, the finding lifecycle, AI explanations, audit append), read-only views, and one PostgreSQL
role per caller. The `jwt_hs256` module and **AI Governance - Issue API Tokens** sign one token per role and store
it in the AAP credential *AI Governance - Inventory API (role)*. SQL tests cover the whole privilege matrix and
every function; HTTP tests run through a real PostgREST (CI and `database/tests/run_local.sh`).

**Results.** V002 applied (job 55); tokens issued and checked (job 56: every token runs as its own role, 15/15
read-only HTTP checks, no token in the job output).

**Problems found and fixed.**
- Functions called inside a view run with the *caller's* privileges: the evaluator needed the two date helpers.
- **Config as code wiped the issued tokens on every run.** The credential module treats a different set of input
  keys as a change; the credentials did not send `token`, so each run patched it away. They now send an empty
  `token` key, and a re-run keeps all six tokens.

## 2026-11-19 - automation orchestrator on mk6hb

**Results.** After the AO service account `claude-work-access` was made project-admin in `default` (a fresh token
was needed after the grant), `configure_ao.yml` created `aigov-trigger` (`project-user`) and stored its client
credential in AAP; **Apply AO Workflows** (job 62, as `aigov-trigger`) published the test workflows; the loader test
and LLM smoke test executions completed.

**SSRF allowlist.** The AO UI could only grant project roles, so no AO identity could change AO settings. New job
template **AI Governance - Configure AO Network Allowlist** sets `APP_INTEGRATION_URL_ALLOWED_HOSTS` in the
`ao-admin-settings` ConfigMap that every AO deployment loads (the same approach as sales.demos). It **merges**: the
existing value also held `maas-rhdp.apps.maas.redhatworkshops.io`, which the LiteMaaS integration needs.
First run restarted AO (job 71); re-runs (87, 89) change nothing; the value is checked inside a running ao-worker pod.

**Problems found and fixed.** The execution environment runs ansible-core 2.16: it parsed the stored JSON value into
a list, `union` reordered hosts on every run (so AO restarted every time), and a templated `"[...]"` string turns back
into a list. The job now sorts, compares sets, decides the restart in its own step, and writes one key as a merge patch.

**Watch out.** sales.demos' "AAP Ecosystem - Configure Automation Orchestrator" writes the same ConfigMap with only
the AAP host. Re-run Configure AO Network Allowlist after it.

## 2026-11-19 - T1.03 Contracts

**Built.** Nine versioned JSON Schemas in `schemas/` (discovery record, registry, policy input, policy result,
evaluation result, findings for explanation, AI explanation, job artifacts, shared definitions), with the key rules
written into the schemas: explicit evidence status, no silent compliance, risk category bands, remediation only on
fail, AI output cannot carry decisions, AI input excludes owner-controlled text. Fixtures for the four demo agents
in `policies/fixtures/`. A database test proves the Inventory API turns the discovery fixtures into exactly the
policy-input fixtures.

**Decision.** Risk bands: medium starts at 21 (low is 20 or less), so the payments agent (score 20) is low, as the
plan's demo table intended.

## 2026-11-19 - T1.04 Custom read modules

**Built.** `iam_role_permissions_info` (trust policy, tags, managed and inline policy documents, permissions
boundary, in the contract identity shape), `bedrock_agent_details_info` (Bedrock Agents Classic: tags, guardrail,
KMS key, knowledge bases and S3 data sources with bucket classification, collaborators; never returns the agent
instruction), and an evidence mode plus the contract simulation map for `iam_policy_simulation_info`. AccessDenied
always becomes the evidence status `access_denied`, never "nothing found". 37 unit tests with the botocore Stubber;
the full `ansible-test sanity` suite is clean and runs in CI.

**Results.** Verify AWS Baseline (job 94) reads the four demo execution roles through the discovery role:
AdministratorAccess, and allowed administrator actions, only on `quick_helper_bot`.

**Problems found and fixed.** Sanity found invalid YAML in the T1.02 `jwt_hs256` documentation.

**Limitation.** AWS put Bedrock Agents into maintenance mode on 2026-07-30 ("Bedrock Agents Classic"): `CreateAgent`
is refused for accounts with no Bedrock Agents activity in the past 12 months, which includes these accounts (never
used; inferred from the documented rule, not called). The Classic module is therefore tested with stubbed responses only.

## 2026-11-19 - T1.06 AgentCore discovery

**Built.** `agentcore_runtime_info` (never returns runtime environment variables), the `agentcore_discovery_record`
filter (unit tests rebuild the four demo fixtures exactly), roles `discover_ai_agents`, `discover_aws_agentcore` and
`inventory_api` (API calls that never print the token), self-contained schema copies in `schemas/bundled/` for
`ansible.utils.validate`, and job templates **Discover AI Agents** and **Check Inventory**.

**Results.** Discovery (job 98) recorded the four agents; the repeat (99) found all four unchanged (no new history);
Check Inventory (103) confirmed evidence collected, valid policy inputs, and AdministratorAccess only on
`quick_helper_bot`.

**Decision.** ansible-lint's `var-naming[no-role-prefix]` is skipped: the project deliberately shares `aigov_`
variables across roles and credentials (reason recorded in `.ansible-lint`).

## 2026-11-19 - T1.07 Governance registry as code

**Built.** `inventory/registry/owners.yml` and `registrations.yml` (the demo scenario; `quick_helper_bot`
deliberately unregistered; matching includes the account ID) and **Load Governance Registry**, which validates the
files, records the Git commit, and re-matches every agent. Contract tests keep the files valid and in step with the
fixture registry.

**Results.** Job 106 registered three agents; job 108 recorded commit `9ae5d1c` and re-matched none (stable); a
later discovery (111) kept the registrations; Check Inventory (110, 113) confirmed them.

**Problem found and fixed.** An AAP job's project copy has no `.git`; AAP passes the synced commit in the
`PROJECT_REVISION` environment variable, which the job now uses.

## 2026-11-19 - T1.08 Governance policies (OPA / Rego)

**Decision: Rego library.** The suggested library
[ynotbhatc/rego_policy_libraries](https://github.com/ynotbhatc/rego_policy_libraries) (Apache-2.0; its tests pass on
OPA 1.22.4) evaluates organization-level attestations (ISO 42001, EU AI Act, NIST AI RMF) and AI actions, not
individual cloud agents, and uses a different input/output format. Chosen approach (hybrid): our own library and 10
per-agent policies in our contract; each result cites the library's control IDs, pinned to commit `9d26ac4`
(for example AIGOV-IAM-001 automates CIS AWS v7 7.1.3, which CIS lists as a manual check). A Stage 3 roll-up that
feeds our findings into the library's framework modules is planned.

**Built.** `policies/governance` (library, 10 policies, risk score, entry point), settings in `data.json`, 55 unit
tests (99.2% coverage), golden decisions for the four demo agents (contract-checked in CI), and **Publish Governance
Policies**: tests the bundle in a Kubernetes Job with the server's own OPA image and refuses failures, replaces the
policies and restarts OPA only on change, verifies the golden decisions on the live server, and rolls back on a
mismatch. The plan's §7 sketches were corrected where testing showed wrong results (AgentCore data sensitivity from
the tag or registry, approvals by date, IAM-002 wildcard matching, remediation only on fail, explicit nulls).

**Results.** Job 141 published and verified; job 143 (negative self-test) was refused (`FAIL: 1/56`) without touching
the live policies; job 145 needed no restart.

**Problems found and fixed.** OPA loaded every file twice from the ConfigMap's hidden `..data` folders (fixed with
`--ignore=.*` on the server and the check Job); ConfigMap keys broke on ansible-core 2.16 regex backreferences; a
finished check Job was reused for different content, so the first self-test passed (the Job name is now a hash of the
exact content).

**Not done.** The Regal linter: downloading and running it was blocked by the permission checker. Correctness is
covered by `opa check --strict`, the tests and the golden decisions.

## 2026-11-20 - T1.10 Evaluate job

**Built.** Migration V003 `api.findings_for_explanation` (what the AI may see: structured fields, owner-controlled
values masked, safe characters only, length limits, next steps from the policy's remediation text; evaluator only)
and **Evaluate Governance Policies** (policy inputs, OPA, contract check, record the result, sanitized findings,
artifacts). The CI database test now runs the whole chain from fixtures to AI-safe findings. Check Inventory also
checks compliance, risk and the exact open findings per agent.

**Results.** Job 154: 1 compliant, 2 noncompliant, 1 unknown, 9 findings for the AI; the repeat (156) opened no
duplicates; Check Inventory (157) confirmed everything.

**Not shown live yet.** Automatic closing of a finding once fixed (covered by SQL tests); planned for T1.13.

## 2026-11-20 - T1.11 WF-01 Governance Assessment

**Built.** WF-01 (Discover, Evaluate, condition, AI explanation, Record, Summary; each branch ends in its own summary
node because AO's join behavior is unproven), **Record AI Explanations**, **Publish Assessment Summary**, and
migration V004 `api.complete_governance_run`.

**Results.** Execution `98433f4f` recorded 9 of 9 AI explanations; execution `c559f2d6` took the nothing-to-explain
branch (see VERIFIED.md). Confirmed on this AO build: condition ports are `true`/`false`; numbers compare; an array
from the AI step reaches the AAP job as a JSON list.

**Problems found and fixed.**
- **Config as code wiped the AO trigger credential** (same class as the tokens: an empty `client_id` counted as a
  change). Config as code now only creates that credential (`state: exists`).
- `configure_ao.yml` could not recover: it now re-issues the credential when AAP no longer holds a working one and
  disables the orphaned one (`nx_sa_13274b...`).
- The local podman VM clock drifted 19 minutes after sleep, which broke the local token tests (environment only):
  `podman machine ssh "sudo date -u -s @$(date -u +%s)"`.

## 2026-11-20 - T1.12 Grafana dashboards

**Built.** Migration V005: 11 reporting views (the only thing the dashboards query, as `grafana_ro`). Dashboards
**AI Governance - Inventory and Findings** and **AI Governance - Agent Detail** in `dashboards/json/`, published by
Deploy Platform Services, which restarts Grafana only on change and checks the dashboards live. CI runs every panel
query as `grafana_ro` on the demo data.

**Results.** Job 182: both dashboards loaded once each; 24 panel queries ran through Grafana.

**Open.** A visual review of the layout for customer demos (the automated checks prove the queries and data).
The README's getting-started steps now run the AO allowlist right after configuring AO.

## 2026-11-20 - T1.13 Demo reset, Stage 1 end-to-end test, rehearsal

**Built.**
- Migration V006: `api.reset_demo`, which works on demo-tagged agents only. It resolves their open findings as
  `demo_reset`, marks them not evaluated, deletes nothing, and writes a `demo.reset` audit event. Only the remediator
  role may call it. It also adds the views `api.agent_assessment` and `api.governance_runs` for the acceptance checks.
- Modules `iam_role_managed_policies` and `agentcore_runtime_tags`. The certified `amazon.aws.iam_role` module also
  manages instance profiles and role paths, which needs permissions the least-privilege `AIGovDemoResetRole` rightly lacks.
- `playbooks/demo/vars/demo_baseline.yml`, contract-tested against the demo CloudFormation and the deploy playbook's
  stack tags. Job template **Reset Demo Agents** and the AAP workflow **Reset Demo Environment**
  (Reset Demo Agents → Load Governance Registry → Publish Governance Policies).
- **Stage 1 End-to-End Test**: three cycles of reset + WF-01, checking acceptance A1-1 to A1-7 per cycle, then A1-8
  (identical end state) and A1-9 (VERIFIED.md). The AO run steps are shared with `run_workflow.yml`
  (`ao_workflows/tasks/run_one.yml`).
- The demo script (docs/plan/11) and README use the real workflow, dashboard and Rego file names, and the README has a
  *Running the Stage 1 demo* section.

**Results.** Reset Demo Environment ran and was idempotent (workflow jobs 201, then 206 with no changes). **Job 224:
Stage 1 acceptance A1-1 to A1-9 passed in 3 consecutive cycles with an identical end state:**

| Agent | Registration | Status | Risk | Open findings |
|---|---|---|---|---|
| payments_dispute_assistant | registered | compliant | low (20) | none |
| quick_helper_bot | unregistered | noncompliant | critical (100) | DATA-001, IAM-001, MDL-001, OWN-001, REG-001, RSK-001, TAG-001 |
| hr_faq_agent | registered | noncompliant | low (10) | RSK-001 |
| research_runtime | registered | unknown | low (5) | MDL-001 |

**Problems found and fixed.**
- **A YAML `true` became the tag value `"True"`.** That would silently break the IAM conditions, which compare against
  `"true"`. Tag values are now normalized (caught by a unit test).
- **AWS refuses to remove `aws:` system tags.** CloudFormation adds `aws:cloudformation:*` tags to every runtime. The module
  now never touches `aws:` tags (found on the first live run).
- **The first reset removed the stack tags `aigov:component` and `aigov:managed-by`.** CloudFormation propagates them from the
  stack, not from the template, and the baseline missed them. They are now part of the baseline, contract-tested, and restored.
- **The first end-to-end run (job 211) failed at its own acceptance check.** Counts are strings on ansible-core 2.16 (the EE),
  and my local simulation used 2.21. The checks now convert counts to numbers, and the simulation is run on ansible-core 2.16 too.

## 2026-11-20 - Stage 2 begins: T2.01 Remediation catalog, authorization and route policies

**Built.**
- `policies/data/governance/remediation_catalog`: every remediation the solution can perform, with impact,
  reversibility, platforms and automatic eligibility. It adds `agentcore_apply_governance_tags`, because the demo agents are
  AgentCore runtimes and the T1.13 `agentcore_runtime_tags` module can implement it.
- `policies/data/governance/policy_actions`: policy → actions. This is now the **single source** for the `action_types`
  in each failing result (they were listed per policy, and some named actions that did not exist).
- `governance.remediation.authz`: eligibility (enabled, account allowlist, violation only, attempts, cooldown, exempt),
  action choice (narrowed by `applicable_actions` that the Plan job derives from the real pre-state), and approval reasons.
- `governance.remediation.route`: halt, simulate, approval or auto. Anything uncertain forces approval.
- **The committed default stays detection-only** (`enabled: false`, `mode: detect_only`, enforced by a test). The demo
  profile (`policies/overlays/demo/remediation.json`) is applied only by **Publish Governance Policies** with
  `aigov_policy_profile: demo`, and allows only `aigov_aws_account_id`. The platform info reports the active
  remediation mode, and the publish job checks it on the live server.

**Tests.** 29 new Rego tests (84 total, 99.4% coverage): every denial and approval reason, every route row, catalog
consistency. They were mutation-checked: enabling remediation in the default, or naming an unknown action, makes the tests fail.

**Results.** Publish Governance Policies (job 259): 84/84 tests in the server's OPA image; golden decisions 4/4 on the
live server; remediation disabled (detect_only).

**Decisions (plan refinements).**
- Approval is required for every environment except development and sandbox. That includes unknown environments,
  fail-closed (the plan said production only).
- Approval is also required when the catalog marks an action as not automatically eligible (in addition to the
  configured automatic list).

**Problems found and fixed.** On ansible-core 2.16 (the EE), `fileglob` returns nothing for a wildcard directory
(`*/data.json`); the publish job uses `find`. Found by simulating on 2.16 before deploying, as T1.13 taught.

## 2026-11-20 - T2.02 Remediation lifecycle in the database

**Built.** Migration V007: `api.get_finding_context`, `begin_remediation`, `update_remediation`, `record_approval`,
`close_finding` and `record_outcome` (remediator role only), the view `api.remediations`, an approval `kind`
(remediation or rollback), and an explicit table of allowed status transitions. The finding's status follows its remediation
(planned → awaiting approval → remediating → verifying → resolved, or back to open).

**Safety rules enforced by the database itself, whatever a job sends** (beyond the plan's function list):
- only the action OPA selected, only for an eligible violation (never for insufficient evidence), only on an open finding;
- straight from `planned` to `approved` only when OPA permitted automatic remediation; otherwise only `record_approval`
  approves, rejects or expires it, and approvals and rejections need a named approver;
- a dry run never reaches `executing`;
- `rolled_back` only after an approved **rollback** approval (plan §9.2: rollback is never automatic);
- `close_finding` needs a verified remediation and a *verification* evaluation in which the finding's policy passed;
- one active remediation per finding: a second attempt is a conflict (HTTP 409);
- rejected, failed and rolled-back outcomes start the cooldown that OPA checks;
- every step writes an audit event (`remediation.planned`, `approval.requested`, `approval.decided` as the human
  approver, `remediation.executed`, `verification.passed`, `finding.resolved`, `rollback.executed`, ...).

**Tests.** `database/tests/test_v007_remediation.sql` follows the approval path end to end, then the automatic path, a dry run,
a failure with rollback, cooldown, rejection and the concurrency conflict. It was mutation-checked: removing the
approval-bypass guard or the selected-action guard makes the matching test fail.

**Results.** V007 applied on mk6hb (job 261). CI green.

## 2026-11-20 - T2.03 Get Finding Context and Reassess Agent

**Built.**
- **AI Governance - Get Finding Context** (remediator credential): reads `api.get_finding_context` and publishes the
  finding, agent, environment, attempts, cooldown and exempt status, with a new remediation run ID. An unknown finding
  does not fail the job: it reports `finding_status: not_found`, so WF-02 can branch on it.
- **AI Governance - Reassess Agent** (discovery AWS role + evaluator credential): re-collects one agent from AWS (the
  AgentCore adapter, filtered to that runtime), then rebuilds its policy input with the live state (new filter
  `policy_input_refresh`; registration and IDs from the inventory). It asks OPA and records the evaluation with purpose
  `pre_remediation`, which never changes findings. The finding's policy gives the assessment: `compliant` (the finding is
  stale), `noncompliant`, `missing_evidence` or `error` (filter `reassessment_outcome`). Errors are reported as
  `assessment: error`, never as a failed job.
- The decision does not depend on the last discovery run, and the job cannot rewrite the inventory. Verify Remediation
  (T2.07) will reuse it.
- Contracts: `artifacts.v1` gains `finding_context` and `reassess`. The `inventory_api` wrapper can accept expected
  error responses.

**Tests.** The refresh filter rebuilds all four stored policy inputs exactly from their discovery records; the outcome
filter is tested for every decision, including a stale finding (live pass gives `compliant`). Get Finding Context
artifacts were simulated on ansible-core 2.16 for both the found and the not-found case.

**Results on mk6hb.** Get Finding Context: `quick_helper_bot` IAM-001 (job 266, full context), unknown finding (268,
`not_found`). Reassess: IAM-001 `noncompliant` critical (274), MDL-001 `missing_evidence` (275), HR RSK-001
`noncompliant` (277), unknown finding `error` with the reason (278). Check Inventory (279): findings unchanged.

**Not shown live.** A stale finding (`compliant`) needs AWS or the registry to change after an assessment. It is covered by
unit tests and will be shown live in T2.07: after a remediation, the reassessment of the fixed finding must be compliant.

---

## 2026-11-20 - T2.04 Plan Remediation

**Built.**
- **AI Governance - Plan Remediation** (`playbooks/remediation/plan.yml`; AWS bootstrap + discovery role + Inventory API
  remediator credentials). For one open violation it:
  1. reads the finding context and captures the **pre-state** read-only (execution role policies, boundary, trust policy,
     tags; runtime tags);
  2. works out the actions that fit the pre-state (filter `remediation_applicable_actions`) and asks OPA
     `governance.remediation.authz`;
  3. **dry-runs** the selected action with the real modules in check mode (managed policies, boundary, runtime tags);
  4. checks the AI recommendation against `schemas/ai-recommendation.v1.json` (`remediation_ai_check`). It is advisory only:
     output that fails its contract is neither shown to the approver nor stored;
  5. computes the **blast radius** (`remediation_blast_radius`): other agents on the same role, or a trust policy that
     admits other principals, gives `yes`; incomplete evidence gives `unknown`;
  6. asks OPA `governance.remediation.route` for `auto`, `approval`, `simulate` or `halt`;
  7. records the remediation (`begin_remediation`, always with OPA's action) and moves it to `awaiting_approval`,
     `approved` or `skipped` (simulate); writes a Markdown **approval summary** (finding, planned change, blast radius,
     rollback, OPA reasons and bundle, AI advisory, owner and separation of duties).
  Any problem gives `route: halt` with the reason; nothing is changed in AWS.
- **V008**: `get_finding_context` adds `agents_sharing_role`, tags and the registry facts (owner, environment, data
  classification).
- New filter `remediation_governance_tags`: registry values when the agent is registered, quarantine tags otherwise;
  owners are never invented.
- Contracts: `ai-recommendation.v1.json` and `artifacts.v1.json#/$defs/plan`, with examples.

**Problem found and fixed.** The demo profile could never be published: the overlay was included in the data of the
policy check Job, so the test "the committed default is detect_only" refused the bundle (job 286; the live policies
were not touched). The check Job now always tests the committed settings. The profile changes only the serving bundle,
whose remediation settings are checked on the live server (commit b7257f4).

**ansible-core 2.16 findings** (simulated before deploying): a `set_fact` of the string `yes` becomes boolean `true`, so
yes/no values are kept as booleans and converted where used. `omit` inside a nested dict is not removed, so request
bodies are built with `combine`. The template lookup trims newlines after block tags, so the summary template keeps
each tag on its own line.

**Tests.** Unit tests for the four filters (76 in total), V008 SQL tests, schema examples (128), and the plan Jinja on
ansible-core 2.16 with the AI recommendation as an object, as JSON text, invalid, and empty.

**Results on mk6hb.** V008 applied (job 282). Default settings: route `halt`, with every OPA reason (job 285). Demo
profile published (job 288). `quick_helper_bot` IAM-001 (job 291): route `approval`, remediation
`320f53ea-43db-4feb-9ede-155870a7fa14` awaiting approval. Planned change: attach `aigov-approved-agentcore-runtime-basic`,
detach `AdministratorAccess`. Blast radius `no`, rollback `yes`, AI agrees. Finding status `awaiting_approval` (job 293).
A second plan halts (job 294). Reassess still finds the role noncompliant, so the dry run changed nothing in AWS (job 295).

**Not shown live.** The `auto` and `simulate` routes and an invalid AI recommendation (covered by unit tests, the
simulation and the OPA route tests). The OPA decision ID is empty because OPA decision logging is not enabled; the
bundle revision identifies the policy version.

**Left in place for T2.05.** The demo profile stays published on mk6hb, and remediation `320f53ea…` awaits approval.
Republish with the default profile to turn remediation off.

---

## 2026-11-22 - T2.05 Execute Remediation (IAM actions)

**Built.**
- **AI Governance - Execute Remediation** (`playbooks/remediation/execute.yml`; AWS bootstrap + **remediation role** +
  Inventory API remediator). It acts only on the recorded remediation (`api.get_remediation`); the action, target and
  pre-state come from the database. The job template takes only the two IDs (survey) and runs one at a time.
  1. Preconditions. Any failure gives `status: refused`, changes nothing, and marks an approved remediation `skipped`:
     - the remediation is `approved`, in `enforce` mode, and belongs to the run;
     - the action is implemented;
     - the execution role did not change since the pre-state (filter `remediation_state_drift`: managed policies, boundary,
       inline policies);
     - OPA authorizes the same action again now (approval is not authorization by itself).
  2. Executes with `AIGovRemediationRole`. The session name contains the governance run ID (CloudTrail correlation).
  3. Re-reads the role and stores `succeeded` or `failed` with the post-state.
- Role `remediate_ai_agent`, one task file per action:
  - `iam_replace_managed_policy`: attach the approved policy, then detach admin policies (`remediation_policy_sets`);
  - `iam_apply_permissions_boundary`;
  - `iam_remove_inline_policy`: certified `amazon.aws.iam_policy`;
  - `agentcore_apply_governance_tags`.
- **V009**: `api.get_remediation`. `record_approval` refuses an approval by the agent's registered owner (by owner ID,
  e-mail or name), which is separation of duties enforced in the database.
- **AI Governance - Record Approval Decision** (interim): records a named approver's decision. Only AAP administrators can
  launch it. T2.10 replaces the typed approver with the decision read from the AO approvals API.
- Contracts: `artifacts.v1.json#/$defs/execute` and `approval_decision`.

**Decisions.**
- Managed policies and boundary use the project module `iam_role_managed_policies`, not certified `amazon.aws.iam_role`.
  `iam_role` requires the trust policy on every call and would rewrite it if it differed, and the remediation role is
  deliberately not allowed to change trust policies.
- `iam_tag_role` is in the catalog but no policy maps to it, so OPA never selects it; it is not implemented (refused if
  ever selected).
- Bedrock Agents Classic actions follow in T2.06.

**Problems found and fixed.**
- New API functions were not callable after a migration (PostgREST schema cache, job 309). `migrate.sh` now sends
  `NOTIFY pgrst, 'reload schema'` on every run (job 313).
- The local tool environments in `/tmp` were lost in a restart. They were rebuilt in `~/.cache/aigov`.

**Tests.** Unit tests for the three new filters (80 in total), V009 SQL tests (grants, record, owner refused by ID,
e-mail and name, another approver accepted), schema examples (140), and the Execute Jinja on ansible-core 2.16
(succeeded and refused paths).

**Results on mk6hb** (remediation `320f53ea-43db-4feb-9ede-155870a7fa14`, `quick_helper_bot` IAM-001):

| Step | Job | Result |
|---|---|---|
| V009 applied; schema cache reload | 307, 313 | done |
| Execute before approval | 315 | `refused`; nothing changed; still awaiting approval |
| Approval recorded by the user (human) | 316 | `approved` |
| Execute | 318 | `succeeded`: attached `aigov-approved-agentcore-runtime-basic`, detached `AdministratorAccess` |
| Execute again | 320 | `refused` (remediation is `succeeded`) |
| Reassess | 321 | IAM-001 `pass` (the stale-finding case from T2.03, now shown live) |
| Get Finding Context | 322 | finding `verifying` |

**Not shown live.** Drift refusal, failed execution, the boundary, inline-removal and tag actions (unit tests and
simulation). There is no AO approval yet, because WF-02 is T2.09. The approval was recorded with the interim AAP job.

**Left in place for T2.07.** The `quick_helper_bot` role is remediated and the finding awaits verification. Reset Demo
Agents restores the original policies.

---

## 2026-11-22 - T2.07 Verify Remediation

**Built.**
- **AI Governance - Verify Remediation** (`playbooks/remediation/verify.yml`; AWS bootstrap + **discovery** role +
  Inventory API remediator):
  1. For IAM actions, IAM policy simulation of the administrator probes (`admin_probe_actions` from OPA), retried 6 × 10 s
     until they are denied (IAM is eventually consistent).
  2. Independent re-collection of the agent with the read-only discovery role and the discovery adapter, never the
     remediation role. Then an OPA evaluation with purpose `verification`.
  3. `api.record_verification` decides. Problems before the decision give `status: error` and leave the remediation
     unchanged, so Verify can run again. The functional smoke test (P1) is not implemented (`functional_check: skipped`).
- **V010 `api.record_verification`**: in one transaction it records the verification evaluation and computes two checks
  itself:
  - the target policy decision;
  - regressions: policies that passed in the agent's last evaluation before the remediation and fail now.

  It combines them with the AWS checks the job reports (probes denied, agent READY). If all pass, the remediation is
  `verified` and `api.close_finding` resolves the finding as `remediated`. Otherwise it is `verification_failed`, with a
  check-by-check report in the record and the audit. A regression also opens a new finding.
- Filters `remediation_probe_check` and `remediation_simulation_checks`. Contract `artifacts.v1.json#/$defs/verify`.

**Decision.** Verify must both record an evaluation and change the remediation, and AAP allows only one credential of
each custom type per template. So the decision is one remediator database function, and the remediator also reads
`api.evaluation_inputs` (the privilege-matrix test was updated). The database, not the playbook, decides "verified",
as with the other safety rules.

**Tests.** V010 SQL tests:
- grants;
- invalid check values refused;
- verified, with the finding resolved as remediated;
- a second verification refused;
- a regression (TAG-001 pass to fail) fails and opens a new finding;
- an admin probe still allowed fails even when OPA says pass.

Also unit tests (82), schema examples (150), and the Verify Jinja on ansible-core 2.16.

**Results on mk6hb.** V010 applied (job 326). **Verify (job 327): `verified`.** Details: IAM-001 `pass`, 0 regressions,
probes `all_denied`, agent `READY`, finding `resolved` (remediated), verification evaluation `4597cdca`. This is the
first full closed loop on the demo: detect, plan, human approval, execute, verify, resolve. A second Verify makes no
decision (job 329, `error`, remediation unchanged).

Check Inventory now fails (job 331) as expected: it compares with the demo baseline, which still expects IAM-001 on
`quick_helper_bot`. Reset Demo Environment restores the baseline.

**Not shown live.** `verification_failed` (regression, probes still allowed, agent not READY): covered by the SQL tests.

---

## 2026-11-22 - T2.08 Rollback Remediation

**Built.**
- **AI Governance - Rollback Remediation** (`playbooks/remediation/rollback.yml`; AWS bootstrap + remediation role +
  Inventory API remediator). The job template takes only the two IDs (survey) and runs one at a time.
  - Preconditions (refused, nothing changed): the remediation is `failed` or `verification_failed`, a human-approved
    rollback approval is recorded, and a pre-state exists.
  - Rollback plan (filter `remediation_rollback_plan`), from the pre-state and what AWS shows now:
    - `nothing`: already at the pre-state;
    - `automated`: every step is allowed to `AIGovRemediationRole`. That covers detaching the approved policy after a
      partial failure, removing a boundary that was not there before, and undoing governance tags (only the keys the
      remediation added; other tags are kept);
    - `manual`: a step would re-attach a non-approved policy (for example AdministratorAccess), set another boundary or
      recreate an inline policy. The remediation role is denied these by design (**Q-11, decision a**). Nothing is
      changed, and the steps are listed in the artifacts and in a `rollback.manual_required` audit event.
  - Automated: runs the steps, re-reads AWS, requires the pre-state to be restored, and stores `rolled_back` or
    `rollback_failed`. The database requires the rollback approval for both.
- **Record Approval Decision** takes `aigov_approval_kind` (`remediation` or `rollback`).
- Contract `artifacts.v1.json#/$defs/rollback`.

**Problem found and fixed.** `agentcore_runtime_info` first lists all runtimes (`ListAgentRuntimes`), which the
remediation role may not do. Execute's post-state had silently recorded no runtime tags. `agentcore_runtime_tags` now
returns `tags_before`. A check-mode call with no tags reads them using only `ListTagsForResource`, and Execute and
Rollback both use it, so the role did not have to be widened.

**Tests.** The rollback plan in unit tests (89 in total):
- replacing an admin policy rolls back manually;
- a partial failure rolls back automatically;
- the pre-state needs nothing;
- boundary rollback is automated or manual depending on the previous boundary;
- inline rollback is manual;
- tags are restored for the remediation's keys only;
- an unknown action is manual.

Also schema examples (158) and the Rollback Jinja on ansible-core 2.16 (automated tags, manual admin).

**Results on mk6hb** (`quick_helper_bot` AIGOV-REG-001, remediation `9368225f-8c95-4184-9084-762fc4219138`):

| Step | Job | Result |
|---|---|---|
| Plan | 337 | `approval`: quarantine tags (`aigov:status`, `aigov:finding`, `aigov:policy`) |
| Remediation approved by the user | 338 | `approved` |
| Execute | 340 | `succeeded`: tags added |
| Verify | 341 | `verification_failed`: REG-001 still fails (tags contain a shadow agent but do not register it), 0 regressions, agent READY |
| Rollback without a rollback approval | 343 | `refused`, nothing changed |
| Rollback approved by the user | 344 | `kind: rollback`, `approved` |
| Rollback | 346 | `rolled_back`: removed exactly the three tags; the pre-state was confirmed from AWS |
| Rollback again | 348 | `refused` (already rolled back) |
| Rollback of the verified IAM fix `320f53ea…` | 349 | `refused` (verified remediations are not rolled back) |
| Get Finding Context | 351 | REG-001 `open` again (the real fix is registering the agent) |

**Not shown live.** `manual_required` and `rollback_failed`: covered by unit tests and the 2.16 simulation. A live
manual case needs a failed IAM remediation.

---

## Open items (2026-11-22)

| Item | Notes |
|---|---|
| Visual review of the Grafana dashboards | `https://grafana-ai-governance.apps.cluster-mk6hb.dyn.redhatworkshops.io`, folder *AI Governance* |
| Regal (Rego linter) | Blocked locally by the permission checker; could run as a CI-only step if wanted |
| Live demonstration of finding auto-close | Covered by SQL tests; not shown live yet (the reset resolves findings as `demo_reset`). A good Stage 2 demo moment: renew HR's risk assessment and re-run WF-01 |
| Bedrock Agents Classic live test | Needs an AWS account with Bedrock Agents activity in the past 12 months |
| `claude-work-access` has an extra `project-user` assignment | `project-admin` covers it; can be removed |
| Demo profile published on mk6hb | Still on. `quick_helper_bot` IAM-001 was remediated and verified, so the demo is off its baseline and Check Inventory fails (job 331) until Reset Demo Environment runs. Republish with `aigov_policy_profile: default` to turn remediation off |
| Interim approval recording | Record Approval Decision takes the approver as a launch variable (admins only) until T2.10 reads decisions from the AO approvals API |
| OPA decision IDs | Empty in plan records until OPA decision logging is enabled; the bundle revision identifies the policy version |
| Workstation `~/.ansible/collections` mock modules | Reinstall the real collections there if other projects need them |
