# METADATA
# title: Remediation route (docs/plan/04 section 7.2)
# description: >-
#   Queried by the Plan job: POST /v1/data/governance/remediation/route/decision with input
#   {authz: <authz decision>, dry_run_succeeded, ai_agrees, blast_radius: {shared_role}}. The first matching
#   rule wins: halt, simulate, approval or auto. Anything uncertain (AI disagrees or is invalid, blast radius
#   unknown) forces human approval; only a clean, eligible, low-impact case runs automatically.
package governance.remediation.route

a := object.get(input, "authz", {})

blast := object.get(object.get(input, "blast_radius", {}), "shared_role", "unknown")

route := "halt" if {
	object.get(a, "route_precheck", "") != "eligible"
} else := "simulate" if {
	a.mode == "dry_run"
} else := "halt" if {
	object.get(input, "dry_run_succeeded", "no") != "yes"
} else := "approval" if {
	a.approval_required != "no"
} else := "approval" if {
	object.get(input, "ai_agrees", "unknown") != "yes"
} else := "approval" if {
	blast != "no"
} else := "auto"

reason := sprintf("not eligible: %s (%s)", [object.get(a, "route_precheck", "missing"), concat("; ", object.get(a, "reasons", []))]) if {
	object.get(a, "route_precheck", "") != "eligible"
} else := "dry-run mode: the change is only simulated" if {
	a.mode == "dry_run"
} else := "the check-mode dry run did not succeed" if {
	object.get(input, "dry_run_succeeded", "no") != "yes"
} else := sprintf("approval required: %s", [concat("; ", a.reasons)]) if {
	a.approval_required != "no"
} else := sprintf("the AI recommendation does not agree (%s)", [object.get(input, "ai_agrees", "unknown")]) if {
	object.get(input, "ai_agrees", "unknown") != "yes"
} else := sprintf("the execution role may be shared (%s)", [blast]) if {
	blast != "no"
} else := "eligible, low impact, AI agrees, role not shared"

decision := {"route": route, "reason": reason, "bundle_revision": data.governance.config.bundle_revision}
