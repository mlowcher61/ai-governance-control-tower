# 01 — Executive Overview

**Project:** AI Governance Control Tower, powered by Red Hat Ansible Automation Platform automation orchestrator (AO)
**Status:** Planning — awaiting approval. No implementation code has been written.
**Plan date:** 2026-11-17

---

## 1. The business problem

Enterprises are deploying AI agents faster than they can govern them. Development teams create agents in AWS (Amazon Bedrock Agents, Amazon Bedrock AgentCore), Microsoft Foundry, Google Vertex AI Agent Engine, SaaS copilots, and home-grown frameworks. Each agent:

- runs under a **machine identity** (for example an IAM execution role) that is frequently over-privileged ("just give it admin so it works"),
- connects to **tools** (Lambda functions, APIs, MCP servers) that can change real systems,
- reads **enterprise data** (knowledge bases, S3 buckets, databases),
- uses a **foundation model** that may not be approved for the data it touches,
- often has **no accountable owner**, no risk assessment, and no record in any inventory.

Security and risk teams are asked three questions they cannot answer today:

1. *What AI agents do we have, and who owns them?*
2. *Which of them violate our policies, and how risky are they?*
3. *When we find a problem, can we fix it quickly, safely, and prove that we did?*

Most AI governance tools answer questions 1 and 2 with inventories and dashboards. Very few close the loop on question 3 with **enforceable, auditable remediation** — and that is precisely what Red Hat Ansible Automation Platform (AAP) already does for infrastructure, cloud, network, and security.

## 2. The proposed solution

The **AI Governance Control Tower** is an open, extensible reference solution that turns an existing AAP investment into an AI governance platform:

| Capability | How it is delivered |
|---|---|
| **Discover** AI agents, models, tools, data sources, and permissions | AAP job templates running Ansible discovery roles (certified `amazon.ai` and `amazon.aws` content, plus small read-only modules for API gaps) |
| **Inventory** every agent with history | PostgreSQL inventory exposed through a REST/JSON API (PostgREST) |
| **Evaluate** agents against governance policy | Open Policy Agent (OPA) with vendor-neutral Rego policies stored in Git |
| **Classify risk** | Deterministic Rego risk scoring (permissions, data sensitivity, ownership, posture, evidence completeness) |
| **Explain** findings in plain language | AO AI task agent (advisory only) |
| **Decide** whether remediation is allowed and needs approval | Deterministic OPA remediation-authorization policy — never the AI |
| **Approve** high-impact changes | AO approval steps with named approvers |
| **Remediate** | AAP job templates running Ansible playbooks (certified modules for every write where they exist) |
| **Verify** | Re-discovery, IAM policy simulation, and OPA re-evaluation before any finding is closed |
| **Prove** | Append-only, hash-chained audit trail in PostgreSQL plus AO and AAP execution records |
| **Monitor continuously** | AWS CloudTrail → Amazon EventBridge → Amazon SQS → Event-Driven Ansible → AO, plus scheduled reconciliation |
| **Report** | Grafana dashboards and compliance evidence reports mapped to NIST AI RMF and ISO/IEC 42001 control areas |

### The core idea in one sentence

> **AI explains, policy decides, humans approve, Ansible executes, and the platform verifies and records everything.**

## 3. Three-stage proof of concept

| Stage | Outcome | Standalone value |
|---|---|---|
| **Stage 1 — Discovery and Governance** | A centralized inventory of Bedrock agents with OPA policy findings, risk scores, and AI-written explanations | Yes — answers "what do we have and what is wrong?" |
| **Stage 2 — Closed-Loop Remediation** (primary competitive demo) | An unauthorized agent with administrator permissions is detected, explained, approved, remediated by AAP, verified, and audited | Requires Stage 1 |
| **Stage 3 — Continuous Governance** | Event-driven detection, drift reconciliation, dashboards, compliance evidence reports, cost and ROI metrics | Requires Stage 1; Stage 2 recommended |

Estimated MVP effort, before 20% contingency:

- **~46 engineer-days** for Stage 1, including platform foundations
- **~26** for Stage 2
- **~22.5** for Stage 3

That is about 13–14 calendar weeks for all three stages with two engineers. Assumptions and the task-level breakdown are in [12-implementation-roadmap.md](12-implementation-roadmap.md).

## 4. Target customers

| Segment | Why they care |
|---|---|
| **Existing AAP customers adopting AI** (financial services, public sector, telco, healthcare, manufacturing) | Reuse automation, RBAC, credentials, and audit they already trust; no new remediation tool |
| **Security and cloud governance teams** (CISO office, cloud center of excellence) | Need enforcement and evidence, not just inventories |
| **Risk and compliance teams** preparing for NIST AI RMF, ISO/IEC 42001, EU AI Act obligations | Need repeatable control execution and evidence collection |
| **Organizations evaluating ServiceNow AI Control Tower** | Want an open, policy-as-code alternative or a complementary enforcement layer |

## 5. Competitive positioning (summary)

ServiceNow announced AI Control Tower at Knowledge 2025 and expanded it in May 2026 (Discover, Observe, Govern, Secure, Measure), with general availability reported for August 2026. October 2026 sources indicate a rename to "Super Intelligence Control Tower". It is strong in **inventory breadth, lifecycle workflow, risk frameworks, access-graph analysis (Veza), and observability (Traceloop)**.

Our position is **not feature parity**. It is:

1. **Enforcement and remediation as a first-class capability.** AAP executes deterministic, approved, verified changes across clouds, identity systems, networks, and ITSM — including ServiceNow itself.
2. **Open, portable policy.** Governance rules are Rego in Git, testable in CI, and reusable outside this solution.
3. **Leverage of existing investment.** Customers already own AAP, its credentials, RBAC, execution environments, and audit trails.
4. **Deterministic authority with advisory AI.** The AI never authorizes actions; OPA policy and named humans do.
5. **Complementary deployment.** The Control Tower can feed findings to, or receive tasks from, ServiceNow using the certified `servicenow.itsm` collection.

Known gaps (discovery breadth, runtime authorization, packaged UI, out-of-the-box risk frameworks) are documented honestly in [10-competitive-analysis.md](10-competitive-analysis.md).

## 6. What success looks like

At the end of Stage 2, a customer watching a 15–20 minute demonstration sees:

1. An **unauthorized** Amazon Bedrock AgentCore agent with `AdministratorAccess` on its execution role discovered automatically.
2. OPA policies flag it as **critical** with explicit evidence.
3. An AO AI task agent explains the risk in plain language for a security administrator.
4. OPA determines that remediation is permitted **but requires approval**.
5. A named approver approves in AO.
6. AAP replaces the administrator policy with an approved least-privilege policy.
7. The workflow proves the risky permissions are gone (IAM policy simulation plus OPA re-evaluation).
8. Grafana shows the posture change and the complete audit trail.

## 7. Key risks (executive view)

| Risk | Impact | Mitigation |
|---|---|---|
| **Amazon Bedrock Agents ("Classic") entered maintenance mode on 2026-07-30.** New AWS accounts cannot create agents. | **Decided:** the demo uses AgentCore runtimes (the demo account has never used Bedrock Agents). Classic discovery is retained for customer estates. Original impact: demo account may not be able to create test agents | Use an allowlisted account with prior Bedrock Agents usage, **or** demonstrate against Amazon Bedrock AgentCore runtimes (same IAM-role remediation story). Decision required. |
| AO is new (docs version 2026.8) and its workflow import/export format is not formally documented | Workflow JSON may need adjustment per AO build | Require a reference export from the target AO; validate every workflow with AO's `/workflows/validate` API before claiming importability |
| AI explanations could be manipulated by prompt injection in agent metadata | Misleading explanations | AI is advisory only; no tools; constrained output schema; deterministic validation of every AI choice |
| Remediation could disrupt a legitimate agent | Business outage | Detection-only default, dry-run, approval gates, account allowlists, pre-state snapshots, rollback playbooks |

## 8. Decision requested

Approve the architecture and stage plan, and answer the key decisions in [13-open-questions.md](13-open-questions.md) — in particular the AWS account / Bedrock platform choice, the LLM provider for AO, and the inventory API approach — before implementation begins.
