# mlowcher61.ai_governance

Project collection for the [AI Governance Control Tower](../../../../README.md).

It contains **only** content that certified collections do not provide. Each module documents the
verified content gap that justifies it (see `docs/plan/06-technical-dependencies.md`).

| Module | Type | Purpose |
|---|---|---|
| `iam_policy_simulation_info` | read-only | Run `iam:SimulatePrincipalPolicy` checks with expected outcomes (negative tests, remediation verification) |

Planned (Stage 1/2): `agentcore_runtime_info`, `bedrock_agent_details_info`, `iam_role_permissions_info`,
`bedrock_agent_alias_state`, `bedrock_agent_tags`.

The collection is installed into Ansible Automation Platform projects from the repository itself
(`collections/requirements.yml`, `type: dir`).
