# 07 — Repository Structure and Development Conventions

**Repository:** `github.com/mlowcher61/ai-governance-control-tower`

**Target runtime:** Ansible Automation Platform 2.7 with automation orchestrator. The repository is used as an AAP **project** and an EDA **project**. It is not designed for standalone ansible-core use.

---

## 1. Recommended layout

The suggested top-level directories are kept, with three changes:

1. Custom modules and roles live in a real collection (`collections/ansible_collections/mlowcher61/ai_governance/`) instead of top-level `roles/`, so that `ansible-test` works.
2. `discovery/` is folded into that collection, because discovery is roles plus modules.
3. `aap_config/`, `schemas/`, `aws/`, and `compliance/` are added.

```
ai-governance-control-tower/
├── README.md                          # Solution overview, quick start, links to docs
├── CHANGELOG.md
├── CODEOWNERS                         # policies/ and aap_config/ require security-team review
├── LICENSE
├── .github/
│   └── workflows/
│       ├── ci.yml                     # lint + unit tests + contracts on every PR
│       ├── ee-build.yml               # build and push execution / decision environments
│       └── policy-bundle.yml          # opa check/test, stamp revision, artifact
├── .pre-commit-config.yaml
├── .ansible-lint, .yamllint, ruff.toml, .regal/config.yaml
│
├── docs/
│   ├── plan/                          # 01–13 planning documents (this set)
│   ├── architecture/                  # diagrams (Mermaid sources)
│   ├── actions/                       # one spec per remediation action type
│   ├── runbooks/                      # RB-01 … RB-12
│   └── demo/                          # demo scripts, talking points, reset checklist
│
├── aap_config/                        # Config as code for AAP (infra.aap_configuration)
│   ├── README.md                      # How a new user configures AAP for their platform
│   ├── configure_aap.yml              # Entry playbook: include_role infra.aap_configuration.dispatch
│   ├── group_vars/all/
│   │   ├── aap_organizations.yml
│   │   ├── gateway_teams_users.yml    # ansible.platform-backed objects
│   │   ├── controller_credential_types.yml
│   │   ├── controller_credentials.yml # references only; secrets supplied at runtime/survey or secret backend
│   │   ├── controller_execution_environments.yml
│   │   ├── controller_projects.yml
│   │   ├── controller_inventories.yml
│   │   ├── controller_templates.yml
│   │   ├── controller_schedules.yml
│   │   ├── controller_notifications.yml
│   │   ├── controller_roles.yml
│   │   ├── eda_projects.yml
│   │   ├── eda_credentials.yml
│   │   ├── eda_decision_environments.yml
│   │   └── eda_rulebook_activations.yml
│   └── vars/customer.example.yml      # The only file a new user must copy and edit
│
├── ao_workflows/
│   ├── README.md                      # Format, loader, validation, importability policy
│   ├── reference/                     # Known-good export + openapi.json from target AO (T0.02)
│   ├── config/
│   │   ├── connections.yml            # names of AO credentials/integrations/LLM model
│   │   └── approvers.yml              # approver AAP usernames
│   ├── definitions/                   # "by name" YAML — source of truth
│   │   ├── wf01_discovery_assessment.yml
│   │   ├── wf02_closed_loop_remediation.yml
│   │   └── wf03_targeted_reassessment.yml
│   ├── rendered/                      # schema_version 2.0.0 JSON with placeholders (reviewable; CI-generated)
│   ├── configure_ao.yml               # AO config as code: AAP integration, LLM integration, credentials, service account
│   └── apply_workflows.yml            # render → /workflows/validate → create/patch → publish
│
├── playbooks/
│   ├── platform/                      # deploy_services.yml, db_migrate.yml, issue_api_tokens.yml
│   ├── policy/                        # publish.yml
│   ├── registry/                      # load.yml
│   ├── discovery/                     # discover.yml
│   ├── evaluation/                    # evaluate.yml, reassess.yml, record_explanations.yml, summary.yml
│   ├── remediation/                   # get_context.yml, plan.yml, execute.yml, verify.yml, rollback.yml,
│   │                                  # record_outcome.yml, request_evidence.yml, finalize.yml
│   ├── events/                        # process_change_event.yml, trigger_remediation.yml, deploy_event_plumbing.yml
│   ├── reporting/                     # collect_usage_cost.yml, reconcile_sweep.yml, compliance_report.yml
│   └── demo/                          # setup.yml, reset.yml, inject_violation.yml
│
├── collections/
│   ├── requirements.yml               # pinned certified/validated collections (AAP project sync)
│   └── ansible_collections/mlowcher61/ai_governance/
│       ├── galaxy.yml
│       ├── meta/runtime.yml
│       ├── plugins/
│       │   ├── modules/               # bedrock_agent_details_info.py, iam_role_permissions_info.py, ...
│       │   ├── module_utils/          # normalization (IAM statements), evidence status helpers
│       │   └── filter/                # aigov_* filters (e.g., canonical JSON hash)
│       ├── roles/
│       │   ├── discover_ai_agents/    # orchestrates scopes, validation, submission
│       │   ├── discover_aws_bedrock_agents/
│       │   ├── discover_aws_agentcore/
│       │   ├── evaluate_agents/
│       │   ├── remediate_ai_agent/    # tasks/actions/<action_type>.yml
│       │   ├── verify_remediation/
│       │   ├── inventory_api/         # thin wrappers around ansible.builtin.uri for RPC calls
│       │   ├── ao_api/                # token + executions + approvals
│       │   └── otel_emit/
│       └── tests/
│           ├── unit/plugins/modules/  # pytest + botocore Stubber
│           └── integration/targets/   # optional ansible-test integration (demo account)
│
├── policies/
│   ├── governance/                    # Rego (see Stage 1 §6.1)
│   ├── aap/                           # AAP policy-as-code guard (Stage 2, P1)
│   ├── data/governance/               # config/data.json, remediation_catalog.json, policy_actions.json
│   ├── tests/                         # *_test.rego
│   └── fixtures/                      # golden inputs/outputs (shared with Python + E2E)
│
├── schemas/                           # JSON Schemas: discovery-record, policy-input, policy-result,
│                                      # authz-request/response, ai-explanation, ai-recommendation, artifacts
├── inventory/
│   ├── hosts.yml                      # localhost-only inventory for API-driven playbooks
│   └── registry/                      # governance registry as code: owners.yml, registrations.yml
│
├── database/
│   ├── migrations/                    # V001__baseline.sql, V002__api.sql, V003__reporting_views.sql, ...
│   ├── seeds/                         # demo/reference data (never prod)
│   └── tests/                         # SQL assertions / pgTAP
│
├── eda/
│   └── rulebooks/aigov_aws_change_events.yml   # EDA project root must contain rulebooks/ (see note)
│
├── platform/                          # Kubernetes manifests (templated) for governance services
│   ├── postgres/  postgrest/  opa/  grafana/  otel-collector/  networkpolicies/
│
├── dashboards/
│   ├── provisioning/datasources/aigov.yaml
│   ├── provisioning/dashboards/aigov.yaml
│   └── json/                          # executive.json, operations.json, agent_detail.json, audit.json, usage_cost.json
│
├── compliance/
│   ├── controls.yml                   # control catalog + framework mappings
│   └── report_templates/              # Jinja2 templates for reports
│
├── aws/
│   ├── cloudformation/                # aigov-governance-roles.yaml, aigov-demo-agents.yaml, aigov-events.yaml, aigov-evidence.yaml
│   └── iam/                           # policy JSON documents (reviewed separately)
│
├── execution_environments/
│   ├── ai-governance-ee/execution-environment.yml
│   └── ai-governance-de/decision-environment.yml
│
├── tests/
│   ├── e2e/                           # stage1.yml, stage2.yml, stage3.yml (assertion playbooks)
│   └── failure_injection/             # scenarios (see 09-testing-and-validation.md)
│
└── scripts/                           # small helpers only (render AO JSON locally, verify audit chain)
```

**Note on the EDA project:** EDA projects expect rulebooks in a `rulebooks/` directory at the project root, or in an `extensions/eda/rulebooks/` path. The reference repositories use both. Task T3.02 confirms which layout the AAP 2.7 EDA project scanner accepts. If needed, `eda/rulebooks/` becomes `extensions/eda/rulebooks/`.

## 2. Development conventions

### 2.1 Ansible

- **FQCN everywhere**, including `ansible.builtin.*`. Enforced by `ansible-lint` in the production profile.
- **Every task is named.** Names use the imperative mood and say what the task does.
- **No `shell` or `command` for things a module can do.** Allowed exceptions are documented inline: `opa` CLI in the policy publish job, and `psql` inside the migration Job container.
- **Idempotency.** Every write task must be idempotent. Remediation actions are tested for a second-run `changed=false`.
- **Check mode.** Every remediation action supports `check_mode` with `diff`, and the Plan job uses it.
- **Variable prefixes.** `aigov_` for project variables; `governance_run_id`, `remediation_id`, and `finding_id` are the only unprefixed workflow inputs.
- **Business outcomes.** Remediation, verification, and rollback use `block`/`rescue`/`always` and report `status` via `ansible.builtin.set_stats` (`per_host: false`).
- **Credentials.** Secrets are injected only through AAP credentials (custom credential types). No vars files contain secrets, and Ansible Vault is not used.
- **Logging.** Tasks that handle tokens or JWTs use `no_log: true`.
- **Collections.** Pinned in `collections/requirements.yml`, with certified and validated content preferred. Any community collection requires an entry in `docs/plan/13-open-questions.md` and a reviewer sign-off.
- **Job template naming:** `AI Governance - <Verb> <Object>`.
- **Organization:** `AI Governance`.

### 2.2 automation orchestrator workflows

- **Source of truth.** The "by name" YAML in `ao_workflows/definitions/`. Rendered JSON is generated, never hand-edited.
- **Naming.** Workflow names end with `(as code)` so they never collide with canvas-built copies (convention from `sales.demos`). Labels are `managed-by: ai-governance-control-tower` and `source_file: <file>`.
- **Node IDs.** `activity_<verb>`, `logic_<decision>`, `approval_<subject>`, `trigger_<kind>`.
- **Expressions.** Reference node IDs only; compare strings or numbers, never bare booleans.
- **Importability rule.** A workflow may be described as importable **only** after `POST /workflows/validate` returns `is_valid: true` **and** a test execution completes on the target AO version. The version is recorded in `ao_workflows/reference/VERSION`.
- **Product naming.** Running text uses "automation orchestrator" in lowercase, following the naming rule in your `ao_demo_config` repository, and "AO" as the abbreviation. See open question Q-17.

### 2.3 Rego

- Rego v1 on OPA 1.x. One policy per file, in package `governance.policies.<id_lower>`.
- Every policy defines `meta` (ID, version, title, severity, controls, remediation) and `result`.
- A policy version bump is required for any decision-affecting change. CHANGELOG entries go in `policies/CHANGELOG.md`.
- **No `time.now_ns()`.** Use `input.evaluation.evaluated_at`.
- **No `http.send`.** Policies are pure functions of input and data.
- Tests sit next to their fixtures. Coverage ≥ 90%.

### 2.4 Python (custom modules)

- Based on `amazon.aws` `AnsibleAWSModule`, with standard documentation blocks (`DOCUMENTATION`, `EXAMPLES`, `RETURN`).
- Read modules never call mutating APIs. Write modules support `check_mode` and `diff`.
- Unit tests use `botocore.stub.Stubber`. `ruff` must be clean.

### 2.5 SQL

- Forward-only numbered migrations. Never edit an applied migration; add a new one.
- All client access goes through the `api` schema (functions and views). Reporting views live in the `reporting` schema.
- Every write function appends audit events in the same transaction.

### 2.6 Git workflow

- `main` is protected: PR required, CI green, and CODEOWNERS approval for `policies/`, `aap_config/`, `aws/iam/`, and `ao_workflows/definitions/`.
- Conventional commit messages. Tags are `vX.Y.Z`. EE images are tagged with the same version (immutable tags).
- The AAP project syncs `main`. Demos may pin a tag.

## 3. Automated validation (CI pipeline)

| Job | Tools | Blocks merge |
|---|---|---|
| `lint-yaml-ansible` | `yamllint`, `ansible-lint --profile production` | Yes |
| `collection-sanity-units` | `ansible-test sanity --docker`, `ansible-test units`, `pytest`, `ruff` | Yes |
| `rego` | `opa fmt --diff`, `opa check --strict`, `opa test --coverage --threshold 90`, `regal lint` | Yes |
| `contracts` | `check-jsonschema`: fixtures and rendered AO JSON structural schema (derived from the reference export) | Yes |
| `sql` | Apply migrations on PostgreSQL 16, run SQL tests | Yes |
| `golden-decisions` | Run OPA against `policies/fixtures/inputs/*` and diff with expected outputs | Yes |
| `ao-render` | Render AO definitions with dummy IDs; schema-check | Yes |
| `ee-build` (on tag) | `ansible-builder build`, push to registry | — |
| `ao-validate` (manual / self-hosted runner with AO access) | Loader in validate-only mode against the target AO | Required before release tag |
