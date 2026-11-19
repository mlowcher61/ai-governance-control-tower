# METADATA
# title: AIGOV-IAM-002 - dangerous permissions are flagged for review
# description: >-
#   Flags grants of sensitive actions short of full administrator access (that is AIGOV-IAM-001). A granted
#   action is dangerous when it equals, or as a wildcard covers, a configured dangerous action: s3:* matches
#   "s3:*" and secretsmanager:* covers secretsmanager:GetSecretValue, but bedrock:InvokeModel does not match
#   "bedrock:*".
package governance.policies.iam_002

import data.governance.lib

meta := {
	"policy_id": "AIGOV-IAM-002",
	"version": "1.0.0",
	"title": "Agents with dangerous permissions must be flagged for review",
	"severity": "high",
	"remediation": {
		"summary": "Remove the dangerous actions from the execution role or scope them to specific resources, after owner review.",
		"action_types": ["iam_replace_managed_policy", "iam_remove_inline_policy"],
		"automatable": false,
	},
}

cfg := data.governance.config

full_admin_action(a) if a in {"*", "*:*"}

dangerous_grants contains {"source": p.ref, "action": a, "covers": d} if {
	some p in input.identity.policies
	p.type != "boundary"
	not p.ref in cfg.admin_policy_arns
	some s in p.statements
	s.effect == "Allow"
	some a in s.actions
	not full_admin_action(a)
	some d in cfg.dangerous_actions
	glob.match(lower(a), [], lower(d))
}

decision := "unknown" if {
	not lib.collected("identity")
} else := "fail" if {
	count(dangerous_grants) > 0
} else := "pass"

explanation := lib.unknown_explanation("identity") if {
	decision == "unknown"
} else := sprintf("Execution role grants dangerous actions: %s.", [concat("; ", sort([sprintf("%s in %s", [g.action, g.source]) | some g in dangerous_grants]))]) if {
	decision == "fail"
} else := "No dangerous actions are granted (administrator access is assessed by AIGOV-IAM-001)."

evidence := [{"path": "identity.policies", "value": g} | some g in dangerous_grants]

result := lib.result(meta, decision, explanation, evidence)
