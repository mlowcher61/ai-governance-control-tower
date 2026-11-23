# Tests for aap.remediation_guard (T2.11, failure case F-18).
package aap.remediation_guard_test

import data.aap.remediation_guard as guard

enabled := object.union(data.governance.config.remediation, {"enabled": true})

launch(user, teams, vars) := {
	"created_by": {"id": 7, "username": user, "is_superuser": user == "admin", "teams": teams},
	"extra_vars": vars, "job_template": {"id": 117, "name": "AI Governance - Execute Remediation"},
	"launch_type": "manual",
}

ids := {"aigov_governance_run_id": "g", "aigov_remediation_id": "r", "aigov_opa_url": "http://opa:8181", "aigov_aws_region": "us-west-1"}

test_ao_service_account_may_launch if {
	d := guard.decision with input as launch("svc-aigov-ao", [], ids) with data.governance.config.remediation as enabled
	d.allowed
	d.violations == []
}

test_admin_launching_directly_is_denied if {
	d := guard.decision with input as launch("admin", [], ids) with data.governance.config.remediation as enabled
	not d.allowed
	contains(d.violations[0], "admin may not launch AI Governance - Execute Remediation")
}

test_break_glass_team_may_launch_by_name_or_object if {
	guard.decision.allowed with input as launch("oncall", ["AI Governance - Break Glass"], ids)
		with data.governance.config.remediation as enabled
	guard.decision.allowed with input as launch("oncall", [{"id": 3, "name": "AI Governance - Break Glass"}], ids)
		with data.governance.config.remediation as enabled
}

test_other_teams_do_not_help if {
	not guard.decision.allowed with input as launch("dev", [{"name": "Developers"}], ids)
		with data.governance.config.remediation as enabled
}

test_unexpected_extra_variable_is_denied if {
	d := guard.decision with input as launch("svc-aigov-ao", [], object.union(ids, {"aigov_action_type": "iam_detach_everything"}))
		with data.governance.config.remediation as enabled
	not d.allowed
	d.violations == ["extra variable aigov_action_type is not allowed (only aigov_governance_run_id, aigov_remediation_id, aigov_opa_url, aigov_aws_region)"]
}

test_disabled_remediation_denies_everyone if {
	d := guard.decision with input as launch("svc-aigov-ao", [], ids)
	not d.allowed
	d.violations == ["remediation is disabled in the published governance settings"]
}

test_empty_input_is_denied if {
	not guard.decision.allowed with input as {} with data.governance.config.remediation as enabled
}
