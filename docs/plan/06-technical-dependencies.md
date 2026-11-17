# 06 — Technical Dependencies

Legend: ✅ verified at the stated version · 🟡 partially verified · ❓ unverified (validated in the Stage 0 spike)

Version data was collected on **2026-11-17**:

- **Collection versions:** taken from the connected AAP private automation hub (`rh-certified` and `validated` repositories), and confirmed in the upstream GitHub tags where noted.
- **Platform versions:** the connected AAP environment reported controller **4.8.13** and Lightspeed **2.7.20261019**, which places it on AAP 2.7.

---

## 1. Platform software

| Component | Version | Status | Notes / source |
|---|---|---|---|
| Red Hat Ansible Automation Platform | **2.7** (GA 2026-06-10; latest patch found 2026-10-05) | ✅ | Containerized or operator install only. Since 2.7, component APIs are reached only through the platform gateway ([API changes](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/upgrade-con_upgrade_api_changes_27)) |
| automation orchestrator (AO) | **2026.8** documentation set; GA as a paid add-on for AAP 2.7+ | 🟡 | OpenShift-only operator (`automation-orchestrator-operator`, channel `stable`) ([docs](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8)). The exact GA date is inconsistent across sources. A Technology Preview disclaimer appears on one install page; check which item it applies to (❓). Pin the operator with `installPlanApproval: Manual`, because an auto-upgrade broke SSO in the reference environment |
| Red Hat OpenShift Container Platform | Version supported by AO 2026.8 and AAP 2.7 operators | ❓ | Confirm against the AO install guide |
| Open Policy Agent | **1.22.x** (v1.22.4 released 2026-11-12) | ✅ | Rego v1 default since OPA 1.0. CNCF graduated project. The image `openpolicyagent/opa:<version>-static` is community upstream, not Red Hat supported |
| Regal (Rego linter) | 0.43.0 | ✅ | CI only |
| PostgreSQL | 16 (`registry.redhat.io/rhel9/postgresql-16`) | ✅ image exists | Customer may substitute a managed or enterprise PostgreSQL |
| PostgREST | 12.x / 13.x (pin at implementation) | ✅ project | Community (MIT). **Decision required** (AD-03) |
| Grafana OSS | 13.x (v13.3.1 released 2026-11-10) | ✅ | `grafana-postgresql-datasource` plugin is built in |
| Red Hat build of OpenTelemetry | Version matching the OpenShift release | 🟡 | Stage 3. Upstream Collector is v0.165.0. Receiver availability in the Red Hat build is ❓ |
| Grafana Tempo | Optional (Stage 3 traces) | — | Or the Red Hat distributed tracing platform, if the customer has it |

## 2. Ansible content

### 2.1 Collections

| Collection | Version on hub | Support | Use | Status |
|---|---|---|---|---|
| `ansible.platform` | 2.7.20260930 | Certified | Gateway objects: organizations, teams, users, role assignments, authenticators, settings | ✅ The tag `v2.7.20260930` contains **gateway modules only**. Controller and EDA modules exist only on the unreleased `devel` branch |
| `ansible.controller` | 4.8.11 | Certified | Controller objects (credential types, credentials, projects, job templates, schedules, notification templates), consumed via `infra.aap_configuration` | ✅ |
| `ansible.eda` | 2.13.0 | Certified | EDA config (`project`, `credential`, `decision_environment`, `rulebook_activation`) and event sources (`aws_sqs_queue`, `webhook`, `azure_service_bus`, …) | ✅ |
| `infra.aap_configuration` | 4.10.0 | Validated | Config-as-code `dispatch` role for gateway, controller, EDA, and hub objects | ✅ |
| `amazon.aws` | 11.5.0 | Certified | `sts_assume_role`, `aws_caller_info`, `iam_role`, `iam_role_info`, `iam_policy`, `iam_policy_info`, `iam_managed_policy`, `cloudformation`, `s3_object` | ✅ Module list checked at tag `11.5.0`. **No module returns managed policy documents, metric data, or Cost Explorer data** |
| `amazon.ai` | **1.0.1** on hub (upstream 2.0.0 released 2026-11-16) | Certified | `bedrock_agent_info`, `bedrock_agent_action_group(_info)`, `bedrock_agent_alias(_info)`, `bedrock_invoke_agent`, `bedrock_foundation_models_info` | ✅ Module list checked at tag `1.0.1`. 1.0.1 has no AgentCore modules; 2.0.0 adds `bedrock_agentcore_runtime(_info)` and `…_endpoint(_info)` (sync to hub when certified) |
| `kubernetes.core` | 6.6.0 | Certified | Deploy governance services, migration Job, ConfigMaps | ✅ |
| `ansible.utils` | 6.1.1 | Certified | `validate` (JSON Schema) and data filters | ✅ |
| `servicenow.itsm` | 2.16.0 | Certified | Optional notifications and evidence attachment (Stage 3) | ✅ on hub |
| `hashicorp.vault` | 1.3.0 | Certified | Optional secret backend integration | ✅ on hub |
| `styra.opa` | 1.1.1 | Certified (partner) | OPA installer role only (`k8s_pdp`); no query modules; last commit April 2024 | ✅ Evaluate in the spike; not the primary approach (AD-10) |
| `community.postgresql` | — | **Community (Galaxy)**, not on the certified hub | **Not used.** PostgREST replaces it | ✅ absence confirmed on hub |
| `community.aws` | — | Community | **Not used** | — |
| `mlowcher61.ai_governance` | 0.x (this project) | Project collection | Roles, custom modules, filters (§2.2) | To build |

### 2.2 Custom modules (project collection)

All custom modules are built on `amazon.aws` module utilities and support `check_mode`. Each one exists because of a verified content gap.

| Module | Type | Gap justification |
|---|---|---|
| `bedrock_agent_details_info` | read | Tags, KB associations, data sources, collaborators, and guardrail are not returned by `amazon.ai` 1.0.1 |
| `iam_role_permissions_info` | read | No certified module returns managed policy documents or permissions boundary details |
| `iam_policy_simulation_info` | read | No module for `SimulatePrincipalPolicy` |
| `agentcore_runtime_info` | read | Not in `amazon.ai` 1.0.1; **retire when 2.x is on hub** |
| `bedrock_agent_alias_state` | write | `UpdateAgentAlias` `aliasInvocationState` is not exposed by `amazon.ai.bedrock_agent_alias` 1.0.1 |
| `bedrock_agent_tags` | write | `amazon.ai.bedrock_agent` 1.0.1 does not tag existing agents on update (source review: no `TagResource` call) and requires `foundation_model`, `instruction`, and role for `state: present` |
| `cloudwatch_metric_data_info` | read | No `GetMetricData` module in `amazon.aws` 11.5.0 (Stage 3) |
| `cost_explorer_info` | read | No Cost Explorer module (Stage 3) |

### 2.3 Execution and decision environments

| Image | Base | Contents |
|---|---|---|
| **AI Governance EE** (`ai-governance-ee:<semver>`) | `registry.redhat.io/ansible-automation-platform-27/ee-minimal-rhel9` | Collections in §2.1 (certified versions pinned), the project collection, Python `boto3`/`botocore` (current release pinned at build; must include `bedrock-agentcore-control` and `UpdateAgentAlias.aliasInvocationState`), `jsonschema`, and the `opa` binary (policy test and publish job). Built with **ansible-builder v3** (`execution-environment.yml` `version: 3`) |
| **AI Governance DE** | `registry.redhat.io/ansible-automation-platform-27/de-supported-rhel9` | `ansible.eda` (SQS source requires `aiobotocore`; confirm it is included ❓) |

## 3. External APIs

| API | Operations used | Stage | Docs |
|---|---|---|---|
| Amazon Bedrock Agents (`bedrock-agent`) | `ListAgents`, `GetAgent`, `ListAgentActionGroups`, `GetAgentActionGroup`, `UpdateAgentActionGroup`, `PrepareAgent`, `ListAgentAliases`, `GetAgentAlias`, `UpdateAgentAlias`, `ListAgentKnowledgeBases`, `GetKnowledgeBase`, `ListDataSources`, `GetDataSource`, `ListAgentCollaborators`, `ListTagsForResource`, `TagResource`, `UntagResource` | 1–2 | ✅ [Operations](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_Operations_Agents_for_Amazon_Bedrock.html), [Agent](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_Agent.html), [UpdateAgentAlias](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_UpdateAgentAlias.html), [UpdateAgentActionGroup](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_UpdateAgentActionGroup.html), [maintenance mode](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-classic-maintenance-mode.html) |
| Amazon Bedrock AgentCore control (`bedrock-agentcore-control`) | `ListAgentRuntimes`, `GetAgentRuntime`, `ListAgentRuntimeEndpoints`, `ListTagsForResource` | 1 | ✅ [Operations](https://docs.aws.amazon.com/bedrock-agentcore-control/latest/APIReference/API_Operations.html), [GetAgentRuntime](https://docs.aws.amazon.com/bedrock-agentcore-control/latest/APIReference/API_GetAgentRuntime.html) |
| Amazon Bedrock (`bedrock`) | `ListFoundationModels`, `GetModelInvocationLoggingConfiguration` | 1, 3 | ✅ |
| AWS IAM | `GetRole`, `ListAttachedRolePolicies`, `ListRolePolicies`, `GetRolePolicy`, `GetPolicy`, `GetPolicyVersion`, `SimulatePrincipalPolicy`, `AttachRolePolicy`, `DetachRolePolicy`, `PutRolePermissionsBoundary`, `DeleteRolePermissionsBoundary`, `DeleteRolePolicy`, `PutRolePolicy`, `TagRole` | 1–2 | ✅ [Operations](https://docs.aws.amazon.com/IAM/latest/APIReference/API_Operations.html) |
| AWS STS | `AssumeRole`, `GetCallerIdentity` | 1 | ✅ |
| AWS CloudTrail | `LookupEvents` (creator identity, P1); trail as event source | 1, 3 | ✅ [Bedrock CloudTrail](https://docs.aws.amazon.com/bedrock/latest/userguide/logging-using-cloudtrail.html) |
| Amazon EventBridge | Rules with `detail-type: AWS API Call via CloudTrail` | 3 | ✅ [CloudTrail events](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-service-event-cloudtrail.html) |
| Amazon SQS | Queue + DLQ; EDA polling | 3 | ✅ |
| Amazon CloudWatch | `GetMetricData` (`AWS/Bedrock`, `AWS/Bedrock/Agents`) | 3 | ✅ [Agents metrics](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-agents-cw-metrics.html), [runtime metrics](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-runtime-metrics.html) |
| AWS Cost Explorer | `GetCostAndUsage` | 3 | 🟡 [Bedrock cost management](https://docs.aws.amazon.com/bedrock/latest/userguide/cost-management.html) |
| AO REST API | `POST /api/v1/auth/token`, `POST /api/v1/executions`, `GET /api/v1/executions/{id}`, `/executions/{id}/activities`, `GET /api/v1/approvals`, `/workflows`, `/workflows/validate`, `/workflows/{id}/versions/{v}/publish`, `/credentials`, `/integrations` | 1–3 | 🟡 Observed in reference repos; the authoritative source is the instance's `/api_docs/v1/openapi.json` |
| AAP gateway API | `/api/controller/v2/…` (through `infra.aap_configuration`); `/api/gateway/v1/…` | 0 | ✅ |
| OPA REST | `POST /v1/data/{path}`, `GET /health` | 1–3 | ✅ [REST API](https://www.openpolicyagent.org/docs/rest-api) |
| PostgREST | `POST /rpc/{function}`, `GET /{view}` | 1–3 | ✅ [docs](https://docs.postgrest.org/) |
| Microsoft Foundry Agent Service | `GET …/agents`, `POST …/agents/{name}:disable` | 3+ (design) | ✅ [docs](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/manage-hosted-agent) |
| Vertex AI Agent Engine | `GET …/reasoningEngines` | 3+ (design) | 🟡 [docs](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/reference/rest/v1/projects.locations.reasoningEngines/list) |

## 4. Credentials

| Credential (AAP / AO / EDA) | Type | Purpose | Stored where |
|---|---|---|---|
| AI Governance - AWS Bootstrap | AAP built-in "Amazon Web Services" | Principal allowed only to assume the governance roles | AAP (optionally sourced from AWS Secrets Manager or Vault via credential plugin) |
| AI Governance - AWS Discovery Role | Custom "AI Governance - AWS Discovery Role" | `role_arn`, `external_id` | AAP |
| AI Governance - AWS Remediation Role | Custom "AI Governance - AWS Remediation Role" | `role_arn`, `external_id` | AAP |
| AI Governance - AWS Demo Reset Role | Custom "AI Governance - AWS Demo Reset Role" | `role_arn`, `external_id`. As built, there is **one credential type per role**: AAP allows only one credential of a given type per job template, which also enforces role separation | AAP |
| AI Governance - Inventory API (discovery / evaluator / remediator / registry / reader / admin) | Custom "AI Governance - Inventory API" | One JWT per PostgreSQL role | AAP |
| AI Governance - OPA | Custom "AI Governance - OPA" | OPA URL (+ token if OPA auth is enabled) | AAP |
| AI Governance - Automation Orchestrator | Custom "AI Governance - Automation Orchestrator" | AO URL, service account client ID and secret | AAP |
| AI Governance - Notification | Custom "AI Governance - Notification" | Webhook URL | AAP |
| AI Governance - OpenShift | AAP built-in "OpenShift or Kubernetes API Bearer Token" | Deploy services, migrations, policy publish | AAP |
| AI Governance - GitHub | AAP "Source Control" | Project sync (if the repo is private) | AAP |
| AI Governance - Hub | AAP "Ansible Galaxy/Automation Hub API Token" | Pull collections | AAP |
| AI Governance - Registry | AAP "Container Registry" | Pull the EE image | AAP |
| AO: AAP connection | AO credential type "Ansible Automation Platform" (username/password or token) for AAP user `svc-aigov-ao` | `aap_job_template` steps | AO |
| AO: LLM provider | AO credential type "LLM Provider" (`api_key`) | `agentic` steps | AO |
| AO: service account `aigov-trigger` | AO OAuth2 client credentials | API-triggered executions, audit capture | AO |
| EDA: AWS SQS | EDA credential (AWS access key or role) | `aws_sqs_queue` source | EDA |
| EDA: AAP | EDA "Red Hat Ansible Automation Platform" credential | `run_job_template` | EDA |

**No secrets in Git. No Ansible Vault files.** (This follows the project standard.)

## 5. Cloud resources (AWS demo account)

Deployed by CloudFormation through `amazon.aws.cloudformation` from `aws/cloudformation/`:

| Stack | Resources |
|---|---|
| `aigov-governance-roles` | `AIGovDiscoveryRole`, `AIGovRemediationRole` (external ID, scoped policies), bootstrap principal permissions |
| `aigov-demo-agents` | Demo agent execution roles (one scoped, one with `AdministratorAccess`, tagged `aigov:managed=true`), approved least-privilege policy `aigov-approved-bedrock-agent-basic`, approved permissions boundary, S3 bucket for the demo KB tagged `DataClassification=restricted`, Lambda for the demo action group, and the agents themselves. **Bedrock agents are created only if the account is allowlisted for Bedrock Agents Classic**; otherwise AgentCore runtimes are used (requires an ECR image, see open questions) |
| `aigov-events` (Stage 3) | EventBridge rules (agent Region and us-east-1), SQS queue, DLQ, queue policy, EDA consumer IAM principal |
| `aigov-evidence` (Stage 3) | S3 evidence bucket (optionally with Object Lock) |

**Prerequisites:**

- CloudTrail enabled (the default management-event trail is sufficient for EventBridge).
- Bedrock model access enabled for the demo model(s).
- AgentCore available in the chosen Region, if used.

## 6. Infrastructure sizing (POC)

| Workload | Replicas | CPU / memory request | Storage |
|---|---|---|---|
| PostgreSQL | 1 | 0.5 vCPU / 1 GiB | 10 GiB PVC |
| PostgREST | 1 | 0.1 vCPU / 128 MiB | — |
| OPA | 2 | 0.1 vCPU / 128 MiB | — |
| Grafana | 1 | 0.2 vCPU / 256 MiB | 1 GiB PVC (optional) |
| OTel Collector (Stage 3) | 1 | 0.2 vCPU / 256 MiB | — |
| AAP execution capacity | existing | ~3 concurrent jobs during the demo | — |
| AO | existing | — | — |

## 7. Development tooling (CI)

| Tool | Purpose |
|---|---|
| `ansible-lint` (production profile), `yamllint` | Ansible and YAML quality; FQCN enforcement |
| `ansible-test sanity` / `units` | Project collection |
| `pytest`, `botocore` Stubber, `moto` (optional) | Custom module unit tests |
| `ruff` | Python lint and format |
| `opa` 1.22.x, `regal` 0.43.0 | Rego format, check, test, lint |
| `check-jsonschema` | Contract and fixture validation; AO rendered JSON structural checks |
| PostgreSQL 16 service container | Migration and SQL tests |
| `ansible-builder` v3 | EE build |
| `pre-commit` | Local hooks mirroring CI |
| GitHub Actions | CI pipelines (see [07-repository-structure.md](07-repository-structure.md)) |

## 8. Network and access prerequisites

- OpenShift namespace `ai-governance` with permission to create Deployments, StatefulSets, Services, Routes, ConfigMaps, Secrets, NetworkPolicies, and Jobs. A service account for AAP is provided.
- AO admin settings: `APP_INTEGRATION_URL_ALLOWED_HOSTS` includes the AAP gateway host, the OPA and Inventory API service hosts, and the LLM endpoint. The setting must apply to ao-backend **and ao-worker**.
- Egress from AAP execution pods to AWS endpoints: `bedrock`, `bedrock-agent`, `bedrock-agentcore-control`, `iam`, `sts`, `sqs`, `cloudformation`, `cloudwatch`, `ce`, `s3`.
- Egress from AO to the LLM endpoint.
