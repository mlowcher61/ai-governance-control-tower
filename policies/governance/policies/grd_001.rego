# METADATA
# title: AIGOV-GRD-001 - production Bedrock Agents Classic agents have a guardrail
package governance.policies.grd_001

import data.governance.lib

meta := {
	"policy_id": "AIGOV-GRD-001",
	"version": "1.0.0",
	"title": "Production Bedrock Agents Classic agents must have a guardrail attached",
	"severity": "medium",
	"remediation": {
		"summary": "Attach an approved Amazon Bedrock guardrail to the agent.",
		"action_types": ["bedrock_attach_guardrail"],
		"automatable": false,
	},
}

decision := "not_applicable" if {
	input.agent.platform != "aws.bedrock_agents_classic"
} else := "not_applicable" if {
	not lib.is_production
} else := "unknown" if {
	not lib.collected("agent")
} else := "fail" if {
	not is_object(input.agent.guardrail)
} else := "pass"

explanation := "Applies to production Bedrock Agents Classic agents only." if {
	decision == "not_applicable"
} else := lib.unknown_explanation("agent") if {
	decision == "unknown"
} else := "Production agent has no guardrail attached." if {
	decision == "fail"
} else := sprintf("Guardrail %v is attached.", [input.agent.guardrail.identifier])

evidence := [{"path": "agent.guardrail", "value": object.get(input.agent, "guardrail", null)}]

result := lib.result(meta, decision, explanation, evidence)
