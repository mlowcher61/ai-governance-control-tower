# METADATA
# title: Remediation authorization (docs/plan/04 section 7.1)
# description: >-
#   Decides whether a finding may be remediated, which catalog action to use, and whether a human must
#   approve. Query: POST /v1/data/governance/remediation/authz/decision. Policy authority: humans can approve
#   only what this policy marks eligible; the AI can never widen it. The committed default profile is
#   detect_only (remediation disabled).
package governance.remediation.authz

cfg := data.governance.config.remediation

catalog := data.governance.remediation_catalog

r := input.request

required_fields := ["finding_id", "policy_id", "severity", "finding_type", "environment", "account_ref", "platform"]

missing_fields contains f if {
	some f in required_fields
	not is_string(object.get(r, f, null))
}

# Ordered preference of actions for the policy (data.governance.policy_actions)
candidates := object.get(data.governance.policy_actions, object.get(r, "policy_id", ""), [])

# Optional: the actions the Plan job found applicable to the real pre-state (for example an inline admin
# policy needs iam_remove_inline_policy, a managed one iam_replace_managed_policy).
applicable(_) if not r.applicable_actions

applicable(a) if a in r.applicable_actions

allowed_actions := [a |
	some a in candidates
	catalog[a]
	r.platform in catalog[a].platforms
	applicable(a)
]

selected_action := allowed_actions[0] if {
	count(allowed_actions) > 0
} else := "none"

impact := catalog[selected_action].impact if {
	selected_action != "none"
} else := "none"

attempts := to_number(object.get(r, "remediation_attempts", 0))

denials contains sprintf("invalid request: missing %s", [concat(", ", sort(missing_fields))]) if count(missing_fields) > 0

denials contains sprintf("account %s is not on the remediation allowlist", [r.account_ref]) if {
	not r.account_ref in cfg.allowed_accounts
}

denials contains "insufficient evidence findings are never remediated automatically" if r.finding_type != "violation"

denials contains sprintf("maximum attempts (%d) reached", [cfg.max_attempts]) if attempts >= cfg.max_attempts

denials contains "remediation cooldown is active" if r.cooldown_active == "yes"

denials contains "agent is marked exempt" if r.exempt == "yes"

denials contains sprintf("no automatable action is defined for %s on %s", [r.policy_id, r.platform]) if {
	count(missing_fields) == 0
	selected_action == "none"
}

# Only development and sandbox may skip approval; production, staging and unknown environments require it
# (fail-closed, like the governance policies).
approval_reasons contains sprintf("environment '%s' requires approval", [object.get(r, "environment", "unknown")]) if {
	not object.get(r, "environment", "unknown") in {"development", "sandbox"}
}

approval_reasons contains sprintf("impact '%s' requires approval", [impact]) if impact in {"medium", "high"}

approval_reasons contains "action is not on the auto-remediation list" if {
	selected_action != "none"
	not selected_action in cfg.auto_remediation_actions
}

approval_reasons contains "action is not eligible for automatic remediation" if {
	selected_action != "none"
	not catalog[selected_action].auto_eligible
}

approval_reasons contains "critical severity requires approval" if r.severity == "critical"

route_precheck := "detect_only" if {
	not cfg.enabled
} else := "detect_only" if {
	cfg.mode == "detect_only"
} else := "denied" if {
	count(denials) > 0
} else := "eligible"

approval_required := "yes" if {
	count(approval_reasons) > 0
} else := "no"

auto_remediation_permitted := "yes" if {
	route_precheck == "eligible"
	approval_required == "no"
} else := "no"

decision := {
	"route_precheck": route_precheck,
	"mode": cfg.mode,
	"selected_action": selected_action,
	"allowed_actions": allowed_actions,
	"approval_required": approval_required,
	"auto_remediation_permitted": auto_remediation_permitted,
	"impact": impact,
	"reversible": object.get(object.get(catalog, selected_action, {}), "reversible", false),
	"reasons": sort([x | some x in (denials | approval_reasons)]),
	"bundle_revision": data.governance.config.bundle_revision,
}
