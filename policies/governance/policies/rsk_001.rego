# METADATA
# title: AIGOV-RSK-001 - production agents have a completed, current risk assessment
package governance.policies.rsk_001

import data.governance.lib

meta := {
	"policy_id": "AIGOV-RSK-001",
	"version": "1.0.0",
	"title": "Production agents must have a completed, unexpired risk assessment",
	"severity": "high",
	"remediation": {
		"summary": "Complete or renew the AI risk assessment and record it in the governance registry.",
		"action_types": [],
		"automatable": false,
	},
}

assessment := input.registration.risk_assessment if input.registration.status == "registered"

complete if assessment.status == "complete"

current if lib.not_expired(assessment.expires_at)

problem := "the agent is not registered, so no risk assessment is recorded" if {
	input.registration.status != "registered"
} else := "no risk assessment is recorded" if {
	not is_object(assessment)
} else := sprintf("the risk assessment is %s, not complete", [object.get(assessment, "status", "missing")]) if {
	not complete
} else := sprintf("the risk assessment %s expired on %s", [object.get(assessment, "reference", ""), object.get(assessment, "expires_at", "?")]) if {
	not current
}

decision := "not_applicable" if {
	not lib.is_production
} else := "unknown" if {
	not lib.collected("registration")
} else := "fail" if {
	problem
} else := "pass"

explanation := sprintf("Applies to production agents; this agent is in %s.", [lib.effective_environment]) if {
	decision == "not_applicable"
} else := lib.unknown_explanation("registration") if {
	decision == "unknown"
} else := sprintf("Production agent fails the risk assessment requirement: %s.", [problem]) if {
	decision == "fail"
} else := sprintf("Risk assessment %s is complete and valid until %s.", [assessment.reference, assessment.expires_at])

evidence := [{"path": "registration.risk_assessment", "value": object.get(input.registration, "risk_assessment", null)}]

result := lib.result(meta, decision, explanation, evidence)
