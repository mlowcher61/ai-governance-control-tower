# Tests for governance.remediation.authz and governance.remediation.route (docs/plan/04 sections 7.1, 7.2).
package governance.remediation_tests

import data.governance.remediation.authz
import data.governance.remediation.route

# The demo profile (policies/overlays/demo/remediation.json) with the demo account allowed
demo := {
	"enabled": true, "mode": "enforce", "allowed_accounts": ["111122223333"],
	"auto_remediation_actions": ["agentcore_apply_governance_tags", "bedrock_apply_governance_tags", "iam_tag_role"],
	"max_attempts": 3, "cooldown_minutes": 60,
}

req := {
	"finding_id": "8d0f0000-0000-4000-8000-000000000001", "policy_id": "AIGOV-IAM-001", "severity": "critical",
	"finding_type": "violation", "environment": "production", "account_ref": "111122223333",
	"platform": "aws.bedrock_agentcore_runtime", "remediation_attempts": 0, "cooldown_active": "no", "exempt": "no",
}

with_req(patch) := object.union(req, patch)

decide(rq) := d if {
	d := authz.decision with input as {"request": rq} with data.governance.config.remediation as demo
}

# ---- The committed default profile is detection-only -----------------------------------------------------
test_committed_default_is_detect_only if {
	data.governance.config.remediation.enabled == false
	data.governance.config.remediation.mode == "detect_only"
	authz.decision.route_precheck == "detect_only" with input as {"request": req}
}

test_detect_only_mode_even_when_enabled if {
	d := authz.decision with input as {"request": req}
		with data.governance.config.remediation as object.union(demo, {"mode": "detect_only"})
	d.route_precheck == "detect_only"
}

# ---- Eligible remediation of the demo admin finding ------------------------------------------------------------
test_admin_finding_is_eligible_with_approval if {
	d := decide(req)
	d.route_precheck == "eligible"
	d.selected_action == "iam_replace_managed_policy"
	d.allowed_actions == ["iam_replace_managed_policy", "iam_remove_inline_policy", "iam_apply_permissions_boundary"]
	d.approval_required == "yes"
	d.auto_remediation_permitted == "no"
	d.impact == "high"
	d.reversible == true
	"critical severity requires approval" in d.reasons
	"environment 'production' requires approval" in d.reasons
	"impact 'high' requires approval" in d.reasons
}

test_applicable_actions_narrow_the_choice if {
	d := decide(with_req({"applicable_actions": ["iam_remove_inline_policy"]}))
	d.selected_action == "iam_remove_inline_policy"
	d.allowed_actions == ["iam_remove_inline_policy"]
}

test_platform_filters_actions if {
	d := decide(with_req({"policy_id": "AIGOV-REG-001", "severity": "high"}))
	d.selected_action == "agentcore_apply_governance_tags"
	not "bedrock_pause_agent_alias" in d.allowed_actions
	c := decide(with_req({"policy_id": "AIGOV-REG-001", "severity": "high", "platform": "aws.bedrock_agents_classic"}))
	c.selected_action == "bedrock_apply_governance_tags"
	"bedrock_pause_agent_alias" in c.allowed_actions
}

test_low_impact_development_tagging_is_auto if {
	d := decide(with_req({"policy_id": "AIGOV-TAG-001", "severity": "medium", "environment": "development"}))
	d.route_precheck == "eligible"
	d.approval_required == "no"
	d.auto_remediation_permitted == "yes"
	d.impact == "low"
}

test_unknown_environment_requires_approval if {
	d := decide(with_req({"policy_id": "AIGOV-TAG-001", "severity": "medium", "environment": "unknown"}))
	d.approval_required == "yes"
	"environment 'unknown' requires approval" in d.reasons
}

test_action_not_on_auto_list_requires_approval if {
	d := decide(with_req({"severity": "high", "environment": "sandbox", "applicable_actions": ["iam_apply_permissions_boundary"]}))
	d.selected_action == "iam_apply_permissions_boundary"
	"action is not on the auto-remediation list" in d.reasons
	"impact 'medium' requires approval" in d.reasons
}

# ---- Every denial ------------------------------------------------------------------------------------------------
denied_with(rq, text) if {
	d := decide(rq)
	d.route_precheck == "denied"
	some reason in d.reasons
	contains(reason, text)
	d.auto_remediation_permitted == "no"
}

test_account_not_allowlisted if denied_with(with_req({"account_ref": "999999999999"}), "not on the remediation allowlist")

test_insufficient_evidence_never_remediated if denied_with(with_req({"finding_type": "insufficient_evidence"}), "never remediated automatically")

test_max_attempts if denied_with(with_req({"remediation_attempts": 3}), "maximum attempts (3) reached")

test_cooldown if denied_with(with_req({"cooldown_active": "yes"}), "cooldown is active")

test_exempt if denied_with(with_req({"exempt": "yes"}), "marked exempt")

test_no_action_for_policy if denied_with(with_req({"policy_id": "AIGOV-RSK-001"}), "no automatable action is defined for AIGOV-RSK-001")

test_no_action_when_platform_lacks_it if {
	denied_with(with_req({"policy_id": "AIGOV-TOOL-001"}), "no automatable action is defined for AIGOV-TOOL-001 on aws.bedrock_agentcore_runtime")
}

test_invalid_request_fails_closed if {
	d := decide({"policy_id": "AIGOV-IAM-001"})
	d.route_precheck == "denied"
	some reason in d.reasons
	startswith(reason, "invalid request: missing")
}

# ---- Route table (docs/plan/04 section 7.2), one test per row ---------------------------------------------------
eligible := decide(req)

eligible_auto := decide(with_req({"policy_id": "AIGOV-TAG-001", "severity": "medium", "environment": "development"}))

route_of(inp) := r if {
	r := route.decision.route with input as inp
}

test_route_1_not_eligible_halts if route_of({"authz": decide(with_req({"exempt": "yes"})), "dry_run_succeeded": "yes"}) == "halt"

test_route_2_dry_run_mode_simulates if {
	d := authz.decision with input as {"request": req} with data.governance.config.remediation as object.union(demo, {"mode": "dry_run"})
	route_of({"authz": d, "dry_run_succeeded": "yes"}) == "simulate"
}

test_route_3_failed_dry_run_halts if route_of({"authz": eligible_auto, "dry_run_succeeded": "no", "ai_agrees": "yes", "blast_radius": {"shared_role": "no"}}) == "halt"

test_route_4_approval_required if route_of({"authz": eligible, "dry_run_succeeded": "yes", "ai_agrees": "yes", "blast_radius": {"shared_role": "no"}}) == "approval"

test_route_5_ai_disagrees_or_invalid_needs_approval if {
	every agrees in ["no", "unknown", "invalid"] {
		route_of({"authz": eligible_auto, "dry_run_succeeded": "yes", "ai_agrees": agrees, "blast_radius": {"shared_role": "no"}}) == "approval"
	}
	route_of({"authz": eligible_auto, "dry_run_succeeded": "yes", "blast_radius": {"shared_role": "no"}}) == "approval"
}

test_route_6_shared_or_unknown_blast_radius_needs_approval if {
	every shared in ["yes", "unknown"] {
		route_of({"authz": eligible_auto, "dry_run_succeeded": "yes", "ai_agrees": "yes", "blast_radius": {"shared_role": shared}}) == "approval"
	}
	route_of({"authz": eligible_auto, "dry_run_succeeded": "yes", "ai_agrees": "yes"}) == "approval"
}

test_route_7_auto if {
	d := route.decision with input as {"authz": eligible_auto, "dry_run_succeeded": "yes", "ai_agrees": "yes", "blast_radius": {"shared_role": "no"}}
	d.route == "auto"
	contains(d.reason, "low impact")
}

test_route_missing_authz_halts if route_of({}) == "halt"

# ---- Consistency of the catalog and the policy-action mapping ---------------------------------------------------
test_every_mapped_action_is_in_the_catalog if {
	every _, actions in data.governance.policy_actions {
		every a in actions {
			data.governance.remediation_catalog[a]
		}
	}
}

test_every_catalog_entry_is_complete if {
	every _, entry in data.governance.remediation_catalog {
		entry.impact in {"low", "medium", "high"}
		count(entry.platforms) > 0
		is_boolean(entry.reversible)
		is_boolean(entry.auto_eligible)
		entry.summary != ""
	}
}

test_every_policy_has_a_mapping if {
	every _, p in data.governance.policies {
		data.governance.policy_actions[p.meta.policy_id]
	}
}

test_auto_list_only_names_auto_eligible_actions if {
	every a in demo.auto_remediation_actions {
		data.governance.remediation_catalog[a].auto_eligible == true
	}
}

test_failing_result_lists_the_mapped_actions if {
	r := data.governance.policies.iam_001.result with input as {
		"schema_version": "1.0",
		"evaluation": {"evaluated_at": "2026-11-17T15:04:05Z"},
		"agent": {"id": "x", "environment": "production", "tags": {}},
		"identity": {"principal_ref": "r", "policies": [{"type": "aws_managed", "ref": "arn:aws:iam::aws:policy/AdministratorAccess", "statements": []}], "simulation": {}},
		"registration": {"status": "unregistered"},
		"evidence": {"identity": "collected", "identity_simulation": "collected"},
	}
	r.decision == "fail"
	r.remediation.action_types == data.governance.policy_actions["AIGOV-IAM-001"]
}
