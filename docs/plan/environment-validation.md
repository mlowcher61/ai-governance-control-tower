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

**Still open:** the execution ID as an expression (U-06), the trigger-input expression syntax (U-02), and the `http_request` response path (U-07). These need an authenticated test run.

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
| Least-privilege verification | ✅ 19/19 IAM policy-simulator checks passed as `AIGovDiscoveryRole` (AAP job 1257). Runtime listing awaits the custom EE |

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
