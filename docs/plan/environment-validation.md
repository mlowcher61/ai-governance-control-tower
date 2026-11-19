# Environment Validation (T0.01 / T0.02 partial)

**Date:** 2026-11-17

**Method:** read-only API checks only. No objects were created or modified in AAP, AO, or AWS.

---

## 1. Ansible Automation Platform

| Check | Result |
|---|---|
| Gateway | `https://<aap-gateway-host>` (from `$AAP_SERVER`; the value has no scheme, so playbooks must prepend `https://`) |
| Controller version | **4.8.13** (AAP 2.7) ✅ |
| Token identity | `admin`, superuser ✅ |
| Organizations | `Ansible Product Demos (APD)`, `Default`, `IT Service Automation`, `Linux Patching`. **`AI Governance` does not exist yet** and will be created by config as code |
| Existing credentials of interest | `AWS` (×2, Amazon Web Services), `Autohub - Certified`, `Autohub - Validated`, `OpenShift Credential`, `CVE Demo - Automation Orchestrator` (custom type with `ao_url`, `ao_username`, `ao_password`), `Sales Demos - Inference Endpoint` (`inference_url=https://<litemaas-endpoint>`, `inference_model=llama-scout-17b`) |
| Private hub collections | `ansible.platform` 2.7.20260930, `ansible.controller` 4.8.11, `ansible.eda` 2.13.0, `amazon.aws` 11.5.0, `amazon.ai` 1.0.1, `infra.aap_configuration` 4.10.0, `kubernetes.core` 6.6.0, `ansible.utils` 6.1.1 ✅ |

## 2. automation orchestrator

| Check | Result |
|---|---|
| URL | `https://<ao-route-host>`, the same OpenShift cluster as AAP (integrated deployment) ✅ |
| Authentication | The AAP bearer token is **not** accepted (401). AO needs its own login (`POST /api/v1/auth/login`) or a service-account OAuth2 client (`POST /api/v1/auth/token`). **An AO credential is needed for automation** (see Q-25) |
| OpenAPI | Public at `/api_docs/v1/openapi.json`: **"Orchestrator API" version 1.3.0**, OpenAPI 3.1, 126 paths. Saved to `ao_workflows/reference/openapi.json` ✅ |
| LLM | User-confirmed: the existing AO credential **"LiteMaaS API Key"** with model **`llama-scout-17b`**, used by the workflow "Compliance as Code - Golden Image (as code)" |
| Reference workflow export | **Pending AO authentication.** The target is "Compliance as Code - Golden Image (as code)" via `GET /api/v1/workflows/{id}/versions/{v}/export` |

### 2.1 AO interface facts from the official OpenAPI (resolves several unverified items)

| Topic | Finding | Plan impact |
|---|---|---|
| Workflow definition | `WorkflowDefinition`: `schema_version` (const `"2.0.0"`), `name`, `description`, `triggers[]`, `nodes[]`, `edges[]` ✅ | Matches the plan |
| Export / import | `GET /workflows/{id}/versions/{version}/export` exists; import is `POST /workflows` with a definition; `POST /workflows/validate`; `POST /workflows/{id}/test`; publish, unpublish, restore ✅ | Resolves U-01 |
| Node types (enum) | `manual_trigger`, **`scheduled_trigger`**, `webhook_trigger`, `eda_trigger`, `condition`, `converge`, `loop`, `switch`, `wait`, `aap_job_template`, `aap_workflow_job_template`, `agentic`, `approval`, `http_request`, `internal_activity`, `script` ✅ | Schedule trigger type is `scheduled_trigger` (older exports used `schedule_trigger`); plan corrected |
| Node settings | `aap_job_template` and `http_request`: `settings.{timeout, retry_policy{max_retries, initial_interval, max_interval, backoff_coefficient}, continue_on_failure, disabled}`. `agentic` and `approval`: `{timeout, continue_on_failure, disabled}` (no retry) ✅ | Timeouts and retries are native per node; the AI step uses `continue_on_failure: true` (resolves U-04) |
| Approval | `approver_users`, `approver_groups`, `prompt`, `fallback_decision` ("decision when approval times out with continue_on_failure"), **`decision_window` (seconds)**, `credential_id` ✅ | Approval timeout configurable (resolves U-05); use `decision_window: 3600` for the demo |
| Converge | `strategy: all \| any`, `n_required`, `wait_duration` ✅ | Branch merges use an explicit `converge` (`strategy: any`) instead of relying on implicit OR-join (resolves U-03) |
| HTTP request | `method`, `url`, `headers`, `body` (object or string), `query_params`, **`credential_id`** ✅ | OPA calls can carry a credential if OPA auth is enabled (U-07 partially resolved; response path still to confirm) |
| AAP job template | `job_template_name` / `job_template_id`, `organization_name`, `extra_vars`, `credential_id`, `integration_id`, `limit`, `inventory_name`, `job_credentials`, `diff_mode`, `execution_environment`, … ✅ | Matches the plan |
| Agentic | `prompt`, `llm_model_id`, `credential_id`, **`responseSchema`** (camelCase in the API), `integration_connections`, `tool_selection_strategy`, `tool_selections`, `file_ids`, `agent` ✅ | Definitions use `responseSchema` |
| Execution control | `POST /executions/{id}/cancel`, `/retry`, `/activities/{activity_id}/signal` ✅ | — |
| Service accounts | `/service_accounts` with credential create, rotate, disable ✅ | Config as code can create `aigov-trigger` |
| Webhooks | `POST /webhooks/{path}` and `POST /webhooks/eda/{path}` ✅ | Alternative EDA path |

### 2.2 Reference workflow export (2026-11-18, AO service account `ai-service-account`)

- **Access:** the AO service-account client credentials (`AO_CLIENT_ID` / `AO_CLIENT_SECRET`) work, yielding a 15-minute JWT. The service account sees 7 workflows.
- **Export:** "Compliance as Code - Golden Image (as code)" v2 was exported via `GET /workflows/{id}/versions/2/export` (`schema_version` 2.0.0). A sanitized copy is in `ao_workflows/reference/golden-image-export.sanitized.json`.
- **Runtime proof:** the workflow has several **completed** executions (most recently 2026-11-11), so the patterns below are proven at runtime, not just valid on paper.

| Item | Finding |
|---|---|
| U-02 trigger input | ✅ `${trigger.<field>}` (for example `${trigger.target_hostname}`). The trigger node's ID is not used |
| U-07 REST response | ✅ `${<node>.body.result.<field>}` and `${<node>.body.decision_id}`. Output also has `status_code`, `headers`, `elapsed` |
| OPA gating pattern | ✅ `http_request` POST to OPA `/v1/data/.../decision` with the AI recommendation and facts in `input`; `switch` on `${opa_gate.body.result.route} == 'auto' \| 'approve' \| ...`; OPA may override the agent (`overrode_agent`) |
| Approval output | ✅ `decision`, `decided_at`, **`decided_by`** (federated username). The approver identity can be passed directly to the audit job |
| `aap_job_template` output | ✅ `job_id`, `job_url`, `status`, `artifacts`, timestamps |
| `agentic` output | ✅ `result.content` plus `tokens_used`, `tools_used`, `structured_output_metadata`, `agent_trace` |
| Skipped branches | ✅ Untaken branches are recorded with status `skipped` |
| U-06 execution ID expression | Still not seen in any expression. Activity records carry `execution_id`, and approval `decided_by` removes the main need for it |
| Agentic parameters in storage | `response_schema` (snake_case) is stored, although the API accepts `responseSchema`. The reference uses `tool_selection_strategy: ALL` with 2 MCP connections; this project uses `NONE` |

## 3. AWS

**Update 2026-11-17 (implementation):**

| Check | Result |
|---|---|
| AAP credential `AWS` (ID 18) | **Invalid**: `InvalidClientTokenId` (access key rejected by AWS) |
| AAP credential `AWS` (ID 4, org APD) | ✅ Account **759722782548**, IAM user `open-environment-t5d26-1-admin`. Used as the bootstrap principal |
| Region | **us-west-1**. AgentCore Runtime (microVMs and instances), Gateway, Identity and Policy are available. The managed **harness, Memory and Agent Registry are not available** in us-west-1, so demo runtimes use direct code deployment |
| AAP `Default execution environment` | ansible-core 2.16.19, **boto3 1.38.27**, which has no `bedrock-agentcore-control` client (`UnknownServiceError`). A custom EE is required for AgentCore APIs (T0.04) |
| Governance roles stack `aigov-governance-roles` | ✅ Deployed (AAP job 1253) |
| Demo stacks `aigov-demo-artifacts`, `aigov-demo-agents` | ✅ Deployed (AAP job 1255). Four AgentCore runtimes **READY** |
| Least-privilege verification | ✅ 19/19 IAM policy-simulator checks passed as `AIGovDiscoveryRole` (AAP job 1257). ✅ **Full verification on `ai-governance-ee` (AAP job 1271, 2026-11-18): all 4 AgentCore runtimes listed READY through the discovery role** |

| Check | Result |
|---|---|
| Bedrock Agents Classic | **The user has never used Bedrock Agents.** Under the 2026-07-30 maintenance-mode rules, `CreateAgent` will be denied (HTTP 403) in any of their accounts. **Decision: AgentCore is the demo platform** (Q-01 resolved) |
| Credentials | AAP has two credentials named `AWS` (Amazon Web Services type). The account ID and Region were not inspected because the secrets cannot be read. **Which one to use, and whether governance roles and demo resources may be created in it, still needs confirming** (Q-26) |

## 4. Private automation hub content issue

| Check | Result |
|---|---|
| `ansible.utils` 6.1.1 (rh-certified) | **Artifact hash mismatch.** `ansible-galaxy` fails with "Mismatch artifact hash with downloaded file". Reproduced from AAP project sync and from a workstation. The project pins 6.1.0, which installs cleanly. **Action for the hub administrator:** re-sync or repair `ansible.utils` 6.1.1 |
| `amazon.aws` 11.5.0, `amazon.ai` 1.0.1, `kubernetes.core` 6.6.0 | Install cleanly from the private hub ✅ |

## 5. Tokens

| Token | Result |
|---|---|
| `$AAP_API_TOKEN` | Valid ✅ |
| `$GITHUB_TOKEN` | Present (not exercised; it will be used to create the repository after approval) |
| `$VALIDATED_HUB_TOKEN` | **Rejected by Red Hat SSO** (`invalid_grant: Offline user session not found`). The offline token appears expired or revoked; regenerate it at console.redhat.com → Automation Hub → API token. Not blocking, because the private hub already syncs certified and validated content |

## 6. Governance platform services (T0.06, 2026-11-18)

| Check | Result |
|---|---|
| AAP credential | `OpenShift Credential` (ID 5, org APD), cluster `api.cluster-t5d26`. Its token can create namespaces, NetworkPolicies, Routes, StatefulSets, and Jobs ✅ |
| Namespace | `ai-governance` ✅ |
| Images | `registry.redhat.io/rhel9/postgresql-16:1-1794513854`, `postgrest/postgrest:v16.6`, `openpolicyagent/opa:1.22.4-static`, `grafana/grafana:13.3.1`. The cluster pulls from registry.redhat.io and docker.io without a mirror ✅ |
| Deploy job | **AAP job 1289 successful.** Job 1287 (the first run) timed out waiting for Grafana on its first start; the re-run converged |
| Health | OPA `/health` OK, and `GET /v1/data/governance/platform/info` returns the bootstrap policy; PostgREST `GET /rpc/health` reports PostgreSQL 16.15; Grafana `/api/health` reports 13.3.1 through its route ✅ |
| NetworkPolicy | A pod with `aigov/db-client=true` reaches `governance-db:5432`; a pod without it is blocked ✅ |
| AAP job pods → services | The deploy job called OPA and PostgREST by service DNS, so AAP job pods run in a trusted namespace (`aap`) ✅. The AO worker namespace (`automation-orchestrator`) is assumed from the AO route name and will be proven by the first AO `http_request` to OPA (Stage 2) |

## 7. automation orchestrator config as code (T0.08, 2026-11-18)

| Check | Result |
|---|---|
| Validate endpoint | `POST /workflows/validate` takes `{"workflow_definition": {...}}` and returns 422 with `validation_result.findings` when the definition is invalid ✅ |
| Loader | `ao_workflows/apply_workflows.yml` created "AI Governance - Loader Test (as code)" (version 1, published). A second run reported `unchanged`, `changed=0` ✅ |
| Execution | AO execution `daa650ad-2fdb-4821-b243-a1b691e286bc` **completed**. It launched AAP job 1284 (*AI Governance - Check Environment*), whose `set_stats` artifacts came back in the activity output ✅ |
| AAP proxy | `GET /proxies/aap/job_templates?organization=<name>` filters by organization **name** ✅ |
| Paging | `GET /workflows` accepts `limit` ≤ 100 |
| Service account rights | `ai-service-account` is scoped to project `default`. It can manage workflows, credentials, executions, approvals, and service accounts. It **cannot** read settings (403) |
| `aigov-trigger` | Created by `configure_ao.yml` (ID `5f2ac72f-…`). **Its client credential is not issued yet.** Issuing it writes the secret into the AAP credential *AI Governance - Automation Orchestrator*; the automated step was held for user confirmation |
| SSRF allowlist | **Not verified** (settings require an AO administrator). It must contain `opa.ai-governance.svc`, `governance-api.ai-governance.svc`, and the AAP gateway host, and it must reach ao-worker |
| LLM integration | **"LiteMaaS" is in validation status `error`: HTTP 401.** The API key needs renewal before the Stage 1 AI explanation step (T1.11) |

### 7.1 Update 2026-11-19

| Check | Result |
|---|---|
| LLM credential | The AO credential "LiteMaaS API Key" was updated with a new key (`$LITEMAAS_TOKEN`). **Workflow "AI Governance - LLM Smoke Test (as code)" execution `fb83e168` completed**: `llama-scout-17b` returned schema-valid structured output (`${activity_llm_check.result.content.status}` = `ok`), which addresses the basic Q-27 structured-output risk. The integration's *cached* validation status still shows the old 401, because re-validation (`POST /integrations/{id}/validate`) needs an AO admin |
| `aigov-trigger` credential | Issued and stored in the AAP credential *AI Governance - Automation Orchestrator* by `configure_ao.yml` ✅ |
| `aigov-trigger` rights | It authenticates from AAP (job 1308), but has **no project role**: it sees no projects or credentials, and integrations return 403. `configure_ao.yml` now assigns `project-user` in project `default` (config var `aigov_ao_trigger_role`). `ai-service-account` is project-admin, so it is allowed to do this; the automated grant is waiting for user confirmation |
| Second AO client | `AO_DEMO_CLIENT_ID` is a second client credential for the same `ai-service-account` (same rights) |
| mk6hb AAP | `$AAP_SERVER_DEMO` (cluster mk6hb) is reachable, but `AAP_API_TOKEN` returns 401 there. The governance deployment stays on t5d26 |

## 8. Second environment: cluster mk6hb (2026-11-19)

Work moved to cluster **mk6hb**. It was rebuilt from an empty state with the config as code only, which is
also a test of the new-user steps in [aap_config/README.md](../../aap_config/README.md).

| Check | Result |
|---|---|
| AAP | `https://aap-aap.apps.cluster-mk6hb.dyn.redhatworkshops.io`, controller 4.8.13. The token in `$AAP_DEMO_TOKEN` is a superuser ✅ |
| Private hub | `infra.aap_configuration` 4.11.1 (validated), `ansible.platform` 2.7.20260930, `ansible.controller` 4.8.12; every collection pinned in `collections/requirements.yml` is available, including `ansible.utils` 6.1.0 ✅ |
| Existing credentials used | `AWS` (ID 7, org APD) as the AWS bootstrap credential; `OpenShift Credential` (ID 5); `AAP Credential` (ID 4) for **Issue API Tokens** |
| AWS account | **505889097019** (IAM user `open-environment-mk6hb-1-admin`, us-west-1), found by **Check Environment** (job 40). No AgentCore runtimes existed beforehand |
| AWS baseline | Governance roles (job 43) and demo agents (job 44) deployed. **Verify AWS Baseline** (job 46): no failed least-privilege checks, and all four runtimes are `READY` through the discovery role ✅ |
| Platform services | **Deploy Platform Services** (job 48) ✅: all acceptance checks passed, including the NetworkPolicy allow and block probes. Grafana is at `https://grafana-ai-governance.apps.cluster-mk6hb.dyn.redhatworkshops.io` |
| Database | V001 (job 49; the re-run, job 51, reported `changed=0`) and V002 (job 55) applied ✅ |
| Inventory API tokens | **Issue API Tokens** (job 56) ✅: six tokens; every token switches PostgREST to its own role; 15/15 read-only HTTP acceptance checks passed from an AAP job pod; no token appears in the job output. A config-as-code re-run keeps the tokens |
| automation orchestrator | `https://ao-automation-orchestrator.apps.cluster-mk6hb.dyn.redhatworkshops.io`, API 1.3.2. Integrations *Ansible Automation Platform* and *LiteMaaS* are `available`. The `$AO_DEMO_CLIENT_ID` service account (`claude-work-access`) is project-admin in project `default` |
| AO config as code | `configure_ao.yml` ✅: it created `aigov-trigger`, assigned `project-user` in `default`, and stored its client credential in the AAP credential *AI Governance - Automation Orchestrator*. **Apply AO Workflows** (AAP job 62, running as `aigov-trigger`) created and published both workflows |
| AO executions | Loader test `fed0b761` completed; it ran **Check Environment** as AAP job 65. LLM smoke test `63ba65dd` completed (`llama-scout-17b`) ✅ |
| SSRF allowlist | The AO UI could only grant project roles, so no AO identity could change settings through the API. **AI Governance - Configure AO Network Allowlist** set it at the deployment level instead, in the `ao-admin-settings` ConfigMap that every AO Deployment loads. It **merged** the AAP gateway, `opa.ai-governance.svc` and `governance-api.ai-governance.svc` into the existing value and kept `maas-rhdp.apps.maas.redhatworkshops.io`, which the LiteMaaS integration needs. It restarted AO (job 71); re-runs (jobs 87 and 89) report `changed=0` and do not restart. The value was checked inside the running ao-worker pod ✅. After the restart the loader test (`abd98b0a`) and LLM smoke test (`19557e83`) still complete |
| Note | sales.demos' "AAP Ecosystem - Configure Automation Orchestrator" writes the same ConfigMap with **only** the AAP host. If it runs again, re-run **Configure AO Network Allowlist** afterwards |
