# METADATA
# title: AIGOV-TAG-001 - production agents carry the required tags with valid values
package governance.policies.tag_001

import data.governance.lib

meta := {
	"policy_id": "AIGOV-TAG-001",
	"version": "1.0.0",
	"title": "Production agents must carry the required governance tags with valid values",
	"severity": "medium",
	"remediation": {
		"summary": "Add the missing governance tags (owner, environment, data classification, cost center) with valid values.",
		"action_types": ["bedrock_apply_governance_tags"],
		"automatable": true,
	},
}

cfg := data.governance.config

tags := object.get(input.agent, "tags", {})

problems contains sprintf("missing tag %s", [k]) if {
	some k in cfg.required_production_tags
	trim_space(object.get(tags, k, "")) == ""
}

problems contains sprintf("tag %s has invalid value '%s'", [k, tags[k]]) if {
	k := cfg.tag_keys.environment
	tags[k]
	not lower(tags[k]) in cfg.known_environments
}

problems contains sprintf("tag %s has invalid value '%s'", [k, tags[k]]) if {
	k := cfg.tag_keys.data_classification
	tags[k]
	not lower(tags[k]) in cfg.data_classifications
}

decision := "not_applicable" if {
	not lib.is_production
} else := "unknown" if {
	not lib.collected("tags")
} else := "fail" if {
	count(problems) > 0
} else := "pass"

explanation := sprintf("Applies to production agents; this agent is in %s.", [lib.effective_environment]) if {
	decision == "not_applicable"
} else := lib.unknown_explanation("tags") if {
	decision == "unknown"
} else := sprintf("Governance tags are incomplete: %s.", [concat("; ", sort(problems))]) if {
	decision == "fail"
} else := "All required governance tags are present with valid values."

evidence := [{"path": "agent.tags", "value": tags}]

result := lib.result(meta, decision, explanation, evidence)
