# METADATA
# title: AIGOV-TOOL-001 - high-risk built-in tools require explicit approval
package governance.policies.tool_001

import data.governance.lib

meta := {
	"policy_id": "AIGOV-TOOL-001",
	"version": "1.0.0",
	"title": "High-risk built-in tools require explicit approval",
	"severity": "high",
	"remediation": {
		"summary": "Disable the high-risk tool, or record its approval in the agent's registration (approved_tools).",
		"automatable": false,
	},
}

approved := {t | some t in object.get(input.registration, "approved_tools", [])}

unapproved contains t.parent_signature if {
	some t in input.tools
	t.parent_signature in data.governance.config.high_risk_tool_signatures
	upper(object.get(t, "state", "ENABLED")) != "DISABLED"
	not t.parent_signature in approved
}

decision := "not_applicable" if {
	lib.unsupported("tools")
} else := "unknown" if {
	not lib.collected("tools")
} else := "fail" if {
	count(unapproved) > 0
} else := "pass"

explanation := "The platform does not link tools to the agent in its control plane." if {
	decision == "not_applicable"
} else := lib.unknown_explanation("tools") if {
	decision == "unknown"
} else := sprintf("High-risk tools are enabled without approval: %s.", [concat(", ", sort(unapproved))]) if {
	decision == "fail"
} else := "No unapproved high-risk tools are enabled."

evidence := [{"path": "tools", "value": sort(unapproved)}]

result := lib.result(meta, decision, explanation, evidence)
