# METADATA
# title: AIGOV-DATA-001 - sensitive data requires a current approval
# description: >-
#   Sensitivity comes from the agent's data sources, its DataClassification tag, or the registry. AgentCore
#   exposes no data sources (evidence not_supported), so the tag or registry classification decides there.
package governance.policies.data_001

import data.governance.lib

meta := {
	"policy_id": "AIGOV-DATA-001",
	"version": "1.0.0",
	"title": "Agents accessing sensitive data require a current data-governance approval",
	"severity": "high",
	"remediation": {
		"summary": "Obtain a data-governance approval for the agent, or remove its access to the sensitive data.",
		"action_types": ["agent_restrict_pending_review"],
		"automatable": false,
	},
}

cfg := data.governance.config

approval := input.registration.sensitive_data_approval if input.registration.status == "registered"

approval_valid if {
	is_string(approval.approved_at)
	lib.not_expired(approval.expires_at)
}

sensitive_sources contains ds.external_id if {
	some ds in input.data_sources
	lower(ds.classification) in cfg.sensitive_classifications
}

sensitive_sources contains sprintf("tag %s=%s", [cfg.tag_keys.data_classification, lib.tag_classification]) if {
	lib.tag_classification in cfg.sensitive_classifications
}

sensitive_sources contains sprintf("registry classification %s", [lib.registry_classification]) if {
	lib.registry_classification in cfg.sensitive_classifications
}

unclassified_sources contains ds.external_id if {
	some ds in input.data_sources
	not is_string(ds.classification)
}

# Data sources not inspected: fine only when the sensitivity is known another way.
sources_unknown if {
	not lib.collected("data_sources")
	not lib.unsupported("data_sources")
}

sources_unknown if {
	lib.unsupported("data_sources")
	count(lib.known_classifications) == 0
}

decision := "fail" if {
	count(sensitive_sources) > 0
	not approval_valid
} else := "unknown" if {
	sources_unknown
} else := "unknown" if {
	count(unclassified_sources) > 0
	count(sensitive_sources) == 0
} else := "pass"

explanation := sprintf("Agent accesses sensitive data (%s) without a current data-governance approval.", [concat(", ", sort(sensitive_sources))]) if {
	decision == "fail"
} else := lib.unknown_explanation("data_sources") if {
	sources_unknown
} else := sprintf("Data sources %s have no classification; sensitivity cannot be determined.", [concat(", ", sort(unclassified_sources))]) if {
	decision == "unknown"
} else := sprintf("Sensitive data (%s) is covered by approval %s until %s.", [concat(", ", sort(sensitive_sources)), approval.reference, approval.expires_at]) if {
	count(sensitive_sources) > 0
} else := sprintf("No sensitive data detected (classification: %s).", [concat(", ", sort(lib.known_classifications))])

evidence := [
	{"path": "data_classification", "value": sort(lib.known_classifications)},
	{"path": "registration.sensitive_data_approval", "value": object.get(input.registration, "sensitive_data_approval", null)},
]

result := lib.result(meta, decision, explanation, evidence)
