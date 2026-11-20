# Progress log

What was built, what it proved, what went wrong and how it was fixed, and what was decided, task by task.
The README's *Implementation status* table has the one-line summary; this log has the detail. Environment
facts are in [plan/environment-validation.md](plan/environment-validation.md), verified automation orchestrator
executions in [../ao_workflows/reference/VERIFIED.md](../ao_workflows/reference/VERIFIED.md), and decisions in
[plan/13-open-questions.md](plan/13-open-questions.md).

Stage 0 and T1.01 were built on cluster **t5d26** (2026-11-17 to 2026-11-19); see environment-validation.md
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

---

## Open items (2026-11-20)

| Item | Notes |
|---|---|
| Visual review of the Grafana dashboards | `https://grafana-ai-governance.apps.cluster-mk6hb.dyn.redhatworkshops.io`, folder *AI Governance* |
| Regal (Rego linter) | Blocked locally by the permission checker; could run as a CI-only step if wanted |
| Live demonstration of finding auto-close | Planned in T1.13 (for example renew HR's risk assessment) |
| Bedrock Agents Classic live test | Needs an AWS account with Bedrock Agents activity in the past 12 months |
| `claude-work-access` has an extra `project-user` assignment | `project-admin` covers it; can be removed |
| Workstation `~/.ansible/collections` mock modules | Reinstall the real collections there if other projects need them |
