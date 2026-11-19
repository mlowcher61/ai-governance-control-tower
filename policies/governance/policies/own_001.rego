# METADATA
# title: AIGOV-OWN-001 - production agents must have an approved owner
package governance.policies.own_001

import data.governance.lib

meta := {
	"policy_id": "AIGOV-OWN-001",
	"version": "1.0.0",
	"title": "Every production AI agent must have an approved owner",
	"severity": "high",
	"remediation": {
		"summary": "Assign an approved owner to the agent in the governance registry.",
		"action_types": [],
		"automatable": false,
	},
}

owner_approved if input.registration.owner.approved == true

decision := "not_applicable" if {
	not lib.is_production
} else := "unknown" if {
	not lib.collected("registration")
} else := "fail" if {
	not owner_approved
} else := "pass"

explanation := sprintf("Applies to production agents; this agent is in %s.", [lib.effective_environment]) if {
	decision == "not_applicable"
} else := lib.unknown_explanation("registration") if {
	decision == "unknown"
} else := "Production agent has no approved owner in the governance registry." if {
	decision == "fail"
} else := sprintf("Approved owner: %s.", [input.registration.owner.name])

evidence := [{"path": "registration.owner", "value": object.get(input.registration, "owner", null)}]

result := lib.result(meta, decision, explanation, evidence)
