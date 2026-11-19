# mlowcher61.ai_governance

Project collection for the [AI Governance Control Tower](../../../../README.md).

It contains **only** content that certified collections do not provide. Each module documents the
verified content gap that justifies it (see `docs/plan/06-technical-dependencies.md`).

| Module | Type | Purpose |
|---|---|---|
| `iam_role_permissions_info` | read-only | The full permission picture of an IAM role: trust policy, tags, **documents** of attached managed policies, inline policies and the permissions boundary, normalized to the contract `identity` shape. No certified module returns managed policy documents or the boundary |
| `bedrock_agent_details_info` | read-only | Bedrock Agents Classic details missing from `amazon.ai` 1.0.1: tags, guardrail, KMS key, knowledge bases with their S3 data sources and bucket classification, collaborators. Never returns the agent instruction |
| `iam_policy_simulation_info` | read-only | `iam:SimulatePrincipalPolicy` checks with expected outcomes (negative tests, remediation verification), and the contract `simulation` map for discovery |
| `jwt_hs256` | utility | Signs the Inventory API tokens (HS256, standard library only) |

**Evidence, not failure.** The read modules never treat a permission problem as "nothing found". Each
returns `evidence_status` (`collected`, `access_denied`, `error`, …) per evidence area, plus an `errors`
list, so the discovery run records the gap and the policies return `unknown` instead of `pass`.
`iam_policy_simulation_info` does this with `on_error: report`; by default it fails, which is right for
verification jobs.

Shared code lives in `plugins/module_utils/`: `evidence.py` (AWS error to evidence status) and
`iam_normalize.py` (IAM documents to the contract statement shape).

Tests: unit tests use the botocore Stubber, so they run without AWS
(`cd collections && PYTHONPATH=$PWD python -m pytest ansible_collections/mlowcher61/ai_governance/tests/unit`).
`ansible-test sanity --venv --python 3.12` runs from the collection directory. Both run in CI.

Planned: `agentcore_runtime_info` (T1.06, until a certified `amazon.ai` 2.x is on the hub),
`bedrock_agent_alias_state` and `bedrock_agent_tags` (Stage 2).

The collection is installed into Ansible Automation Platform projects from the repository itself
(`collections/requirements.yml`, `type: dir`).
