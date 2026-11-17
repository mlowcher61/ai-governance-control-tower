# 10 — Competitive Analysis: ServiceNow AI Control Tower

**Research date:** 2026-11-17.

**Sources:** official ServiceNow press releases, product pages, and documentation, where available.

**Verification legend:**

- ✅ read in an official source
- 🟡 seen in search snippets of official pages
- ❓ third-party or unverified

**This analysis does not claim feature parity.** It identifies where an AO/AAP-based solution is stronger, equivalent, weaker, or not comparable.

---

## 1. ServiceNow AI Control Tower — current capabilities (sourced)

| Date | Development | Status |
|---|---|---|
| 2025-05-06 | **AI Control Tower** launched at Knowledge 2025, with **AI Agent Fabric** for MCP and A2A interoperability ([press release](https://www.servicenow.com/company/media/press-room/ai-control-tower-knowledge-25.html)) | 🟡 |
| 2025–2026 | AI Agent Fabric capabilities branded **Action Fabric** (MCP Server Console, MCP Client, A2A); MCP Server reported GA in 2026 | 🟡 |
| 2025-12-15 | Moveworks acquisition closed | 🟡 |
| 2026-03-02 | Veza acquisition closed (identity and access graph) | 🟡 |
| 2026-04-20 | Armis acquisition closed (asset and exposure management) | 🟡 |
| 2026-05-05 | **Expansion to five pillars: Discover, Observe, Govern, Secure, Measure** ([press release](https://newsroom.servicenow.com/press-releases/details/2026/ServiceNow-expands-AI-Control-Tower-to-discover-observe-govern-secure-and-measure-AI-deployed-across-any-system-in-the-enterprise/default.aspx)). Details below this table | ✅ |
| 2026-10-15 | **AI Passport** (runtime authorization scopes for agents and MCP servers), shadow-AI detection, AI Cost Management in ITAM, graduated alert/throttle/block enforcement; "Control Tower Alliance" (AWS, Anthropic, OpenAI, Okta, Kong, Zenity, among others); expected Q4 2026 ([press release](https://newsroom.servicenow.com/press-releases/details/2026/ServiceNow-advances-its-operational-harness-for-enterprise-AI-with-AI-Passport-and-expanded-governance-capabilities/default.aspx)) | 🟡 announced, not yet GA |
| 2026-10 | Product page and press materials use the name **"Super Intelligence Control Tower"**; documentation still says "AI Control Tower" | 🟡 (the reason for the rename is ❓) |

**Details of the 2026-05-05 expansion:**

- **Discover:** 30 new integrations, including AWS, Google Cloud, Azure, SAP, Oracle, and Workday; non-human identities; OT/IoT.
- **Observe:** powered by Traceloop.
- **Govern:** 5 risk frameworks aligned to NIST and the EU AI Act.
- **Secure:** Veza access graph and least privilege, "detect it and shut it down".
- **Measure:** cost and ROI.
- **AI Gateway** for MCP.
- Innovation Lab in May 2026; GA reported for August 2026.

**Documentation facts (✅ [AI inventory docs](https://www.servicenow.com/docs/r/intelligent-experiences/ai-control-tower/ai-inventory.html)):**

- Inventory asset types are AI Systems, AI Models, Prompts, Datasets, and MCP Servers.
- Assets carry a lifecycle phase, state, and risk classification.
- The **AI Discovery** Store app (🟡) provides Service Graph Connectors for AWS Bedrock, SageMaker, AgentCore, Azure Foundry, Copilot Studio, GCP Vertex AI, and others.

## 2. Capability matrix

Legend for the "Ours" columns:

- **OOB:** available in AAP/AO or certified content without development.
- **Int:** requires integration or configuration of existing products.
- **Dev:** custom development in this project.
- **No:** cannot currently be replicated in this POC.

| Capability | ServiceNow AI Control Tower | Our AO/AAP solution | OOB | Int | Dev | No | Our advantage | Our risk / limitation |
|---|---|---|---|---|---|---|---|---|
| **AI asset discovery** | 30+ connectors (AWS, Azure, GCP, SaaS); Service Graph; NHI and OT/IoT | AWS Bedrock Agents Classic and AgentCore in POC; adapters designed for Foundry, Vertex, REST | | ✔ (`amazon.ai`, `amazon.aws` certified) | ✔ (adapters, gap modules) | Breadth: SaaS copilots, NHI graph | Discovery is transparent Ansible; customers can add adapters themselves; same tool discovers and fixes | **Much narrower coverage**; each platform is new adapter work |
| **AI inventory / lifecycle** | Native CMDB-backed inventory with lifecycle phases | PostgreSQL inventory with snapshots, registry-as-code | | ✔ | ✔ | Rich lifecycle UI | Open schema, SQL access, Git-reviewed registry | No lifecycle workflow UI; no CMDB |
| **AI agent governance (policies)** | Governance workflows; risk frameworks; policies in-platform | OPA/Rego policies in Git, CI-tested, vendor-neutral | ✔ (OPA) | | ✔ (policy content) | | **Open, portable, testable policy-as-code**; same engine usable by AAP job-launch policy enforcement | Customers must author or curate Rego; no prebuilt framework library |
| **Policy enforcement** | "Detect and shut down" (Secure), graduated enforcement (announced) | Deterministic remediation via AAP: IAM restriction, alias pause, action-group disable, tagging; approval-gated; verified | ✔ (AAP execution, approvals) | ✔ | ✔ (actions) | | **Enforcement across any system Ansible reaches** (cloud, IAM, network, ITSM, on-prem), with verification and rollback | Enforcement is configuration-plane, not inline request blocking |
| **Risk assessment** | 5 frameworks (NIST, EU AI Act aligned); risk classification | Deterministic Rego risk score; registry-recorded risk assessments | | | ✔ | Packaged framework questionnaires | Transparent, explainable scoring tunable in Git | No questionnaire or assessment workflow |
| **Human approval** | Native ServiceNow approvals and workflow | AO approval steps (named approvers); optional ServiceNow approvals via `servicenow.itsm` | ✔ (AO) | ✔ | | | Approval tied directly to the executed change and its dry-run diff | AO approvals are newer; group approvers limited in the reference environment 🟡 |
| **Automated remediation** | Shut-down actions (Secure); workflow automation; action breadth not detailed publicly | Core strength: AAP job templates, certified modules, check mode, rollback, verification | ✔ | | ✔ (action library) | | **Decades-proven automation platform; existing customer content and skills** | Each remediation action is engineered and tested |
| **Runtime authorization** | AI Passport (announced Q4 2026), AI Gateway for MCP, throttle/block | Not in scope. Could *configure* runtime controls (for example AgentCore Gateway Policy, or API gateways such as Kong) via Ansible | | ✔ (via third-party gateways) | | ✔ inline runtime blocking | Vendor-neutral: manage whichever gateway the customer uses | **Gap**: no inline authorization of agent tool calls in this solution |
| **MCP governance** | MCP server inventory, MCP Server Console, AI Gateway for MCP | Inventory MCP-like tools where provider APIs expose them (Bedrock action groups, AgentCore gateways/targets via adapter); AAP MCP server and AO MCP integrations are separate products | | ✔ | ✔ | ✔ MCP traffic gateway | Can automate MCP server deployment and configuration (`ansible.mcp`, `ansible.mcp_builder`) | **Gap**: no MCP traffic inspection or authorization |
| **AI observability** | Traceloop-based observability | OTel GenAI semantic conventions, CloudWatch metrics, Grafana | | ✔ (Red Hat build of OTel, Grafana) | ✔ (dashboards) | Deep LLM tracing product | Open standards; no proprietary agent | Thinner; relies on agent owners instrumenting with OTel; GenAI semconv still "Development" |
| **Compliance reporting** | Framework-aligned governance (NIST, EU AI Act) | Control catalog mapped to NIST AI RMF / ISO 42001 control areas; evidence packs; hash-chained audit | | | ✔ | Packaged framework content | Evidence derived from **executed, verified controls** rather than attestations | Indicative mappings need customer compliance review; no EU AI Act module in POC |
| **Business-value measurement** | Measure pillar; AI Cost Management in ITAM (announced) | CloudWatch tokens, Cost Explorer, MTTD/MTTR, labor-savings model | | ✔ | ✔ | | Ties value to measured remediation outcomes | Per-agent cost depends on tagging and inference profiles; estimates require customer inputs |
| **Shadow AI detection** | Announced (Oct 2026) | Unregistered-agent detection within discovered platforms; OTel "observed vs governed" | | | ✔ | Network or SaaS shadow-AI discovery | Precise within supported platforms | Only sees platforms with adapters |
| **Identity / access graph** | Veza access graph | Per-agent role analysis plus IAM simulation | | | ✔ | Cross-system access graph | Proof via `SimulatePrincipalPolicy` | No cross-system graph |
| **Platform footprint** | ServiceNow SaaS | Customer-controlled OpenShift and AAP (on-prem, cloud, disconnected) | ✔ | | | | Data sovereignty; runs where AAP runs | Requires OpenShift (AO requirement) and operations effort |

## 3. Where we win

1. **Closed-loop enforcement.** Most AI governance tooling stops at "flag and ticket". AAP executes, verifies, and records the change. ServiceNow can also trigger actions, but AAP is the established execution layer for infrastructure, cloud, and network change in many of the same accounts, and ServiceNow customers often already use AAP for fulfillment.
2. **Open policy.** Rego in Git is reviewable, testable in CI, and portable. AAP also uses OPA natively for job-launch policy enforcement (since 2.5.5), so customers standardize on one policy language for automation governance and AI governance.
3. **Deterministic authority with advisory AI.** This is a clear, auditable answer to the question "can the AI change my environment?": no. It is a strong message for regulated industries.
4. **Existing investment.** Credentials, RBAC, execution environments, audit trails, operations staff, and automation content already exist.
5. **Complement rather than replace.** Findings and approvals can flow into ServiceNow (`servicenow.itsm`, certified). The positioning "ServiceNow governs the process, AAP enforces the change" is credible for joint customers.

## 4. Where we lose (be explicit with customers)

1. **Discovery breadth.** ServiceNow lists 30+ integrations, plus SaaS, NHI, and OT/IoT. The POC covers AWS Bedrock (Classic and AgentCore) only.
2. **Runtime authorization and MCP gateway.** AI Passport and the AI Gateway (announced) intercept or authorize at runtime. This solution governs configuration and identity, not live traffic.
3. **Packaged governance content.** ServiceNow ships risk frameworks, questionnaires, lifecycle workflows, and UI. We ship a policy starter set and Grafana dashboards.
4. **Observability depth.** Traceloop-based tracing goes beyond what the POC provides.
5. **Productization.** This is a reference solution and POC, not a supported product. Support boundaries: AAP, AO, the Red Hat build of OTel, and certified collections are supported by Red Hat. OPA, PostgREST, Grafana OSS, and the custom code are customer- or community-supported.

## 5. Differentiation summary (talk track)

> "ServiceNow AI Control Tower is a broad governance system of record. The AI Governance Control Tower on Ansible Automation Platform is an **enforcement-first** approach. It uses open policy-as-code, keeps AI strictly advisory, and has the automation platform you already run make verified, approved, auditable changes. Many customers will want both. Ansible is how governance decisions actually get enforced across clouds and infrastructure."

## 6. Risks to the competitive position

| Risk | Mitigation |
|---|---|
| ServiceNow ships deep remediation for AWS/Azure agents natively | Emphasize multi-domain enforcement, open policy, and on-prem/sovereign deployment; integrate rather than compete in ServiceNow accounts |
| Hyperscalers add native governance (AWS Agent Registry with approval workflow ✅, AgentCore Policy ✅, Microsoft Foundry native disable ✅) | Position as cross-cloud orchestration and evidence across these native controls. Adapters can *use* native registries as discovery sources |
| AO maturity (new product) | Keep the POC dependent only on AO features proven in reference exports; validate on the target version |
| Customer expects feature parity | Use the matrix above honestly; scope the POC to the closed loop |

## 7. Sources

- ServiceNow AI Control Tower launch (Knowledge 2025): https://www.servicenow.com/company/media/press-room/ai-control-tower-knowledge-25.html
- ServiceNow expansion (2026-05-05): https://newsroom.servicenow.com/press-releases/details/2026/ServiceNow-expands-AI-Control-Tower-to-discover-observe-govern-secure-and-measure-AI-deployed-across-any-system-in-the-enterprise/default.aspx
- AI Passport (2026-10-15): https://newsroom.servicenow.com/press-releases/details/2026/ServiceNow-advances-its-operational-harness-for-enterprise-AI-with-AI-Passport-and-expanded-governance-capabilities/default.aspx
- AI inventory documentation: https://www.servicenow.com/docs/r/intelligent-experiences/ai-control-tower/ai-inventory.html
- AI Discovery store app: https://store.servicenow.com/store/app/64699e821b036694c572dc28b04bcb3d
- AWS Agent Registry: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/registry.html
- AAP policy enforcement (OPA): https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/configuring_automation_execution/controller-pac
