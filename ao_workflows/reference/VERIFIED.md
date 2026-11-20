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

## Earlier proofs (T0.08)

| Workflow | Execution |
|---|---|
| AI Governance - Loader Test (as code) | `abd98b0a`, ran AAP Check Environment |
| AI Governance - LLM Smoke Test (as code) | `19557e83`, structured output from `llama-scout-17b` |
