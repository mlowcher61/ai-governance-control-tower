# AI Governance Control Tower

### Powered by Red Hat Ansible Automation Platform automation orchestrator

> **Status: Stage 0 (foundations) in progress.** The plan was approved on 2026-11-17. Implemented so far:
> - AAP config as code (`aap_config/`)
> - AWS governance roles and demo AgentCore runtimes (CloudFormation)
> - Environment check and least-privilege verification playbooks
> - The project collection's first module
> - CI
>
> See [Implementation status](#implementation-status).

---

## What is this?

Companies are rolling out AI agents quickly: chatbots and assistants built on platforms like **Amazon Bedrock**, Microsoft Foundry, or Google Vertex AI. Each agent:

- runs with a **machine identity**: an IAM role that says what it is allowed to do in your cloud;
- can call **tools** such as APIs and Lambda functions, which can change real systems;
- can read **company data** from knowledge bases;
- often has **no owner**, **no risk review**, and **far too many permissions**.

The **AI Governance Control Tower** finds these agents, checks them against your security rules, explains problems in plain language, and, with a human's approval, **fixes them automatically** using Ansible. Then it **proves** the fix worked and keeps a tamper-evident record of everything.

It is built on tools many enterprises already own, **Red Hat Ansible Automation Platform (AAP)** and its **automation orchestrator (AO)**, plus open standards: **Open Policy Agent (OPA)** for rules, **PostgreSQL** for the inventory, **Grafana** for dashboards, and **OpenTelemetry** for telemetry.

### The idea in one sentence

> **AI explains, policy decides, humans approve, Ansible executes, and the platform verifies and records everything.**

## How it works (the short version)

```
 ┌────────────┐   ┌────────────┐   ┌────────────┐   ┌─────────────┐   ┌──────────┐   ┌───────────┐   ┌──────────┐
 │  DISCOVER  │──▶│  EVALUATE  │──▶│  EXPLAIN   │──▶│  AUTHORIZE  │──▶│ APPROVE  │──▶│ REMEDIATE │──▶│  VERIFY  │
 │ AAP + AWS  │   │ OPA policy │   │ AO AI agent│   │ OPA policy  │   │  Human   │   │ AAP job   │   │ Re-check │
 │ (read-only)│   │ + risk     │   │ (advisory) │   │(deterministic)│ │ in AO    │   │ (scoped)  │   │ + audit  │
 └────────────┘   └────────────┘   └────────────┘   └─────────────┘   └──────────┘   └───────────┘   └──────────┘
```

1. **Discover.** AAP jobs read every AI agent in your AWS account: its model, tools, data sources, tags, and the exact permissions of its IAM role. This uses a read-only role.
2. **Evaluate.** OPA checks each agent against governance rules written in **Rego** (for example: "agents must not have administrator permissions"). It returns a decision, severity, evidence, and a risk score. **Missing information is never treated as "compliant".**
3. **Explain.** An AI task agent in automation orchestrator rewrites each finding in plain language. It is **advisory only**: it cannot change any decision.
4. **Authorize.** OPA decides whether a fix is allowed, which fix to use, and whether a human must approve it.
5. **Approve.** A named security approver reviews the exact planned change and approves or rejects it in AO.
6. **Remediate.** AAP runs an Ansible playbook with a separate, tightly scoped role. For example, it replaces `AdministratorAccess` with an approved least-privilege policy.
7. **Verify.** The workflow re-reads the agent, asks AWS's policy simulator whether the risky permissions are really gone, and re-runs the policy. Only then is the issue closed.

Everything is linked by one correlation ID and written to a hash-chained audit log. Grafana dashboards show posture, trends, and the full audit history.

## Three stages

| Stage | What you get | Plan |
|---|---|---|
| **1. Discovery and Governance** | Inventory of AI agents, OPA policy findings, risk scores, AI explanations, dashboard. **Useful on its own.** | [03-stage-one-plan.md](docs/plan/03-stage-one-plan.md) |
| **2. Closed-Loop Remediation** | Approval-gated, verified, auditable remediation through AAP. **The main demo.** | [04-stage-two-plan.md](docs/plan/04-stage-two-plan.md) |
| **3. Continuous Governance** | Real-time change detection (CloudTrail → EventBridge → SQS → Event-Driven Ansible), drift reconciliation, compliance reports, cost and ROI | [05-stage-three-plan.md](docs/plan/05-stage-three-plan.md) |

## Planning documents

| # | Document | What it covers |
|---|---|---|
| 01 | [Executive overview](docs/plan/01-executive-overview.md) | Business problem, solution, target customers, positioning |
| 02 | [Solution architecture](docs/plan/02-solution-architecture.md) | Components, integrations, topology, authentication, security boundaries, data flows, design decisions |
| 03 | [Stage one plan](docs/plan/03-stage-one-plan.md) | Discovery design, Bedrock APIs, database schema, OPA policy architecture, example policies, WF-01 |
| 04 | [Stage two plan](docs/plan/04-stage-two-plan.md) | WF-02 node-by-node, API contracts, job templates, remediation playbooks, authorization policy, approvals, verification and rollback |
| 05 | [Stage three plan](docs/plan/05-stage-three-plan.md) | Event-driven architecture, EDA rulebook, monitoring, OpenTelemetry, dashboards, compliance evidence, ROI, runbooks, enterprise deployment |
| 06 | [Technical dependencies](docs/plan/06-technical-dependencies.md) | Versions, collections (verified against your private hub), APIs, credentials, cloud resources |
| 07 | [Repository structure](docs/plan/07-repository-structure.md) | Layout, conventions, CI validation |
| 08 | [Security and governance](docs/plan/08-security-and-governance.md) | Threat model, secrets, least privilege, policy authority, approvals, audit |
| 09 | [Testing and validation](docs/plan/09-testing-and-validation.md) | Unit, integration, workflow validation, failure scenarios, acceptance criteria |
| 10 | [Competitive analysis](docs/plan/10-competitive-analysis.md) | ServiceNow AI Control Tower comparison, advantages, gaps |
| 11 | [Customer demo](docs/plan/11-customer-demo.md) | 15–20 minute demonstration script with talking points |
| 12 | [Implementation roadmap](docs/plan/12-implementation-roadmap.md) | Tasks, estimates, critical path, milestones |
| 13 | [Open questions](docs/plan/13-open-questions.md) | Decisions needed, assumptions, licensing, unverified items |
| — | [Environment validation](docs/plan/environment-validation.md) | Read-only checks of the target AAP, AO, and AWS environment (2026-11-17) |

## Key terms for new Ansible users

| Term | Meaning |
|---|---|
| **AAP** | Red Hat Ansible Automation Platform: runs Ansible playbooks as **job templates** with stored **credentials** and role-based access |
| **automation orchestrator (AO)** | AAP add-on for visual, multi-step workflows that combine AAP jobs, AI task agents, REST calls, decisions, and human approvals |
| **Event-Driven Ansible (EDA)** | Listens for events (here, AWS changes delivered through SQS) and launches automation in response |
| **OPA / Rego** | Open Policy Agent, an open-source policy engine. Rego is its rule language. Rules live in Git and are unit-tested |
| **Config as code** | AAP, AO, EDA, OPA, Grafana, and the database are all configured from files in this repository, so a new environment can be set up by running playbooks |
| **Certified / validated content** | Red Hat–supported Ansible collections from automation hub. This project prefers them over community content |

## Implementation status

| Task | Status |
|---|---|
| T0.01 Environment validation | Done (read-only checks): see [environment-validation.md](docs/plan/environment-validation.md) |
| T0.02 AO reference capture | Partially done: the OpenAPI 1.3.0 spec is captured. The workflow export is blocked on AO API credentials |
| T0.03 Repository and CI | Done |
| T0.05 AAP config as code (Stage 0 subset) | Done: `aap_config/` |
| T0.07 AWS governance roles and demo agents | Templates and playbooks done; deployed through AAP job templates |
| T0.04 Execution environment | Pending: Stage 0 uses the AAP 2.7 `Default execution environment` |

## Getting started

The configuration-as-code entry points are:

1. **[aap_config/README.md](aap_config/README.md)**: configure AAP from code. This creates the organization, credential types and credentials, project, inventory, and job templates.
2. In AAP, run **AI Governance - Check Environment**, then **Deploy AWS Governance Roles**, **Deploy Demo Agents**, and **Verify AWS Baseline**.
3. *(Stage 0/1, next)* **AI Governance - Deploy Platform Services**: PostgreSQL, the Inventory API, OPA, and Grafana on OpenShift.
4. *(Stage 1, next)* `ao_workflows/`: configure automation orchestrator and load the workflows.

Credentials are entered into AAP (or pulled from your secret manager). **No secrets are ever stored in this repository.**

## Repository

`github.com/mlowcher61/ai-governance-control-tower` (proposed)
