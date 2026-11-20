# METADATA
# title: AIGOV-MDL-001 - approved foundation models only
# description: >-
#   Uses the discovered model when the platform reports it; otherwise the model the owner declared in the
#   registry (assumption value_declared_by_owner). AgentCore never reports the model.
package governance.policies.mdl_001

import data.governance.lib

meta := {
	"policy_id": "AIGOV-MDL-001",
	"version": "1.0.0",
	"title": "Agents may use only approved foundation models",
	"severity": "medium",
	"remediation": {
		"summary": "Move the agent to an approved foundation model, or request a model approval exception.",
		"automatable": false,
	},
}

declared_model := input.registration.declared_model if {
	input.registration.status == "registered"
	is_string(input.registration.declared_model)
}

discovered_model := input.agent.foundation_model if {
	lib.collected("model")
	is_string(input.agent.foundation_model)
}

model := discovered_model if {
	discovered_model
} else := declared_model

extra_assumptions contains "value_declared_by_owner" if {
	not discovered_model
	declared_model
}

decision := "unknown" if {
	not model
} else := "fail" if {
	not model in data.governance.config.approved_models
} else := "pass"

explanation := sprintf("Foundation model unknown: model evidence is '%s' and the registry declares no model.", [lib.evidence_status("model")]) if {
	decision == "unknown"
} else := sprintf("Model %s is not on the approved model list.", [model]) if {
	decision == "fail"
} else := sprintf("Model %s is approved.", [model])

evidence := [
	{"path": "agent.foundation_model", "value": object.get(input.agent, "foundation_model", null)},
	{"path": "registration.declared_model", "value": object.get(input.registration, "declared_model", null)},
]

result := lib.result_with_assumptions(meta, decision, explanation, evidence, extra_assumptions)
