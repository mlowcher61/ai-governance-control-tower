# METADATA
# title: Deterministic risk score (docs/plan/03 section 6.6)
# description: >-
#   Points per factor come from data.governance.config.risk_weights, so they can be tuned without code changes.
#   Each unknown result adds points (capped), so incomplete evidence raises risk instead of lowering it.
#   Categories: critical >= 70, high 45-69, medium 21-44, low <= 20 (thresholds in risk_categories).
package governance.risk

import data.governance.lib

w := data.governance.config.risk_weights

decisions := {r.policy_id: r.decision | some id; r := data.governance.policies[id].result}

failed(policy_id) if decisions[policy_id] == "fail"

unknown_count := count([id | some id, d in decisions; d == "unknown"])

factors contains {"factor": "admin_permissions", "points": w.admin_permissions} if failed("AIGOV-IAM-001")

factors contains {"factor": "sensitive_data_without_approval", "points": w.sensitive_data_without_approval} if failed("AIGOV-DATA-001")

factors contains {"factor": "unregistered_agent", "points": w.unregistered_agent} if failed("AIGOV-REG-001")

factors contains {"factor": "dangerous_permissions", "points": w.dangerous_permissions} if failed("AIGOV-IAM-002")

factors contains {"factor": "high_risk_tools_unapproved", "points": w.high_risk_tools_unapproved} if failed("AIGOV-TOOL-001")

factors contains {"factor": "no_approved_owner", "points": w.no_approved_owner} if failed("AIGOV-OWN-001")

factors contains {"factor": "unapproved_model", "points": w.unapproved_model} if failed("AIGOV-MDL-001")

factors contains {"factor": "sensitive_data_present", "points": w.sensitive_data_present} if lib.sensitive_present

factors contains {"factor": "production_environment", "points": w.production_environment} if lib.is_production

factors contains {"factor": "insufficient_evidence", "points": min([unknown_count * w.insufficient_evidence_each, w.insufficient_evidence_max])} if {
	unknown_count > 0
}

score := min([sum([f.points | some f in factors]), 100])

thresholds := data.governance.config.risk_categories

category := "critical" if {
	score >= thresholds.critical
} else := "high" if {
	score >= thresholds.high
} else := "medium" if {
	score >= thresholds.medium
} else := "low"

factor_list := sort_by_points([f | some f in factors])

# Highest points first, then by name, so the output is stable.
sort_by_points(fs) := [f |
	some pair in sort([[0 - x.points, x.factor] | some x in fs])
	some f in fs
	f.factor == pair[1]
]
