# automation orchestrator workflows as code

This directory holds the governance workflows for automation orchestrator (AO). It also holds the playbooks that configure AO and load the workflows.

| Path | What it is |
|---|---|
| `definitions/*.yml` | Workflow files, written **by name**. This is the source of truth; never edit the AO canvas copy. |
| `config/connections.yml` | Names of the AO project, integrations, credentials, LLM model, trigger service account, and SSRF allowlist hosts. |
| `config/approvers.yml` | AAP usernames allowed to decide approvals. |
| `configure_ao.yml` | Config as code for AO. It checks the integrations and credentials, creates the `aigov-trigger` service account, and checks the SSRF allowlist. |
| `apply_workflows.yml` | The loader. It renders each file, validates it with AO, then creates or updates it and publishes it. |
| `run_workflow.yml` | Starts a workflow by name, waits for it to finish, and fails unless it completed. |
| `tasks/` | Shared tasks: AO login, name-to-ID lookups, applying one workflow, and issuing the trigger credential. |
| `reference/` | The AO OpenAPI document and a runtime-proven reference export (T0.02). |

## Why the workflow files use names, not IDs

An AO export embeds values that exist only in the environment it came from:

- AO credential and integration UUIDs
- AAP job template IDs
- approver usernames (`admin-<hash>`)

If you import an export into another environment, those values are wrong. So the files in `definitions/` use names, and the loader resolves them to IDs at load time:

| In the file | Resolved through |
|---|---|
| `job_template:` | `GET /api/v1/proxies/aap/job_templates`. These are the IDs AO itself launches. |
| `credential:` / `llm_credential:` | `GET /api/v1/credentials` |
| `integration:` / `llm_integration:` | `GET /api/v1/integrations` |
| `llm_model:` | `GET /api/v1/integrations/{id}/models` |
| approvers | `GET /api/v1/users`, matched on `<aap-username>-<hash>` |

The resolver is the filter plugin `mlowcher61.ai_governance.ao_render_workflow`. It has unit tests in the project collection.

## Writing a workflow file

```yaml
name: AI Governance - Something (as code)   # always end with "(as code)"
description: What it does
publish: true
triggers:                                    # AO's own trigger shape
  - id: trigger_manual
    name: Start
    type: manual_trigger
    parameters: {input_schema: {type: object, properties: {governance_run_id: {type: string}}}}
nodes:
  - id: activity_discover                    # node IDs: activity_*, logic_*, approval_*, trigger_*
    name: Discover Agents
    type: aap_job_template
    job_template: AI Governance - Discover AI Agents
    extra_vars: {governance_run_id: "${trigger.governance_run_id}"}
    settings: {timeout: 1800}
  - id: activity_explain
    name: Explain Findings
    type: agentic
    prompt: ...
    response_schema: {type: object, ...}
    settings: {continue_on_failure: true}
  - id: logic_route                          # any other node type: parameters are passed through as written
    name: Route
    type: switch
    parameters: {cases: [{port: case_0, condition: "${opa_gate.body.result.route} == 'auto'"}]}
edges:
  - {from: trigger_manual, to: activity_discover}
```

Rules that AO enforces at run time, even though `/workflows/validate` accepts the violations:

- Expressions reference **node IDs**, not display names.
- Compare strings or numbers, never bare booleans (`== 'true'`, not `== true`).
- Read trigger input with `${trigger.<field>}`, REST output with `${<node>.body.<field>}`, job artifacts with `${<node>.artifacts.<field>}`, and agent output with `${<node>.result.content.<field>}`. These are all proven in `reference/`.

A workflow counts as importable **only** after AO validates it **and** a test execution completes (see `docs/plan/07`).

## Running it

### From a workstation

```bash
export AO_URL=https://<ao-route-host>
export AO_CLIENT_ID=<service-account client id> AO_CLIENT_SECRET=<secret>
export AAP_SERVER=<aap-gateway-host> AAP_API_TOKEN=<token>   # only needed to store the trigger credential in AAP

ansible-playbook ao_workflows/configure_ao.yml
ansible-playbook ao_workflows/apply_workflows.yml                     # all definitions
ansible-playbook ao_workflows/apply_workflows.yml -e aigov_ao_validate_only=true
ansible-playbook ao_workflows/run_workflow.yml -e 'aigov_ao_workflow_name="AI Governance - Loader Test (as code)"'
```

### From AAP

Set `aigov_ao_url` in `aap_config/vars/customer.yml` and run `aap_config/configure_aap.yml`. It creates the following:

- the credential type and credential **AI Governance - Automation Orchestrator**. This holds the AO URL and the client ID and secret for `aigov-trigger`.
- the job templates **AI Governance - Configure Automation Orchestrator** and **AI Governance - Apply AO Workflows**.

## The trigger service account (`aigov-trigger`)

AAP jobs use `aigov-trigger` to start governance workflows and to read executions and approvals. `configure_ao.yml` handles it as follows:

1. It creates the service account in the AO project, if the AO identity it runs as is allowed to.
2. If the account has no active client credential, it issues one. It writes the client ID and secret **straight into** the AAP credential *AI Governance - Automation Orchestrator* (with `no_log`). AO shows a secret only once, and this playbook never prints it.

Step 2 needs AAP API access (`AAP_SERVER` and `AAP_API_TOKEN`), and the AAP credential must already exist. To rotate the credential, disable the old one in AO and re-run the playbook.

## Items only an AO administrator can do

`configure_ao.yml` never fails because of missing AO permissions. Instead, it lists the open items under `action_required`. Typical items:

- **SSRF allowlist.** `APP_INTEGRATION_URL_ALLOWED_HOSTS` must contain `opa.ai-governance.svc`, `governance-api.ai-governance.svc`, and the AAP gateway host. The setting must also reach the **ao-worker** pods, not only ao-backend.
- **LLM integration health.** If the integration reports `error` (for example HTTP 401), renew its API key in AO.
- **Service account permissions.** A new service account gets only the roles an AO administrator assigns. `aigov-trigger` needs these roles in the governance project:
  - workflow read and run
  - execution read
  - approval read
  - credential use

Run `configure_ao.yml -e aigov_ao_strict=true` to fail while any item is still open.
