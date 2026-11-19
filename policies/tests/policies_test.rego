# Unit tests for the governance policies. Run: opa test --coverage policies/governance policies/data policies/tests
# Each test starts from a compliant production agent (base) and changes one thing.
package governance.tests

import data.governance.evaluate
import data.governance.policies
import data.governance.risk

admin_arn := "arn:aws:iam::aws:policy/AdministratorAccess"

approved_policy := {
	"type": "customer_managed", "ref": "arn:aws:iam::111122223333:policy/aigov/approved", "name": "approved",
	"statements": [{"effect": "Allow", "actions": ["bedrock:InvokeModel"], "resources": ["arn:aws:bedrock:*::foundation-model/amazon.nova-*"]}],
}

base := {
	"schema_version": "1.0",
	"evaluation": {"governance_run_id": "6f1c0000-0000-4000-8000-0000000000aa", "evaluated_at": "2026-11-17T15:04:05Z", "purpose": "assessment"},
	"agent": {
		"id": "0b7a0000-0000-4000-8000-000000000001", "provider": "aws", "platform": "aws.bedrock_agentcore_runtime",
		"external_id": "rt-1", "resource_ref": "arn:aws:bedrock-agentcore:us-west-1:111122223333:runtime/rt-1",
		"name": "payments", "account_ref": "111122223333", "region": "us-west-1", "environment": "production",
		"status": "READY", "foundation_model": null, "guardrail": null, "attributes": {},
		"tags": {"Environment": "production", "Owner": "o@example.com", "DataClassification": "confidential", "CostCenter": "CC-1"},
	},
	"identity": {
		"principal_ref": "arn:aws:iam::111122223333:role/r", "permissions_boundary_ref": null, "policies": [approved_policy],
		"simulation": {"iam:CreateUser": "denied", "iam:AttachRolePolicy": "denied", "iam:PutRolePolicy": "denied"},
	},
	"tools": [], "data_sources": [],
	"registration": {
		"status": "registered", "registration_id": "REG-0001",
		"owner": {"id": "own", "name": "Owner", "approved": true, "approved_by": "ciso", "approved_at": "2026-08-15T00:00:00Z"},
		"business_purpose": "p", "environment": "production", "data_classification": "confidential",
		"declared_model": "amazon.nova-pro-v1:0", "approved_tools": [],
		"risk_assessment": {"status": "complete", "reference": "RA-1", "completed_at": "2026-09-01T00:00:00Z", "expires_at": "2027-09-01T00:00:00Z"},
		"sensitive_data_approval": {"reference": "DA-1", "approved_by": "ciso", "approved_at": "2026-09-05T00:00:00Z", "expires_at": "2027-09-05T00:00:00Z"},
	},
	"evidence": {
		"agent": "collected", "tags": "collected", "identity": "collected", "identity_simulation": "collected",
		"tools": "not_supported", "data_sources": "not_supported", "model": "not_supported", "registration": "collected",
	},
}

# Replace (not deep-merge) the patched keys: object.union merges nested objects, which would keep old values.
patched(obj, patch) := object.union(object.remove(obj, object.keys(patch)), patch)

with_agent(patch) := patched(base, {"agent": patched(base.agent, patch)})

with_reg(patch) := patched(base, {"registration": patched(base.registration, patch)})

with_evidence(patch) := patched(base, {"evidence": patched(base.evidence, patch)})

with_identity(patch) := patched(base, {"identity": patched(base.identity, patch)})

unregistered := patched(base, {"registration": {"status": "unregistered"}})

decision(pkg, inp) := d if {
	d := policies[pkg].result.decision with input as inp
}

# ---- The baseline is compliant, low risk ----------------------------------------------------------------
test_base_is_compliant if {
	r := evaluate.result with input as base
	r.overall_status == "compliant"
	r.risk == {"score": 20, "category": "low", "factors": [
		{"factor": "production_environment", "points": 10},
		{"factor": "sensitive_data_present", "points": 10},
	]}
	r.summary == {"pass": 8, "fail": 0, "unknown": 0, "not_applicable": 2, "error": 0}
	every x in r.results { x.remediation == null }
}

test_controls_come_from_data if {
	r := policies.iam_001.result with input as base
	"CIS-AWS-v7:7.1.3" in r.controls
}

# ---- REG-001 -------------------------------------------------------------------------------------------------
test_reg_unregistered_fails if {
	r := policies.reg_001.result with input as unregistered
	r.decision == "fail"
	r.remediation.automatable == false
	contains(r.explanation, "shadow")
}

test_reg_unknown_without_registration_evidence if decision("reg_001", with_evidence({"registration": "error"})) == "unknown"

# ---- OWN-001 -------------------------------------------------------------------------------------------------
test_own_unapproved_owner_fails if {
	decision("own_001", with_reg({"owner": patched(base.registration.owner, {"approved": false})})) == "fail"
}

test_own_not_applicable_outside_production if {
	inp := patched(with_agent({"environment": "development"}), {"registration": patched(base.registration, {"environment": "development"})})
	decision("own_001", inp) == "not_applicable"
}

test_own_unknown_without_registration_evidence if decision("own_001", with_evidence({"registration": "access_denied"})) == "unknown"

# ---- Environment ----------------------------------------------------------------------------------------------
test_unknown_environment_is_production_with_assumption if {
	inp := patched(with_agent({"environment": null}), {"registration": {"status": "unregistered"}})
	r := policies.own_001.result with input as inp
	r.decision == "fail"
	"environment_assumed_production" in r.assumptions
}

test_registry_environment_used_when_tag_missing if {
	inp := patched(with_agent({"environment": null}), {"registration": patched(base.registration, {"environment": "development"})})
	decision("rsk_001", inp) == "not_applicable"
}

# ---- TAG-001 -------------------------------------------------------------------------------------------------
test_tag_missing_and_invalid_values_fail if {
	inp := with_agent({"tags": {"Environment": "prod-ish", "Owner": "o", "DataClassification": "secret"}})
	r := policies.tag_001.result with input as inp
	r.decision == "fail"
	contains(r.explanation, "missing tag CostCenter")
	contains(r.explanation, "Environment has invalid value")
	contains(r.explanation, "DataClassification has invalid value")
}

test_tag_unknown_when_tags_not_collected if decision("tag_001", with_evidence({"tags": "access_denied"})) == "unknown"

test_tag_not_applicable_in_development if {
	inp := patched(with_agent({"environment": "development"}), {"registration": patched(base.registration, {"environment": "development"})})
	decision("tag_001", inp) == "not_applicable"
}

# ---- IAM-001 -------------------------------------------------------------------------------------------------
admin_policy := {"type": "aws_managed", "ref": admin_arn, "name": "AdministratorAccess", "statements": [{"effect": "Allow", "actions": ["*"], "resources": ["*"]}]}

test_iam_admin_managed_policy_fails_with_simulation_evidence if {
	inp := with_identity({"policies": [admin_policy], "simulation": {"iam:CreateUser": "allowed", "iam:AttachRolePolicy": "allowed", "iam:PutRolePolicy": "allowed"}})
	r := policies.iam_001.result with input as inp
	r.decision == "fail"
	r.remediation.automatable == true
	contains(r.explanation, "policy simulation confirms")
	count(r.evidence) == 5
}

test_iam_inline_wildcard_fails if {
	p := {"type": "inline", "ref": "x", "name": "x", "statements": [{"effect": "Allow", "actions": ["iam:*"], "resources": ["*"]}]}
	decision("iam_001", with_identity({"policies": [p]})) == "fail"
}

test_iam_notaction_on_star_fails if {
	p := {"type": "inline", "ref": "x", "name": "x", "statements": [{"effect": "Allow", "actions": [], "not_actions": ["iam:*"], "resources": ["*"]}]}
	decision("iam_001", with_identity({"policies": [p]})) == "fail"
}

test_iam_boundary_with_denied_probes_neutralizes if {
	inp := with_identity({"policies": [admin_policy], "permissions_boundary_ref": "arn:aws:iam::1:policy/boundary"})
	decision("iam_001", inp) == "pass"
}

test_iam_boundary_without_simulation_does_not_neutralize if {
	inp := patched(with_identity({"policies": [admin_policy], "permissions_boundary_ref": "arn:aws:iam::1:policy/boundary"}), {"evidence": patched(base.evidence, {"identity_simulation": "access_denied"})})
	decision("iam_001", inp) == "fail"
}

test_iam_unknown_without_identity if decision("iam_001", with_evidence({"identity": "access_denied"})) == "unknown"

test_iam_deny_statement_is_not_a_grant if {
	p := {"type": "inline", "ref": "x", "name": "x", "statements": [{"effect": "Deny", "actions": ["*"], "resources": ["*"]}]}
	decision("iam_001", with_identity({"policies": [approved_policy, p]})) == "pass"
}

# ---- IAM-002 -------------------------------------------------------------------------------------------------
test_iam2_dangerous_wildcard_fails if {
	p := {"type": "inline", "ref": "x", "name": "x", "statements": [{"effect": "Allow", "actions": ["secretsmanager:*", "s3:*"], "resources": ["*"]}]}
	r := policies.iam_002.result with input as with_identity({"policies": [p]})
	r.decision == "fail"
	contains(r.explanation, "secretsmanager:*")
}

test_iam2_specific_bedrock_action_is_not_dangerous if decision("iam_002", base) == "pass"

test_iam2_full_admin_left_to_iam_001 if decision("iam_002", with_identity({"policies": [admin_policy]})) == "pass"

test_iam2_unknown_without_identity if decision("iam_002", with_evidence({"identity": "error"})) == "unknown"

# ---- DATA-001 ------------------------------------------------------------------------------------------------
test_data_sensitive_tag_without_approval_fails if {
	r := policies.data_001.result with input as with_reg({"sensitive_data_approval": null})
	r.decision == "fail"
	contains(r.explanation, "DataClassification=confidential")
}

test_data_expired_approval_fails if {
	a := patched(base.registration.sensitive_data_approval, {"expires_at": "2026-01-01T00:00:00Z"})
	decision("data_001", with_reg({"sensitive_data_approval": a})) == "fail"
}

test_data_not_sensitive_passes if {
	inp := patched(with_agent({"tags": patched(base.agent.tags, {"DataClassification": "internal"})}), {"registration": patched(base.registration, {"data_classification": "internal", "sensitive_data_approval": null})})
	decision("data_001", inp) == "pass"
}

test_data_unknown_when_no_classification_anywhere if {
	inp := patched(with_agent({"tags": object.remove(base.agent.tags, ["DataClassification"])}), {"registration": {"status": "unregistered"}})
	decision("data_001", inp) == "unknown"
}

test_data_unknown_when_sources_denied if {
	inp := patched(with_evidence({"data_sources": "access_denied"}), {"agent": patched(base.agent, {"tags": patched(base.agent.tags, {"DataClassification": "internal"})}), "registration": patched(base.registration, {"data_classification": "internal"})})
	decision("data_001", inp) == "unknown"
}

test_data_unclassified_source_is_unknown if {
	inp := patched(base, {
		"evidence": patched(base.evidence, {"data_sources": "collected"}),
		"data_sources": [{"type": "knowledge_base", "external_id": "KB1", "classification": null}],
		"agent": patched(base.agent, {"tags": patched(base.agent.tags, {"DataClassification": "internal"})}),
		"registration": patched(base.registration, {"data_classification": "internal"}),
	})
	decision("data_001", inp) == "unknown"
}

test_data_restricted_source_fails_even_if_tag_is_internal if {
	inp := patched(base, {
		"evidence": patched(base.evidence, {"data_sources": "collected"}),
		"data_sources": [{"type": "knowledge_base", "external_id": "KB1", "classification": "restricted"}],
		"agent": patched(base.agent, {"tags": patched(base.agent.tags, {"DataClassification": "internal"})}),
		"registration": patched(base.registration, {"data_classification": "internal", "sensitive_data_approval": null}),
	})
	decision("data_001", inp) == "fail"
}

# ---- MDL-001 -------------------------------------------------------------------------------------------------
test_mdl_declared_model_passes_with_assumption if {
	r := policies.mdl_001.result with input as base
	r.decision == "pass"
	"value_declared_by_owner" in r.assumptions
}

test_mdl_unapproved_declared_model_fails if decision("mdl_001", with_reg({"declared_model": "some.unapproved-model"})) == "fail"

test_mdl_discovered_model_wins if {
	inp := patched(with_agent({"foundation_model": "some.unapproved-model"}), {"evidence": patched(base.evidence, {"model": "collected"})})
	r := policies.mdl_001.result with input as inp
	r.decision == "fail"
	not "value_declared_by_owner" in r.assumptions
}

test_mdl_unknown_without_any_model if decision("mdl_001", with_reg({"declared_model": null})) == "unknown"

# ---- RSK-001 -------------------------------------------------------------------------------------------------
test_rsk_expired_fails if {
	ra := patched(base.registration.risk_assessment, {"expires_at": "2026-06-01T00:00:00Z"})
	r := policies.rsk_001.result with input as with_reg({"risk_assessment": ra})
	r.decision == "fail"
	contains(r.explanation, "expired on 2026-06-01")
}

test_rsk_incomplete_fails if {
	ra := patched(base.registration.risk_assessment, {"status": "in_progress"})
	decision("rsk_001", with_reg({"risk_assessment": ra})) == "fail"
}

test_rsk_missing_fails if decision("rsk_001", with_reg({"risk_assessment": null})) == "fail"

test_rsk_unregistered_fails if decision("rsk_001", unregistered) == "fail"

test_rsk_unknown_without_registration_evidence if decision("rsk_001", with_evidence({"registration": "error"})) == "unknown"

# ---- TOOL-001 ------------------------------------------------------------------------------------------------
classic_tools(tools, approved) := patched(base, {
	"evidence": patched(base.evidence, {"tools": "collected"}),
	"tools": tools,
	"registration": patched(base.registration, {"approved_tools": approved}),
})

test_tool_not_applicable_when_platform_has_no_tools if decision("tool_001", base) == "not_applicable"

test_tool_unapproved_high_risk_tool_fails if {
	inp := classic_tools([{"type": "action_group", "external_id": "ag1", "parent_signature": "AMAZON.CodeInterpreter", "state": "ENABLED"}], [])
	decision("tool_001", inp) == "fail"
}

test_tool_approved_or_disabled_passes if {
	t := [
		{"type": "action_group", "external_id": "ag1", "parent_signature": "AMAZON.CodeInterpreter", "state": "ENABLED"},
		{"type": "action_group", "external_id": "ag2", "parent_signature": "ANTHROPIC.Bash", "state": "DISABLED"},
	]
	decision("tool_001", classic_tools(t, ["AMAZON.CodeInterpreter"])) == "pass"
}

test_tool_unknown_when_denied if decision("tool_001", with_evidence({"tools": "access_denied"})) == "unknown"

# ---- GRD-001 -------------------------------------------------------------------------------------------------
classic := with_agent({"platform": "aws.bedrock_agents_classic"})

test_grd_not_applicable_for_agentcore if decision("grd_001", base) == "not_applicable"

test_grd_classic_without_guardrail_fails if decision("grd_001", classic) == "fail"

test_grd_classic_with_guardrail_passes if {
	decision("grd_001", patched(classic, {"agent": patched(classic.agent, {"guardrail": {"identifier": "gr-1", "version": "1"}})})) == "pass"
}

test_grd_unknown_when_agent_not_collected if decision("grd_001", patched(classic, {"evidence": patched(base.evidence, {"agent": "error"})})) == "unknown"

test_grd_not_applicable_outside_production if {
	inp := patched(classic, {"agent": patched(classic.agent, {"environment": "development"}), "registration": patched(base.registration, {"environment": "development"})})
	decision("grd_001", inp) == "not_applicable"
}

# ---- Aggregate and risk ----------------------------------------------------------------------------------------
test_unknown_raises_risk_and_status if {
	r := evaluate.result with input as with_reg({"declared_model": null})
	r.overall_status == "unknown"
	{"factor": "insufficient_evidence", "points": 5} in r.risk.factors
}

test_insufficient_evidence_cap if {
	inp := with_evidence({"identity": "error", "tags": "error", "registration": "error"})
	[f | some f in risk.factors; f.factor == "insufficient_evidence"] == [{"factor": "insufficient_evidence", "points": 15}] with input as inp
}

test_admin_agent_is_critical_and_capped if {
	inp := patched(unregistered, {
		"agent": patched(base.agent, {"environment": null, "tags": {"DataClassification": "restricted"}}),
		"identity": patched(base.identity, {"policies": [admin_policy]}),
	})
	r := evaluate.result with input as inp
	r.overall_status == "noncompliant"
	r.risk.score == 100
	r.risk.category == "critical"
	r.risk.factors[0] == {"factor": "admin_permissions", "points": 40}
}

test_risk_category_boundaries if {
	risk.category == "low" with risk.score as 20
	risk.category == "medium" with risk.score as 21
	risk.category == "medium" with risk.score as 44
	risk.category == "high" with risk.score as 45
	risk.category == "critical" with risk.score as 70
}

test_invalid_input_is_error if {
	r := evaluate.result with input as {"schema_version": "0.9"}
	r.overall_status == "error"
	"missing agent.id" in r.input_errors
	"unsupported schema_version (expected 1.0)" in r.input_errors
}

test_failing_remediation_only_on_fail if {
	r := evaluate.result with input as unregistered
	every x in r.results {
		(x.decision == "fail") == x.remediation != null
	}
}

test_platform_info_lists_policies if {
	info := data.governance.platform.info
	count(info.policies) == 10
	info.bundle_revision == data.governance.config.bundle_revision
}
