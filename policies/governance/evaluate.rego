# METADATA
# title: Aggregate decision for one agent (entry point)
# description: >-
#   POST /v1/data/governance/evaluate/result with {"input": <policy input>} returns the contract
#   schemas/evaluation-result.v1.json. Status order: error (invalid input), noncompliant (any fail), unknown
#   (any unknown), compliant. An agent is compliant only when every policy passed or did not apply.
package governance.evaluate

import data.governance.risk

results := [r | some id; r := data.governance.policies[id].result]

input_errors contains "missing agent.id" if not input.agent.id

input_errors contains "unsupported schema_version (expected 1.0)" if input.schema_version != "1.0"

input_errors contains "missing evaluation.evaluated_at" if not input.evaluation.evaluated_at

input_errors contains "missing evidence" if not is_object(input.evidence)

overall_status := "error" if {
	count(input_errors) > 0
} else := "noncompliant" if {
	some r in results
	r.decision == "fail"
} else := "unknown" if {
	some r in results
	r.decision in {"unknown", "error"}
} else := "compliant"

summary := {d: count([r | some r in results; r.decision == d]) | some d in {"pass", "fail", "unknown", "not_applicable", "error"}}

result := {
	"agent_id": object.get(object.get(input, "agent", {}), "id", ""),
	"overall_status": overall_status,
	"risk": {"score": risk.score, "category": risk.category, "factors": risk.factor_list},
	"results": results,
	"summary": summary,
	"bundle_revision": data.governance.config.bundle_revision,
	"evaluated_at": object.get(object.get(input, "evaluation", {}), "evaluated_at", ""),
	"input_errors": sort(input_errors),
}
