# Bootstrap policy loaded by "AI Governance - Deploy Platform Services" so OPA starts with a
# known package. The policy publish job (T1.08) replaces the opa-policies ConfigMap with the
# governance bundle from policies/.
package governance.platform

info := {
	"bundle_revision": "bootstrap",
	"status": "awaiting governance policy publish",
}
