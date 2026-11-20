# METADATA
# title: AIGOV-IAM-001 - no unrestricted administrative permissions
# description: Automates CIS AWS Foundations v7 7.1.3 (Bedrock agent roles are least privilege), a Manual control.
package governance.policies.iam_001

import data.governance.lib

meta := {
	"policy_id": "AIGOV-IAM-001",
	"version": "1.0.0",
	"title": "Agents must not have unrestricted administrative permissions",
	"severity": "critical",
	"remediation": {
		"summary": "Replace administrator-equivalent policies on the execution role with the approved least-privilege policy, or apply the approved permissions boundary.",
		"automatable": true,
	},
}

cfg := data.governance.config

grant_policies := [p | some p in input.identity.policies; p.type != "boundary"]

admin_grants contains {"source": p.ref, "reason": "administrator-equivalent managed policy"} if {
	some p in grant_policies
	p.ref in cfg.admin_policy_arns
}

admin_grants contains {"source": p.ref, "reason": sprintf("statement allows %s on all resources", [a])} if {
	some p in grant_policies
	some s in p.statements
	s.effect == "Allow"
	some a in s.actions
	a in {"*", "*:*", "iam:*"}
	"*" in s.resources
}

admin_grants contains {"source": p.ref, "reason": "statement uses Allow with NotAction on all resources"} if {
	some p in grant_policies
	some s in p.statements
	s.effect == "Allow"
	count(object.get(s, "not_actions", [])) > 0
	"*" in s.resources
}

# A permissions boundary neutralizes a grant only when simulation proves every admin probe is denied.
boundary_neutralizes if {
	input.identity.permissions_boundary_ref != null
	lib.collected("identity_simulation")
	every probe in cfg.admin_probe_actions {
		object.get(input.identity.simulation, probe, "unknown") == "denied"
	}
}

simulation_allows_admin contains probe if {
	lib.collected("identity_simulation")
	some probe in cfg.admin_probe_actions
	input.identity.simulation[probe] == "allowed"
}

decision := "unknown" if {
	not lib.collected("identity")
} else := "fail" if {
	count(admin_grants) > 0
	not boundary_neutralizes
} else := "pass"

explanation := lib.unknown_explanation("identity") if {
	decision == "unknown"
} else := sprintf(
	"Execution role %s grants administrator-equivalent access (%s)%s.",
	[
		input.identity.principal_ref,
		concat("; ", sort([sprintf("%s: %s", [g.source, g.reason]) | some g in admin_grants])),
		simulation_note,
	],
) if {
	decision == "fail"
} else := "No administrator-equivalent permissions found on the execution role."

simulation_note := sprintf(", and policy simulation confirms %s is allowed", [concat(", ", sort(simulation_allows_admin))]) if {
	count(simulation_allows_admin) > 0
} else := ""

evidence := array.concat(
	[{"path": "identity.policies", "value": g} | some g in admin_grants],
	[{"path": sprintf("identity.simulation.%s", [p]), "value": "allowed"} | some p in simulation_allows_admin],
)

result := lib.result(meta, decision, explanation, evidence)
