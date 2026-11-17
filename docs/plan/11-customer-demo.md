# 11 — Customer Demonstration: "Govern the agents you didn't know you had"

**Duration:** 15–20 minutes (+ Q&A)
**Audience:** CISO office, cloud security, platform automation, risk and compliance
**Environment:** Controlled demo AWS account and the governance OpenShift environment. **Never run against customer production.**

---

## 1. Story arc

| Act | Message | Time |
|---|---|---|
| 1. Problem | AI agents are spreading without central oversight | 0:00–2:00 |
| 2. Discovery | AO discovers an agent operating without governance controls | 2:00–5:00 |
| 3. Assessment | OPA identifies the violation and classifies the risk | 5:00–7:00 |
| 4. Explanation | The AO task agent explains the risk in plain language | 7:00–8:30 |
| 5. Decision | AO determines that remediation requires approval | 8:30–10:00 |
| 6. Remediation | The administrator approves; AAP executes the playbook | 10:00–13:00 |
| 7. Verification | The workflow proves the risky permissions are gone | 13:00–15:00 |
| 8. Reporting | The dashboard and audit history reflect the corrected posture | 15:00–17:30 |
| 9. Business value | Existing automation investment delivers enforceable AI governance | 17:30–19:00 |

## 2. Pre-demo setup (T-60 minutes)

1. Run **AI Governance - Reset Demo Environment** in AAP. This restores four AgentCore runtimes. `quick_helper_bot` is unregistered, its role has `AdministratorAccess`, and it is tagged `DataClassification=restricted`.
2. Run the demo readiness checklist ([09-testing-and-validation.md §7](09-testing-and-validation.md#7-demo-readiness-checklist-run-before-every-customer-demo)).
3. Open browser tabs:
   - (A) AWS console, Amazon Bedrock AgentCore → Runtimes list
   - (B) AO workflows list
   - (C) AO Approvals page, logged in as the **approver** persona in a separate browser profile
   - (D) Grafana Executive Overview
   - (E) Grafana Audit Explorer
   - (F) AAP Jobs
   - (G) GitHub `policies/governance/policies/iam_001_admin.rego`
4. **Choose a variant:**
   - **Variant A (default, most reliable):** the baseline WF-01 runs live during Act 2.
   - **Variant B (Stage 3, "wow" moment):** start with the agent's role scoped. During Act 2, attach `AdministratorAccess` live in the AWS console (as "a developer in a hurry"). EventBridge → SQS → EDA → AO then detects it automatically. Allow about 1–3 minutes of latency and use the talk time.
5. Have the fallback recording ready.

## 3. Script

### Act 1 — Problem (0:00–2:00)

**Show:** Tab A, the AWS console list of agents.

**Say:**
> "Every team is building agents now. Each one runs with a machine identity, connects to tools, and reads company data. Here are four agents in one account. Which of them is risky? Who owns them? Has anyone approved them? The console can't tell you, and neither can most inventories. Today we'll show how the Ansible Automation Platform you already own can discover, judge, fix, and prove it."

### Act 2 — Discovery (2:00–5:00)

**Do:** Tab B. Open **AI Governance - Discovery and Assessment (as code)** and click Run.

**Show:** The canvas animates through Discover AI Agents, then Evaluate Governance Policies.

**Do:** Tab F. Open the running Discover job briefly.

**Say:**
> "Automation orchestrator is running a normal AAP job template with Red Hat certified content for AWS. It uses a **read-only** role, and the credentials live in AAP, not in a script. It collects agents, their models, tools, knowledge bases, tags, and the full IAM permissions of each agent's execution role. Anything it *can't* see, it records as unknown, not as fine."

*(Variant B: attach `AdministratorAccess` now, then say: "A developer just gave an agent admin rights to get unblocked. Watch what happens without anyone running anything.")*

### Act 3 — Assessment (5:00–7:00)

**Show:** Tab D, Grafana Executive Overview, which refreshes to 4 agents: 1 compliant, 2 noncompliant, 1 unknown.

**Do:** Click into `quick_helper_bot`, which opens the Agent Detail dashboard.

**Show:** The findings list, with REG-001 (unregistered) and IAM-001 (admin, **critical**), and a risk score of 100.

**Do:** Tab G. Show the Rego for IAM-001 for about 20 seconds.

**Say:**
> "The decision came from Open Policy Agent, open-source policy-as-code your security team owns in Git. It's code-reviewed and unit-tested, and the same engine AAP already uses for job-launch policy. Note the agent marked **unknown**: we couldn't verify its model, so we refuse to call it compliant."

### Act 4 — Explanation (7:00–8:30)

**Show:** The Agent Detail panel with the deterministic explanation next to the AI explanation.

**Say:**
> "The AI task agent in automation orchestrator turned the technical finding into language a security administrator can act on. But notice the design: the **policy** decided; the AI **explains**. The AI has no tools, can't call AWS, and its output never drives a decision."

### Act 5 — Decision (8:30–10:00)

**Do:** Click **Remediate** on the finding. This links to WF-02 with the `finding_id`. Variant B: WF-02 has already been started by the event pipeline.

**Show:** The WF-02 canvas: Get Context, Reassess, Remediation Authorization (OPA), AI Recommendation, Plan Remediation, then waiting at **Approval**.

**Say:**
> "Before acting, we re-check live state, so nothing is fixed from stale data. Then OPA decides what's allowed: replace the admin policy with the approved least-privilege policy, and because this is production and critical, **a human must approve**. The plan step ran a dry-run so the approver sees exactly what will change, plus the blast radius and rollback availability."

### Act 6 — Remediation (10:00–13:00)

**Do:** Tab C (approver persona). Open the approval and read the summary aloud: planned change, OPA decision ID, AI advisory. Add the note "Approved per demo change ticket CHG-1234" and click **Approve → Submit decision**.

**Show:** Tab B. The canvas continues to **Execute Remediation**. Tab F shows the AAP job output: assume the remediation role, attach the approved policy, then detach `AdministratorAccess`.

**Say:**
> "Approval releases the change to AAP, which executes it with a separate, tightly scoped remediation role: attach first, then detach, so the agent is never left broken. Nobody can run this template directly. Only the orchestrated, approved path can."

### Act 7 — Verification (13:00–15:00)

**Show:** The **Verify Remediation** job output:
- re-discovery with the read-only role;
- IAM policy simulation, where `iam:CreateUser` is now **implicitDeny**;
- OPA re-evaluation, where IAM-001 is **pass**;
- no regressions; the runtime is still `READY`;
- optional: the smoke-test invocation answers.

**Say:**
> "We don't trust that a change worked; we prove it. Independent re-collection, AWS's own policy simulator, and the same policy that found the problem confirm it's fixed. Only then is the finding closed."

### Act 8 — Reporting (15:00–17:30)

**Show:** Tab D, refreshed. `quick_helper_bot` drops from critical to high. It is still noncompliant because it is unregistered and has no owner.

**Say:**
> "Notice we didn't declare it compliant. Ownership and registration need a human decision, and the system says so. That's what honest governance looks like."

**Show:** Tab E, the Audit Explorer for this run. The ordered events carry actor icons: service, policy, AI, human approver (with name and note), AAP job IDs, OPA decision ID and policy revision, and the hash-chain status ✔.

**Say:**
> "Every observation, decision, AI suggestion, approval, change, and verification is linked by one correlation ID and chained for tamper evidence. This is the evidence your auditors and your NIST AI RMF or ISO 42001 programs need. It supports the assessment; it isn't a certification."

*(Optional, 30 seconds: show the generated Remediation Evidence Record report.)*

### Act 9 — Business value (17:30–19:00)

**Say:**
> "Everything you saw runs on Ansible Automation Platform: your credentials, your RBAC, your execution environments, your operations team. Policy is open and portable. AI makes it understandable, but never authorizes change. And the same pattern extends to Azure, Google, and your own agent platforms, and to every system Ansible already automates. You're not buying another silo; you're extending the automation platform you trust into AI governance."

## 4. Talking points by persona

| Persona | Emphasize |
|---|---|
| CISO | Deterministic authority; approval-gated; verified; tamper-evident evidence; detection-only by default |
| Cloud security | IAM least privilege proven by simulation; separate read and write roles; CloudTrail-driven detection |
| Platform / automation | Reuse of AAP; config as code; certified content; workflows as code |
| Risk and compliance | Control catalog mapped to NIST AI RMF and ISO/IEC 42001 areas; evidence packs; honest "unknown" handling |
| ServiceNow customer | Complementary: findings and approvals can flow to ServiceNow; AAP is the enforcement arm |

## 5. Anticipated questions

| Question | Answer |
|---|---|
| "Can the AI take actions on its own?" | No. The AI step has no tools; OPA selects the action; humans approve high-impact changes; AAP RBAC restricts who can run remediation. |
| "What about Azure and Google agents?" | The adapter design and contracts are provider-neutral. Microsoft Foundry and Vertex AI adapters are on the roadmap (APIs verified to exist). |
| "Do you block agents at runtime?" | Not in this solution. It governs configuration and identity. Runtime gateways (for example AgentCore Gateway policy, API gateways) can be configured with Ansible, and we're transparent that inline authorization is a different layer. |
| "What if the remediation breaks the agent?" | Dry-run first, attach-then-detach ordering, blast-radius check, functional verification, and approval-gated rollback from the captured pre-state. |
| "Does this replace ServiceNow AI Control Tower?" | It's a different emphasis: enforcement-first and open. Many customers will integrate the two. See the competitive analysis. |
| "Bedrock Agents is in maintenance mode — why demo it?" | Existing agents still run and need governing; all governance APIs remain available. The same flow works for AgentCore runtimes, which the solution also discovers. |

## 6. Reset after demo

Run **AI Governance - Reset Demo Environment**. It restores `AdministratorAccess` on the demo role, deregisters the demo agent, and clears the demo findings, preserving their audit history. It uses the reset-only path and is restricted to demo-tagged resources.
