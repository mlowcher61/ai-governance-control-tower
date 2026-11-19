# METADATA
# title: AIGOV-REG-001 - every AI agent must be registered (shadow agent detection)
package governance.policies.reg_001

import data.governance.lib

meta := {
	"policy_id": "AIGOV-REG-001",
	"version": "1.0.0",
	"title": "Every AI agent must be registered in the governance registry",
	"severity": "high",
	"remediation": {
		"summary": "Register the agent with an approved owner and business purpose, or restrict it pending review.",
		"action_types": ["bedrock_apply_governance_tags", "agent_restrict_pending_review"],
		"automatable": false,
	},
}

decision := "unknown" if {
	not lib.collected("registration")
} else := "fail" if {
	input.registration.status != "registered"
} else := "pass"

explanation := lib.unknown_explanation("registration") if {
	decision == "unknown"
} else := sprintf(
	"Agent %s (%s) in account %s was discovered but has no governance registration: it is an unauthorized (shadow) agent.",
	[input.agent.name, input.agent.external_id, input.agent.account_ref],
) if {
	decision == "fail"
} else := sprintf("Agent is registered as %s.", [input.registration.registration_id])

evidence := [{"path": "registration.status", "value": object.get(input.registration, "status", null)}]

result := lib.result(meta, decision, explanation, evidence)
