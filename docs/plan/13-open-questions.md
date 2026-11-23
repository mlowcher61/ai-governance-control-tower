# 13 — Open Questions, Assumptions, and Decisions

Items marked **🔑 DECISION** need your approval before implementation starts. Each has a recommendation.

---

## 1. Key decisions requiring approval

| ID | Question | Options | Recommendation | Impact if undecided |
|---|---|---|---|---|
| **Q-01 ✅ RESOLVED** | Which AWS account hosts the demo, and is it allowlisted for **Bedrock Agents Classic**? The service went into maintenance mode on 2026-07-30. New accounts get HTTP 403 on `CreateAgent`, and there is no exception process. | (a) An existing account with Bedrock Agents activity in the past 12 months. (b) A new account using **AgentCore** runtimes for the demo. (c) Both. | **Decided: (b) AgentCore.** The user has never used Bedrock Agents, so `CreateAgent` will be denied. The Classic adapter stays as P1 (unit-tested with stubs) for customer estates that have existing Classic agents. | — |
| **Q-02 ✅ RESOLVED** | Stage 1 platform scope | Classic only / AgentCore only / both | **AgentCore is P0 (demo); the Classic adapter is P1** (stub-tested only, because the demo account cannot host Classic agents) | — |
| **Q-03 ✅ RESOLVED** | If AgentCore is used, how is the demo runtime created? A runtime needs an agent artifact (container image in ECR, or the AgentCore managed harness). | Harness via AgentCore CLI / minimal container | **Managed harness**, scripted once, with the resulting runtime referenced by CloudFormation outputs **Resolved (T0.07):** the managed harness is not available in us-west-1, so the four demo runtimes use AgentCore direct code deployment (`CodeConfiguration`, stdlib `main.py` from S3). No container image is needed. | T0.07 +1 ED |
| **Q-04 ✅ RESOLVED** | **LLM provider** for AO agentic steps. Note: AO's list of supported providers was not found in the docs reviewed. | (a) Red Hat AI Inference Server / OpenShift AI model (an all-Red-Hat story). (b) LiteLLM proxy to Claude on Amazon Bedrock (used in `ao_demo_config`). (c) Customer's existing provider. | **Decided: the existing AO credential "LiteMaaS API Key" with model `llama-scout-17b`** (Red Hat-hosted MaaS, already used by "Compliance as Code - Golden Image (as code)"). See Q-27 for the structured-output risk | — |
| **Q-05 ⚙️ DEFAULT ADOPTED** | **Inventory API approach.** No certified PostgreSQL module collection exists. | (a) **PostgREST** (MIT, community) in front of PostgreSQL. (b) `community.postgresql` (Galaxy community) from playbooks. (c) A custom FastAPI service. | **(a) PostgREST** (user unsure; see §1.1). Can be revisited before T1.02 | — |
| **Q-06 ✅ RESOLVED** | **Target environment.** The connected AAP reports controller 4.8.13 (AAP 2.7). Is AO installed there, and is this the POC environment? Integrated or standalone AO? | — | **Confirmed:** AAP 2.7 at `<aap-gateway-host>` and AO at `<ao-route-host>` (same cluster). See [environment-validation.md](environment-validation.md) | — |
| **Q-07 ✅ RESOLVED** | Can governance services (PostgreSQL, PostgREST, OPA, Grafana) run in a new namespace on the same OpenShift cluster? | Same cluster / separate | Same cluster, namespace `ai-governance` **Resolved (T0.06, AAP job 1289):** same cluster as AAP and AO, namespace `ai-governance`. | T0.06 |
| **Q-08 ⚙️ DEFAULT ADOPTED** | **Remediation scope control.** The remediation role may modify only IAM roles tagged `aigov:managed=true` (or under path `/aigov-agents/`). | Tag / path / both | **Tag `aigov:managed=true`** (user unsure; see §1.1). Can be revisited before T0.07 | — |
| **Q-09** | Who are the **approvers**: AAP usernames for the demo security-approver persona? | — | Two named users (primary and backup), neither of them the demo agent owner | T2.09 |
| **Q-10** | **Notification channel** | Slack / Teams / email / ServiceNow incident | Generic webhook (Slack or Teams) for the POC; ServiceNow in Stage 3 if desired | T2.10 |
| **Q-11 🔑** | **Rollback and demo reset of high-risk states.** The remediation role is denied from attaching non-approved policies (such as `AdministratorAccess`). | (a) Rollback that would re-introduce admin rights is manual by design; demo reset uses a separate `AIGovDemoResetRole` restricted to demo-tagged roles. (b) A break-glass credential for automated rollback | **(a)** | T2.08, T1.13 |
| **Q-12** | **Approved model list** and the **approved least-privilege policy** for the demo agent class | — | Customer-supplied list; a demo default is proposed in T0.07 | T1.08, T0.07 |
| **Q-13** | **Tag taxonomy.** Required production tag keys and allowed data-classification values | Proposed: `Owner`, `Environment`, `DataClassification`, `CostCenter`; classifications `public`, `internal`, `confidential`, `restricted` | Use the proposal unless the customer has a standard | T1.08 |
| **Q-14** | **Evidence storage.** S3 bucket, Object Lock (compliance mode), retention period | — | S3 with Object Lock in a separate stack; 7-year default retention, configurable | T3.08 |
| **Q-15 ⚙️ PARTIAL** | **Grafana** licensing and access. Grafana OSS is licensed AGPLv3. SSO via OpenShift OAuth proxy or OIDC? | OSS / customer's Grafana Enterprise / existing Grafana | Grafana OSS for the POC; reuse the customer's Grafana if one exists; OIDC SSO **Status:** Grafana OSS 13.3.1 is deployed behind an edge-TLS Route with a local admin account (Secret `ai-governance/grafana-admin`). SSO is still open. | T0.06, T3.06 |
| **Q-16** | **Unknown environment treatment.** Default `assume_production` (fail-closed) vs `unknown` | — | `assume_production`, with the assumption shown on each result | T1.08 |
| **Q-17** | **Product naming in docs.** Your `ao_demo_config` naming rule says lowercase "automation orchestrator" (never title case); the request text uses "Red Hat Automation Orchestrator". | Lowercase rule / title case | Lowercase in running text, "AO" as the abbreviation; confirm the official style | Docs only |
| **Q-18** | Repository name and **collection namespace** | `github.com/mlowcher61/ai-governance-control-tower`; collection `mlowcher61.ai_governance` | As proposed | T0.03 |
| **Q-19** | May the **AAP policy-as-code feature flag** (`FEATURE_POLICY_AS_CODE_ENABLED`) be enabled in the customer's AAP 2.7? Its support status in 2.7 must be confirmed. | — | Enable in the demo environment only, as a P1 defense-in-depth layer | T2.11 |
| **Q-20** | **AWS bootstrap authentication** for AAP | IAM user access keys / IAM Roles Anywhere / OIDC federation | Access keys for the POC (only `sts:AssumeRole`, rotated); Roles Anywhere or OIDC for production | T0.07 |
| **Q-21 ⚙️ PARTIAL** | Are **community container images** (OPA, PostgREST, Grafana) acceptable? Is mirroring to an internal registry required? | — | Pin by digest; mirror if the cluster image policy requires it **Status:** the cluster pulls `postgrest/postgrest:v16.6`, `openpolicyagent/opa:1.22.4-static` and `grafana/grafana:13.3.1` from docker.io without a mirror. Images are pinned by tag, not yet by digest. | T0.06 |
| **Q-22** | Is **OpenTelemetry / Tempo** available on the cluster, for example the Red Hat build of OpenTelemetry and distributed tracing? | — | Treat as P1; dashboards do not depend on it | T3.09 |
| **Q-23** | Should Stage 3 include **ServiceNow integration** (findings to incidents, evidence attachment)? | — | Optional P2; a strong message for joint customers | Roadmap |
| **Q-25 ✅ RESOLVED** (service account `ai-service-account` via `AO_CLIENT_ID`/`AO_CLIENT_SECRET`, project-admin in AO project `default`; runtime calls use `aigov-trigger`, see T0.08) | **AO credential for automation.** AO does not accept the AAP token (verified: 401). The workflow loader, the reference export, and EDA-triggered runs need AO API access | (a) Create an AO **service account** (client ID and secret) and export `AO_CLIENT_ID` / `AO_CLIENT_SECRET`. (b) Provide the AO admin password as `AO_PASSWORD` for the POC | **(a) service account**, scoped to the governance project. (b) is acceptable for the initial reference export only | Blocks T0.02 export, T0.08 |
| **Q-26 🔑** | **AWS account for the demo.** AAP has two `AWS` credentials. Which account and Region should be used, and may governance roles plus demo AgentCore resources be created there? | — | A dedicated sandbox account; a Region where AgentCore is available (for example us-east-1 or us-west-2) | Blocks T0.07 |
| **Q-27 ⚙️ PARTIAL** | **`llama-scout-17b` structured output.** Can it reliably return JSON matching `responseSchema`? | — | Test in the T0.02 spike. The design already tolerates AI failure: deterministic explanations remain authoritative, the AI step uses `continue_on_failure`, and invalid AI output forces approval. Fallback: a larger MaaS model if one is available **Status (2026-11-19):** a single-step structured-output test passed (execution `fb83e168`, schema-valid JSON). Reliability on the full WF-01 explanation schema is tested in T1.11. **Status (2026-11-20):** WF-01 execution `98433f4f` returned 9 of 9 schema-valid explanations with the exact finding IDs and only the allowed next steps. | Explanation quality only |
| **Q-24** | Should **IAM Access Analyzer** findings (unused access, custom policy checks) feed policies? Some analyzer types are paid features. | — | Defer; `SimulatePrincipalPolicy` and static analysis suffice for the POC | — |

### 1.1 Plain-language guidance on the two "not sure" items

**Q-05: Inventory API.** Playbooks and AO need to save and read inventory records (agents, findings, approvals) in PostgreSQL. There are three ways:

- **PostgREST (recommended, adopted):** a small open-source container that automatically turns database tables and functions into a REST/JSON API.
  - Ansible uses the built-in `ansible.builtin.uri` module, so no extra collection is needed.
  - AO's REST step can read from it directly.
  - Permissions are enforced per caller in the database itself: for example, the discovery job cannot touch approvals.
  - The project writes zero API code.
- **`community.postgresql`:** Ansible modules that run SQL directly. Simple, but the collection is community content (not certified), every playbook needs database credentials, and AO cannot use it.
- **A custom API service:** the most flexible option, but it is a new piece of software to write, test, and maintain. That is too much for a POC.

**Q-08: Remediation scope.** This controls which IAM roles the automation is *allowed* to change when it fixes an agent. With **tag-based scope (adopted)**, the remediation AWS role can only modify IAM roles carrying the tag `aigov:managed=true`. Two consequences:

- Even a bug or a bad policy change cannot touch unrelated roles in the account, such as admin users or application roles.
- Bringing an agent under automated remediation is a deliberate, auditable act: someone adds the tag.

The demo agent's role is tagged by the demo CloudFormation stack. The alternative, an IAM path such as `/aigov-agents/`, works similarly, but a role's path cannot be changed after creation, which makes it impractical for existing customer roles.

### 1.2 Decisions made during implementation (2026-11-19 to 2026-11-22)

Details and evidence are in [../progress-log.md](../progress-log.md).

| Decision | Choice | Why |
|---|---|---|
| Risk category bands | **low 0-20, medium 21-44**, high 45-69, critical 70+ (was medium 20-44) | §8 of the Stage 1 plan expects the payments agent (score 20) to be low. User decision |
| Rego library ([ynotbhatc/rego_policy_libraries](https://github.com/ynotbhatc/rego_policy_libraries)) | **Hybrid**: our own library and per-agent policies; the library's control IDs (CIS AWS v7, ISO 42001, EU AI Act, OWASP LLM, NIST AI RMF) cited in each result, pinned to commit `9d26ac4`; a Stage 3 roll-up into its framework modules | The library evaluates organization attestations and AI actions, not individual cloud agents, and uses a different input/output format. User decision |
| Policy test environment | `opa check` / `opa test` run in a Kubernetes Job with the **server's own OPA image**, not in the EE | No EE rebuild; tests run on exactly the OPA version that serves the policies |
| AO SSRF allowlist | Set through the **`ao-admin-settings` ConfigMap** (job *Configure AO Network Allowlist*), merged with existing hosts | The AO UI could not give any service account the system admin role needed to change settings through the API. User approved |
| Shared `aigov_` variables in collection roles | ansible-lint rule `var-naming[no-role-prefix]` skipped | Credentials inject `aigov_*` variables and the roles exchange data through them |
| Credentials whose secrets are written by jobs | Config as code sends the full key set (Inventory API tokens) or only creates the credential (`state: exists`, AO trigger) | Otherwise a config-as-code re-run patches the secrets away (found twice) |
| Regal (Rego linter) | **Not added** | Downloading and running it was blocked by the permission checker; correctness is covered by strict compile, unit tests and golden decisions |
| Remediation approval scope (T2.01) | Approval for **every environment except development and sandbox** (unknown counts as production), and for actions the catalog marks not automatically eligible | Fail-closed, like the governance policies; the plan required approval for production only |
| Remediation profiles | Committed default **detect_only**; demo profile `policies/overlays/demo/remediation.json` applied at publish time with the account filled in | Remediation cannot be switched on by a commit alone; the account ID never lives in Git |
| Q-12 / Q-13 / Q-16 defaults | Adopted in `policies/data/governance/config/data.json`: approved models `amazon.nova-pro-v1:0`, `amazon.nova-lite-v1:0`, `anthropic.claude-3-5-haiku-20241022-v1:0`; tags `Owner`, `Environment`, `DataClassification`, `CostCenter`; `assume_production` | Proposed defaults; customers change them in `data.json` |
| Approvals before WF-02 exists | **Record approvals with the interim AAP job Record Approval Decision** (admins only) rather than waiting for the AO approval step; the AO approval comes with WF-02 (T2.09) and T2.10 makes the job read decisions from the AO approvals API | Lets Execute Remediation be tested on its own now. User decision (2026-11-22); the user recorded the first approval (job 316) |
| Remediations stranded by failed WF-02 runs | **Record the user's AO decision from AO, then execute, verify and record each with the AAP jobs; reset the demo and run WF-02 on fresh findings** | The approvals were real (given in AO), so finishing them keeps the record honest. User decisions (2026-11-22) |
| WF-02 notification channel | **ServiceNow incidents** (one per finding, certified `servicenow.itsm`), credential AI Governance - ServiceNow | User decision (2026-11-22). Outcomes that need a person open or update the incident; a verified fix resolves it |
| Stage 2 failure-suite approach (T2.12) | **F-09 through a CloudFormation test switch** (`TestFaultDenyDetach`, default off); **F-04 through a separate AO test credential and probe workflow**; **F-08 with a short-window test copy** (in the end shown on the real 1-hour window); **F-18 deferred to T2.11** | User decisions (2026-11-22) |

## 2. Assumptions

1. AAP 2.7 is the execution platform. The solution is not intended for standalone ansible-core.
2. AO 2026.8 runs on OpenShift in the same cluster as AAP (integrated deployment), and it can reach the AAP gateway, OPA, and the Inventory API once they are SSRF-allowlisted.
3. The demo is run only in a controlled demo AWS account. No customer production systems are touched.
4. One AWS account and one or two Regions for the POC. IAM rules live in us-east-1.
5. CloudTrail management events are enabled (the default) in the demo account.
6. The engineering team has the access listed in [12-implementation-roadmap.md §1](12-implementation-roadmap.md#1-estimating-assumptions).
7. Governance registry data (owners, registrations, risk assessments) is supplied as YAML by the customer or demo team. No GRC system integration in the POC.
8. Approved-model and approved-policy lists are customer-provided. Values in the plan are placeholders.
9. AI explanation quality is "good enough to help". Decisions never depend on it.
10. The reference AO behaviors observed in `ao_demo_config` and `sales.demos` (API paths, node types, expressions) hold for the target AO build. This is validated in T0.02.

## 3. Licensing and subscription requirements

| Item | Requirement | Notes |
|---|---|---|
| Red Hat Ansible Automation Platform 2.7 | Subscription | Includes EDA and private automation hub |
| automation orchestrator | **Paid add-on** to AAP 2.7+ subscriptions (🟡 Red Hat blog) | Confirm entitlement for the demo environment |
| Red Hat OpenShift | Subscription | AO is OpenShift-only |
| Red Hat build of OpenTelemetry | Included with OpenShift (🟡) | Stage 3 P1 |
| Certified and validated collections | Included with AAP | Pulled from the private automation hub |
| OPA | Apache 2.0, community | Not Red Hat supported |
| PostgREST | MIT, community | Not Red Hat supported |
| Grafana OSS | **AGPLv3**, community | Review with the customer's legal team if they distribute modifications; using it unmodified internally is typical |
| PostgreSQL (Red Hat image) | Included with RHEL / OpenShift entitlements (🟡) | Or a customer-managed service |
| AWS | Pay-as-you-go | Bedrock inference for the demo agent, Lambda, S3, CloudTrail (management events free for the first copy; data events billed if enabled), SQS, CloudWatch, Cost Explorer API requests (billed per request). **No pricing figures are included in this plan.** |
| LLM for AO agentic steps | Depends on provider | Token-based cost |
| ISO/IEC 42001 text | Licensed standard | Needed to finalize exact Annex A control mappings |

## 4. Unverified items register

Each item has an owner task. Items are re-checked before dependent work starts.

| # | Item | Status | Resolved in |
|---|---|---|---|
| U-01 | AO workflow import/export format | ✅ **Resolved**: OpenAPI 1.3.0 `WorkflowDefinition` plus `/versions/{v}/export` | environment-validation.md |
| U-02 | AO trigger input expression syntax | ✅ **Resolved**: `${trigger.<field>}` (runtime-proven in the reference export) | environment-validation.md §2.2 |
| U-03 | AO OR-join semantics | ✅ **Avoided**: use an explicit `converge` node with `strategy: any` | environment-validation.md |
| U-04 | AO behavior when an `agentic` node fails | ✅ **Mitigated**: `settings.continue_on_failure: true` on agentic nodes (OpenAPI) | environment-validation.md |
| U-05 | AO approval timeout configurability | ✅ **Resolved**: `decision_window` (seconds) plus `fallback_decision` | environment-validation.md |
| U-06 | AO execution ID available as an expression | 🟡 Not found. Approval output `decided_by` and job output `job_id` cover the audit needs | environment-validation.md §2.2 |
| U-07 | AO `http_request` response path | ✅ **Resolved**: `${<node>.body.result.*}` and `${<node>.body.decision_id}` (runtime-proven) | environment-validation.md §2.2 |
| U-08 | AO-supported LLM providers and MCP transports | ❓ | T0.01 / T0.08 |
| U-09 | Which AO item the Technology Preview disclaimer on the install page applies to | ❓ | T0.01 |
| U-10 | AO GA date (sources conflict: 2026-08-21, 2026-09-18, 2026-10-14) | ❓ | Informational |
| U-11 | `/api/eda/v1` path behind the 2.7 gateway (used by `infra.aap_configuration`) | 🟡 | T0.05 |
| U-12 | AAP policy-as-code feature support status in 2.7 | 🟡 | T2.11 |
| U-13 | EventBridge `source` and CloudTrail `eventSource` values for Bedrock Agents and AgentCore management events | ❓ | T3.01 |
| U-14 | Whether DRAFT action group changes reach aliases on numbered versions (assumed: no) | ❓ | T2.06 |
| U-15 | Exact IAM action names and condition keys for AgentCore reads and Bedrock agent resources | ❓ | T0.07 |
| U-16 | `ansible.eda.aws_sqs_queue` event structure (`event.body` parsed) in the AAP 2.7 decision environment; `aiobotocore` presence in `de-supported` | 🟡 | T3.02 |
| U-17 | EDA project rulebook directory layout accepted by the AAP 2.7 scanner | 🟡 | T3.02 |
| U-18 | Red Hat build of OTel receivers (`awscloudwatch`, `sqlquery`) | ❓ | T3.09 |
| U-19 | NIST AI RMF subcategory-level mappings; ISO/IEC 42001 Annex A exact wording | 🟡 / ❓ | T3.08 (compliance review) |
| U-20 | ServiceNow rename to "Super Intelligence Control Tower" and the AI Passport GA date | 🟡 | Informational (refresh before customer use) |
| U-21 | AAP 2.7 documentation pages (docs.redhat.com returned HTTP 403 to automated fetch; content taken from search snippets) | 🟡 | Manual review during T0.01 |

## 5. Research limitations

- **docs.redhat.com** blocked automated fetching (HTTP 403), and the AAP documentation RAG endpoint returned server errors. Red Hat documentation claims are therefore 🟡 unless they were confirmed in source code (GitHub tags) or in the working reference repositories.
- **Collection module lists** were verified directly from GitHub release tags matching the versions on your private automation hub (✅).
- **AWS maintenance-mode status** for Bedrock Agents Classic was verified directly on the AWS documentation page (✅).
