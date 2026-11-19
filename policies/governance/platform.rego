# METADATA
# title: Platform information (checked by Deploy Platform Services and Publish Governance Policies)
package governance.platform

info := {
	"bundle_revision": data.governance.config.bundle_revision,
	"status": "published",
	"policies": sort([id | some id; data.governance.policies[id].meta]),
}
