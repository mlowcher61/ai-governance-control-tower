# Verified automation orchestrator workflows

A workflow is listed here only after every step of docs/plan/09 section 4 passed on the target AO:
the loader rendered it from `ao_workflows/definitions/`, `POST /api/v1/workflows/validate` returned valid,
it was created and published from YAML by the AAP job template **AI Governance - Apply AO Workflows**
(running as the `aigov-trigger` service account), and real executions reached the expected terminal nodes.

## WF-01 - AI Governance Assessment

| Item | Evidence |
|---|---|
| Definition | `ao_workflows/definitions/wf01_governance_assessment.yml` |
| Target | automation orchestrator API 1.3.2, cluster mk6hb, project `default`; AAP controller 4.8.13 |
| Date | 2026-11-20 |
| Validation | Valid (`apply_workflows.yml -e aigov_ao_validate_only=true`) |
| Loaded | AAP job 168: created and published version 1 (id `9785baab-b898-4d7c-ad1b-edaa9354812f`) |
| Execution 1 (findings to explain) | `98433f4f-d6a0-48e2-8439-c8404968037e`, completed. Path: Discover (AAP job 169) -> Evaluate (171) -> condition **true** -> AI explanation (`llama-scout-17b`) -> Record AI Explanations (172: 9 received, 9 recorded, 0 skipped) -> Publish Assessment Summary (174: 4 agents, 1 compliant, 2 noncompliant, 1 unknown, 9 open findings, 1 critical). `activity_summary_no_findings` skipped |
| Execution 2 (nothing new to explain) | `c559f2d6-1300-4ee6-bd72-4d7ece5cdea0`, completed. Path: Discover -> Evaluate -> condition **false** -> Publish Assessment Summary (nothing to explain). The AI node and Record were skipped because all open findings already had explanations |

Behavior confirmed on this AO build (docs/plan/03 section 9.2 open points):

- A `condition` node uses the edge ports `"true"` and `"false"`.
- `${activity_evaluate.artifacts.explain_count} > 0` compares numbers when the artifact is an integer.
- An array from an agentic node (`${activity_explain.result.content.explanations}`) reaches the AAP job's extra
  vars as a JSON list, not as a string. The Record job still accepts text as well.
- The AI step returned one explanation per finding with the exact `finding_id`, and its next steps quoted the
  policy remediation text (the allowed next steps).

### Stage 1 end-to-end test (T1.13, 2026-11-20)

AAP job 224 (**AI Governance - Stage 1 End-to-End Test**) ran three cycles of the AAP workflow Reset Demo Environment
(workflow jobs 226, 236, 247) and WF-01 (executions `7b566ad7-9ba4-4dcb-9230-2c45198ec74f`,
`9e7d1c45-b468-450c-b705-a5b4591852a3`, `d68ce050-3fcd-4e6c-ad3e-0366a31d6197`). Each execution took the explain branch
(the reset leaves no explained findings), and all Stage 1 acceptance criteria (A1-1 to A1-9) passed with an identical end
state in every cycle.

## WF-02 - AI Governance Closed-Loop Remediation

| Item | Evidence |
|---|---|
| Definition | `ao_workflows/definitions/wf02_closed_loop_remediation.yml` (33 steps, no step with more than one incoming edge) |
| Target | automation orchestrator API 1.3.2, cluster mk6hb, project `default`; AAP controller 4.8.13 |
| Date | 2026-11-22 |
| Validation and load | Valid; created by AAP job 360 (id `f935d80f-bd64-4b62-9b8c-cd259d78a22e`), current structure loaded by job 426 |

| Branch | Execution | Path (AAP jobs) |
|---|---|---|
| Assessment error (unknown finding ID) | `1154be7e-12db-44f9-9d45-0510ecf92dcc` | context 374 -> reassess 377 `error` -> outcome `assessment_error` 379 (audited against the unknown ID) |
| Missing evidence | `27838776-a3b5-48b8-b8d0-21f340d83ea9` | context 363 -> reassess 367 `missing_evidence` -> outcome 369 (never remediated) |
| Noncompliant, no automated fix (halted) | `2e33123a-0ce9-490f-9765-30cb28e869a8` | context 364 -> reassess 368 -> AI -> plan 370 `halt` -> outcome `denied` 372 |
| **Noncompliant -> human approval -> execute -> verify -> approved rollback** | `292eac34-92c3-495c-939b-70412536ccd7` | context 428 -> reassess 430 -> AI (agrees) -> plan 431 `approval` -> **AO approval by the user** -> recorded from AO 434 -> execute 435 `succeeded` -> verify 436 `verification_failed` (quarantine tags do not register a shadow agent) -> outcome 438 (rollback offered) -> **AO rollback approval by the user** -> recorded from AO 439 -> rollback 441 `rolled_back` -> outcome 442 |

Behavior confirmed on this AO build:

- A `switch` uses ports `case_0`, `case_1`, ... and `default_port: default`; an `approval` node uses ports `approved`
  and `rejected`.
- **A step is skipped as soon as ANY of its incoming branches is skipped.** A `converge` node (strategy `any`,
  `n_required: 1`) was skipped when the route switch chose approval (execution `24c8f3f9`), and so was a step with
  two incoming edges (execution `f108e75b`). Exclusive branches therefore never join: the automatic route has its own
  copy of the execute chain. Joins work only for branches that all run.
- A `converge` with `strategy: any` requires `n_required` (validation).
- The approval prompt resolves `${activity_plan.artifacts.approval_summary}`; AO limits it to 2000 characters, so Plan
  caps the summary. The approval node's output carries `decision`, `decided_by` (`admin-f0eb7edf97a2575d`) and
  `decision_notes`; the approvals API (`GET /api/v1/approvals?sort=-updated_at`) returns the same decision with
  `workflow_context.workflow_name`, which Record Approval Decision uses to find it.
- `${activity_recommend.result.content}` (an object) reaches the AAP job as a dict.
- Not needed: an execution ID expression. Approvals are matched by workflow, approval node and remediation ID.

### Stage 2 acceptance runs (T2.12, 2026-11-22/23)

| Branch / case | Execution | Result |
|---|---|---|
| Compliant (stale finding, F-17) | `80b39abb-bbca-4025-8d7c-df50a3d9c507` | reassess `compliant` -> outcome `no_longer_detected` |
| Missing evidence | `f656f904-cc42-4a90-b0e3-c52286bab159` | outcome `missing_evidence` |
| Assessment error | `25b58e13-3960-48d3-b019-c825b765b6be` | outcome `assessment_error` |
| Detect-only default (F-16) | `77d0f704-2ce4-45cc-8458-72b03d24618f` | Plan `halt` -> outcome `detect_only` |
| No automated fix | `58cff6f2-900e-4024-ab80-fcb1bad279d9` | outcome `denied` |
| Account not allowlisted (F-15) | `75324c1a-8ea4-46eb-ae70-8efdc38fcb61` | outcome `denied` (allowlist) |
| Simulate | `6bbadaaf-1846-43dc-9b06-a267db68c027` | route `simulate` -> outcome `simulated` |
| **Automatic** -> verification failed -> rollback offered | `2e3ab0e1-bccd-4e95-aaa2-2a7b759992a4` | route `auto`, executed, `verification_failed`, rollback approval waiting (cancelled by the test) |
| Concurrent run (F-12) | `3710698a-9d89-4251-b189-ec4b9c49c061` | second plan refused, outcome `halted` |
| AI step failure (F-04) | `efc4fc94-6f71-40ae-8d00-01947f322409` (probe) | AO continued; Plan: no recommendation -> approval |
| Approval expired (F-08) | `6156f6bd-395e-453b-a5b8-89b23ed0b768` | 1-hour window passed -> recorded `expired` from AO, outcome `expired`, incident opened |
| **Rejected** (F-07) | `32d3a298-141b-4f65-a3d0-cde21400e527` | user rejected in AO -> recorded `rejected`, cooldown, incident updated |
| **Remediation failed -> approved rollback** (F-09, A2-6) | `837563b6-29d1-4157-bfe2-092ed2ff1909` | attach succeeded, detach denied (test fault) -> `failed` -> user approved rollback -> `rolled_back` (pre-state re-read) |
| **Success** (A2-2) | `44f55f3e-e831-49f8-b767-9edeee6f5ccd` | user approved -> executed -> `verified` -> finding resolved, ServiceNow incident resolved; 4.8 minutes excluding the approval |

More behavior confirmed on this AO build:

- An agentic step with `continue_on_failure` lets the run continue, but a later reference to a property it did not
  produce (`${activity_recommend.result.content}`) fails that step. WF-02 passes the whole step output
  (`${activity_recommend}`), which resolves on success and failure.
- The whole AI step output reaches AAP as `{agent_type, id, result, status, timestamp}` on success and
  `{error, output, status, invocation_id, ...}` on failure.
- An expired approval is reported with the error "did not finish within 30 seconds (configured in the node Timeout
  setting)", although the run waited the full `decision_window` (3600 s); the approval status is `expired`.

## Earlier proofs (T0.08)

| Workflow | Execution |
|---|---|
| AI Governance - Loader Test (as code) | `abd98b0a`, ran AAP Check Environment |
| AI Governance - LLM Smoke Test (as code) | `19557e83`, structured output from `llama-scout-17b` |
