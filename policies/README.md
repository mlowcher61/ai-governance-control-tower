# Governance policies (OPA / Rego)

These policies decide whether each discovered AI agent complies with your AI governance rules. They run in
**Open Policy Agent (OPA)** on OpenShift. The Evaluate job (T1.10) sends one **policy input** per agent
(`schemas/policy-input.v1.json`) and stores the answer (`schemas/evaluation-result.v1.json`).

> **AI explains, policy decides.** Only these policies make decisions. The AI step later explains the
> findings in plain language, but it cannot change a decision, a severity or a risk score.

## The 10 policies

| Policy | Rule | Severity | Applies to |
|---|---|---|---|
| AIGOV-REG-001 | Every AI agent is registered in the governance registry (otherwise it is a **shadow agent**) | high | all |
| AIGOV-OWN-001 | Production agents have an approved owner | high | production |
| AIGOV-TAG-001 | Production agents carry the required tags with valid values | medium | production |
| AIGOV-IAM-001 | No unrestricted administrator permissions on the agent's execution role | critical | all |
| AIGOV-IAM-002 | Dangerous permissions (for example `iam:PassRole`, `s3:*`) are flagged for review | high | all |
| AIGOV-DATA-001 | Agents that touch sensitive data have a current data-governance approval | high | all |
| AIGOV-MDL-001 | Agents use only approved foundation models | medium | all |
| AIGOV-RSK-001 | Production agents have a completed, unexpired risk assessment | high | production |
| AIGOV-TOOL-001 | High-risk built-in tools (code interpreter, computer use, ...) are explicitly approved | high | all |
| AIGOV-GRD-001 | Production Bedrock Agents Classic agents have a guardrail | medium | production, Classic |

Each policy answers `pass`, `fail`, `unknown` or `not_applicable`, with a plain explanation and the evidence.

- **Missing evidence is never compliant.** If discovery could not collect what a policy needs (for example
  AccessDenied on the execution role), the policy answers `unknown`, and the agent cannot be compliant.
- **Unknown environment means production.** An agent with no `Environment` tag and no registry environment
  is judged as production (fail-closed), and the result says so (`environment_assumed_production`).
- **Not exposed means not applicable.** When the platform does not expose something at all (AgentCore
  runtimes have no tools or guardrails in their control plane), the policy answers `not_applicable`.
- **Risk score**: points per finding (weights in `data.json`). Categories: critical 70 or more, high 45-69,
  medium 21-44, low 20 or less. Unknown results add points, so incomplete evidence raises risk.

## Remediation authorization (Stage 2)

Two more policies decide whether a finding may be **fixed** automatically:

- `governance/remediation/authz.rego` (`POST /v1/data/governance/remediation/authz/decision`): is the finding eligible
  (remediation enabled, account allowlisted, a violation, attempts and cooldown, not exempt)? Which catalog action fits
  the policy and platform? Must a human approve (production or unknown environment, medium or high impact, critical
  severity, or an action not on the automatic list)?
- `governance/remediation/route.rego` (`POST /v1/data/governance/remediation/route/decision`): `halt`, `simulate`,
  `approval` or `auto`. Anything uncertain (the AI disagrees or its output is invalid, or the role may be shared) forces approval.

The **action catalog** (`data/governance/remediation_catalog/data.json`) lists every remediation the solution can
perform, with its impact and whether it is reversible. **`data/governance/policy_actions/data.json`** maps each policy
to the actions that fix it. It is also the source of the `action_types` in each failing result.

**Remediation is off in the committed settings** (`remediation.enabled: false`, `mode: detect_only`); a test enforces
this. To demonstrate remediation, publish with `aigov_policy_profile: demo`. That applies `overlays/demo/remediation.json`
and allows only the account in `aigov_aws_account_id`. The publish job always runs the tests against the committed settings; the profile changes only
the policies that are served, and the job checks the live remediation settings after publishing.

## Files

| Path | What it is |
|---|---|
| `governance/lib/lib.rego` | Shared helpers: evidence checks, effective environment, date comparisons, data sensitivity, the result builder |
| `governance/policies/*.rego` | The 10 policies, one file each |
| `governance/risk.rego` | The risk score |
| `governance/evaluate.rego` | The entry point: `POST /v1/data/governance/evaluate/result` |
| `data/governance/config/data.json` | **Your settings**: approved models, required tags, sensitive classifications, administrator policies, dangerous actions, risk weights and category thresholds, control IDs |
| `governance/remediation/` | Remediation authorization and routing (Stage 2) |
| `tests/*_test.rego` | Unit tests (84) |
| `fixtures/inputs/`, `fixtures/expected/` | The four demo agents and their **golden decisions** |

## Control mapping

Every result lists the controls it provides evidence for (`controls`), from `data.json`. The identifiers follow
the open-source [rego_policy_libraries](https://github.com/ynotbhatc/rego_policy_libraries) project, pinned to
commit `9d26ac4`: CIS AWS Foundations v7 (section 7, Amazon Bedrock), ISO/IEC 42001, the EU AI Act, OWASP Top 10
for LLM applications, and NIST AI RMF. For example, AIGOV-IAM-001 automates **CIS AWS v7 7.1.3, "Bedrock agent
roles are least privilege"**, which CIS lists as a manual check. That library evaluates organization-level
attestations rather than individual agents, so it is used for these identifiers, not as policy code.

## Changing the policies

1. Edit the settings in `data/governance/config/data.json`, or a policy in `governance/policies/`.
2. Test locally ([OPA 1.22.4](https://github.com/open-policy-agent/opa/releases/tag/v1.22.4), the version the server runs):

   ```bash
   opa fmt --write policies/
   opa check --strict policies/governance policies/data policies/tests
   opa test --coverage --threshold 90 policies/governance policies/data policies/tests
   python3 scripts/golden_decisions.py            # the demo agents still get the expected decisions
   python3 scripts/golden_decisions.py --update   # only after an intended change; review the diff
   ```

3. Commit and push. CI runs the same checks.
4. Sync the project in AAP and run **AI Governance - Publish Governance Policies**. It:
   - runs `opa check --strict` and the tests in a Kubernetes Job with the **same OPA image as the server**,
     and **refuses** the bundle when anything fails (the live policies are not touched);
   - replaces the policies, restarts OPA (only when something changed), and stamps the Git commit;
   - asks the live server to evaluate the four demo agents and requires the golden decisions; on a mismatch it
     **rolls back** to the previous policies.

   Launch it with `aigov_publish_self_test: true` to prove the refusal: it adds one failing test, and the job
   must refuse the bundle.
