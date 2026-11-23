# AAP launch guard for the Execute Remediation and Rollback Remediation job templates (task T2.11,
# docs/plan/04 section 7.3, failure case F-18). AAP policy-as-code queries
#   POST /v1/data/aap/remediation_guard/decision   (job template opa_query_path: aap/remediation_guard/decision)
# with the launch (created_by, extra_vars, job_template, launch_type, ...) and refuses the launch unless "allowed".
# This stops anyone launching a remediation directly in AAP and bypassing automation orchestrator (approval, OPA plan).
package aap.remediation_guard

cfg := object.get(data.governance.config, "aap_guard", {})

launcher := object.get(object.get(input, "created_by", {}), "username", "")

# Team names, whether AAP sends names or team objects
launcher_teams contains t if {
	some t in object.get(object.get(input, "created_by", {}), "teams", [])
	is_string(t)
}

launcher_teams contains t.name if {
	some t in object.get(object.get(input, "created_by", {}), "teams", [])
	is_object(t)
}

break_glass if {
	some t in launcher_teams
	t in object.get(cfg, "break_glass_teams", [])
}

violations contains sprintf("%s may not launch %s: only %s or a member of %s may (launch remediations through automation orchestrator)", [launcher, template, concat(", ", object.get(cfg, "allowed_users", [])), concat(", ", object.get(cfg, "break_glass_teams", []))]) if {
	not launcher in object.get(cfg, "allowed_users", [])
	not break_glass
}

violations contains sprintf("extra variable %s is not allowed (only %s)", [k, concat(", ", object.get(cfg, "allowed_extra_vars", []))]) if {
	some k, _ in object.get(input, "extra_vars", {})
	not k in object.get(cfg, "allowed_extra_vars", [])
}

violations contains "remediation is disabled in the published governance settings" if {
	not object.get(object.get(data.governance.config, "remediation", {}), "enabled", false)
}

template := object.get(object.get(input, "job_template", {}), "name", "this job template")

decision := {"allowed": count(violations) == 0, "violations": sort([v | some v in violations])}
