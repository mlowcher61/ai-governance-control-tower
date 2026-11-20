# METADATA
# title: Shared helpers for the AI governance policies
# description: >-
#   Evidence checks, the effective environment, dates and the policy result builder. Every policy returns
#   the contract schemas/policy-result.v1.json through result/5. Policies never read the current time:
#   dates are compared with input.evaluation.evaluated_at, so results are repeatable.
package governance.lib

cfg := data.governance.config

# ---- Evidence (docs/plan/03 section 3.3) -------------------------------------------------------------
collected(domain) if input.evidence[domain] == "collected"

evidence_status(domain) := object.get(input.evidence, domain, "not_collected")

# The platform does not expose this domain at all (for example AgentCore and knowledge bases).
unsupported(domain) if evidence_status(domain) == "not_supported"

unknown_explanation(domain) := sprintf(
	"Cannot evaluate: evidence '%s' has status '%s'. Missing evidence is never treated as compliant.",
	[domain, evidence_status(domain)],
)

# ---- Environment (docs/plan/03 section 6.5 rule 3) ---------------------------------------------------
registered_environment := input.registration.environment if {
	input.registration.status == "registered"
	input.registration.environment in cfg.known_environments
}

effective_environment := input.agent.environment if {
	input.agent.environment in cfg.known_environments
} else := registered_environment if {
	registered_environment
} else := "production" if {
	cfg.unknown_environment_treatment == "assume_production"
} else := "unknown"

environment_assumed if {
	not input.agent.environment in cfg.known_environments
	not registered_environment
	effective_environment == "production"
}

is_production if effective_environment == "production"

assumptions contains "environment_assumed_production" if environment_assumed

# ---- Dates -------------------------------------------------------------------------------------------
evaluated_ns := time.parse_rfc3339_ns(input.evaluation.evaluated_at)

# True when the RFC 3339 timestamp is strictly after the evaluation time.
not_expired(ts) if time.parse_rfc3339_ns(ts) > evaluated_ns

# ---- Data sensitivity ----------------------------------------------------------------------------------
tag_classification := lower(input.agent.tags[cfg.tag_keys.data_classification])

registry_classification := lower(input.registration.data_classification) if {
	input.registration.status == "registered"
	is_string(input.registration.data_classification)
}

# Classifications known for the agent, from data sources, its tag and the registry.
known_classifications contains lower(ds.classification) if {
	some ds in input.data_sources
	is_string(ds.classification)
}

known_classifications contains tag_classification if tag_classification

known_classifications contains registry_classification if registry_classification

sensitive_present if {
	some c in known_classifications
	c in cfg.sensitive_classifications
}

# ---- Results -------------------------------------------------------------------------------------------
result(meta, decision, explanation, evidence) := result_with_assumptions(meta, decision, explanation, evidence, set())

result_with_assumptions(meta, decision, explanation, evidence, extra) := {
	"agent_id": input.agent.id,
	"policy_id": meta.policy_id,
	"policy_version": meta.version,
	"title": meta.title,
	"decision": decision,
	"severity": meta.severity,
	"explanation": explanation,
	"evidence": evidence,
	"assumptions": sort([a | some a in (assumptions | extra)]),
	# Only failing results carry a remediation (schemas/policy-result.v1.json).
	"remediation": remediation_for(meta, decision),
	"controls": object.get(cfg.controls, meta.policy_id, []),
}

# The remediation actions come from data.governance.policy_actions (one source for the policies and for
# remediation authorization, governance.remediation.authz).
remediation_for(meta, "fail") := object.union(
	meta.remediation,
	{"action_types": object.get(data.governance.policy_actions, meta.policy_id, [])},
)

remediation_for(_, decision) := null if decision != "fail"
