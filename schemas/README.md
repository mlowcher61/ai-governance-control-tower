# Contracts (JSON Schemas)

Every piece of data that moves between the parts of the AI Governance Control Tower has a written
contract here. Discovery jobs, the Inventory API, OPA policies, automation orchestrator and the AI task
agent all agree on these shapes. CI rejects any change that breaks one.

| Contract | What it describes | Produced by | Consumed by |
|---|---|---|---|
| [discovery-record.v1.json](discovery-record.v1.json) | One AI agent as found in the cloud: identity, permissions, tags, tools, data sources, and the **evidence status** of each | Discovery adapters (AgentCore, Bedrock Agents Classic, …) | `api.record_discovery` |
| [registry.v1.json](registry.v1.json) | Owners and agent registrations (the governance registry) | The registry in Git | `api.load_registry` |
| [policy-input.v1.json](policy-input.v1.json) | Everything OPA needs to judge one agent | `api.evaluation_inputs` + the Evaluate job | OPA (`governance.evaluate`) |
| [policy-result.v1.json](policy-result.v1.json) | One policy's decision for one agent: decision, severity, explanation, evidence | Each Rego policy | Aggregate result, findings |
| [evaluation-result.v1.json](evaluation-result.v1.json) | All policy results for one agent, plus the overall status and risk score | OPA | `api.record_evaluation` |
| [findings-for-explanation.v1.json](findings-for-explanation.v1.json) | The **sanitized** findings handed to the AI step | The Evaluate job | WF-01 AI task agent |
| [ai-explanation.v1.json](ai-explanation.v1.json) | The AI's plain-language explanations | WF-01 AI task agent | `api.record_explanations` |
| [artifacts.v1.json](artifacts.v1.json) | What each governance job publishes for automation orchestrator (`set_stats`) | AAP job templates | AO workflows |
| [common.v1.json](common.v1.json) | Shared building blocks (timestamps, evidence values, IAM statements, …) | — | The schemas above |

## Rules the contracts enforce

These rules are written into the schemas, so a broken producer fails CI. Nobody has to remember them:

- **Evidence is explicit.** Each evidence domain is `collected`, `not_collected`, `access_denied`,
  `not_supported` or `error`, and a policy input must state every domain. Missing evidence never means "compliant".
- **No silent compliance.** An evaluation result is `compliant` only when every policy returned `pass` or
  `not_applicable`. Any `fail` forces `noncompliant` (or `error`). Invalid input forces `error`.
- **Risk categories match scores**: critical ≥ 70, high 45–69, medium 20–44, low < 20.
- **Only failures carry a remediation.**
- **The AI cannot decide anything.** An AI explanation has no decision, severity or risk field, and extra
  fields are rejected. The findings sent to the AI exclude owner-controlled free text (tags, descriptions),
  and agent names are limited to safe characters. This keeps prompt-injection text out of the prompt.
- **Dates in policy inputs are RFC 3339 timestamps**, so policies can compare them with the evaluation time.

## Fixtures for the four demo agents

`policies/fixtures/` holds the reference data for the demo scenario. It mirrors the CloudFormation in
`aws/cloudformation/aigov-demo-agents.yaml` (the account ID is the placeholder `111122223333`):

| Agent | Execution role policy | Registry | Expected outcome (once the policies exist, T1.08) |
|---|---|---|---|
| `payments_dispute_assistant` | Approved least-privilege policy | REG-0001: approved owner, approved model declared, risk assessment and sensitive-data approval current | compliant |
| `quick_helper_bot` | **AdministratorAccess** | **Not registered** | noncompliant, critical risk |
| `hr_faq_agent` | Approved policy | REG-0002: **risk assessment expired** on 2026-06-01 | noncompliant (risk assessment) |
| `research_runtime` | Approved policy | REG-0003: **no model declared** (AgentCore cannot report it) | unknown (model) |

- `discovery/<agent>.json`: what discovery sends to the Inventory API.
- `registry.json`: the registry that goes with them.
- `inputs/<agent>.json`: the exact policy input the Inventory API produces from the two files above, plus
  the evaluation block. `database/tests/test_contracts_api.py` proves this against a real database in CI.

## Changing a contract

- Contracts are versioned in the file name. **Adding an optional field** is allowed in place. **Removing or
  renaming a field, or making one required,** needs a new version (`*.v2.json`) and a migration plan for
  every producer and consumer listed above.
- Add a valid example, and an invalid one for any new rule, under `examples/<contract>/{valid,invalid}/`.
  For artifacts, use `examples/artifacts/<job>/`.
- Run the tests:

  ```bash
  pip install "jsonschema>=4.18" pytest
  python -m pytest -q schemas/tests        # schemas, fixtures, examples
  database/tests/run_local.sh              # adds the database contract test (needs podman or docker)
  ```
