# Copyright: AI Governance Control Tower contributors
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)
"""Render "by name" automation orchestrator workflow definitions and compare them.

The workflow files in ao_workflows/definitions/ name things (AAP job templates, AO
credentials and integrations, the LLM model) instead of embedding environment-specific
IDs. These filters resolve the names to this environment's IDs, build the AO
``schema_version`` 2.0.0 definition, and decide whether a stored version differs.
"""

import copy
import json

DOCUMENTATION = r"""
name: ao_render_workflow
short_description: Render a "by name" automation orchestrator workflow definition
description:
  - Resolves names in a workflow file to AO and AAP IDs and returns C({definition, missing}).
  - C(missing) lists every name that could not be resolved, so the caller can fail with one clear message.
  - Node types C(aap_job_template), C(aap_workflow_job_template), C(agentic) and C(approval) are rendered
    from names. Every other node type is carried verbatim from its C(parameters) key.
options:
  _input:
    description: The workflow file content (name, description, triggers, nodes, edges).
    type: dict
    required: true
  lookups:
    description: >-
      Name to ID maps for this environment, with keys C(credentials), C(integrations), C(job_templates),
      C(workflow_job_templates), C(models) (integration name to model name to ID), C(approvers)
      (list of AO usernames) and C(defaults) (aap_integration, aap_credential, llm_integration,
      llm_credential, llm_model, organization).
    type: dict
    required: true
"""

EXAMPLES = r"""
- name: Render the workflow
  ansible.builtin.set_fact:
    rendered: "{{ workflow_file | mlowcher61.ai_governance.ao_render_workflow(lookups) }}"
"""

RETURN = r"""
_value:
  description: C(definition) (the AO workflow definition) and C(missing) (unresolved names).
  type: dict
"""

SCHEMA_VERSION = "2.0.0"


def _resolve(table, name, label, missing):
    if name in table:
        return table[name]
    missing.append("%s: %s" % (label, name))
    return None


def _render_node(node, lookups, missing):
    defaults = lookups.get("defaults", {})
    creds = lookups.get("credentials", {})
    integrations = lookups.get("integrations", {})
    ntype = node["type"]
    out = {
        "id": node["id"],
        "name": node["name"],
        "type": ntype,
        "position": node.get("position", {"x": 0, "y": 0}),
    }
    if "settings" in node:
        out["settings"] = copy.deepcopy(node["settings"])

    if ntype in ("aap_job_template", "aap_workflow_job_template"):
        credential = node.get("credential", defaults.get("aap_credential"))
        integration = node.get("integration", defaults.get("aap_integration"))
        params = {
            "credential_id": _resolve(creds, credential, "AO credential", missing),
            "integration_id": _resolve(integrations, integration, "AO integration", missing),
            "organization_name": node.get("organization", defaults.get("organization")),
        }
        if ntype == "aap_job_template":
            name = node["job_template"]
            params.update({
                "job_template_id": _resolve(lookups.get("job_templates", {}), name, "AAP job template", missing),
                "job_template_name": name,
                "limit": node.get("limit", ""),
                "diff_mode": bool(node.get("diff_mode", False)),
            })
        else:
            name = node["workflow_job_template"]
            params.update({
                "workflow_job_template_id": _resolve(
                    lookups.get("workflow_job_templates", {}), name, "AAP workflow job template", missing),
                "workflow_job_template_name": name,
            })
        if "extra_vars" in node:
            params["extra_vars"] = copy.deepcopy(node["extra_vars"])
        out["parameters"] = params

    elif ntype == "agentic":
        integration = node.get("llm_integration", defaults.get("llm_integration"))
        credential = node.get("llm_credential", defaults.get("llm_credential"))
        model = node.get("llm_model", defaults.get("llm_model"))
        models = lookups.get("models", {}).get(integration, {})
        params = {
            "prompt": node["prompt"].strip(),
            "llm_model_id": _resolve(models, model, "LLM model (integration %s)" % integration, missing),
            "credential_id": _resolve(creds, credential, "LLM credential", missing),
            "tool_selection_strategy": node.get("tool_selection_strategy", "NONE"),
        }
        if "response_schema" in node:
            params["responseSchema"] = copy.deepcopy(node["response_schema"])
        out["parameters"] = params

    elif ntype == "approval":
        out.setdefault("settings", {})
        params = {
            "prompt": node["prompt"].strip(),
            "approver_users": list(lookups.get("approvers", [])),
            "fallback_decision": node.get("fallback_decision", "reject"),
        }
        if "decision_window" in node:
            params["decision_window"] = int(node["decision_window"])
        out["parameters"] = params

    else:
        out["parameters"] = copy.deepcopy(node.get("parameters", {}))
    return out


def ao_render_workflow(workflow, lookups):
    """Return {definition, missing} for a "by name" workflow file."""
    missing = []
    nodes = [_render_node(n, lookups, missing) for n in workflow.get("nodes", [])]
    definition = {
        "schema_version": SCHEMA_VERSION,
        "name": workflow["name"],
        "description": (workflow.get("description") or "").strip(),
        "triggers": copy.deepcopy(workflow.get("triggers", [])),
        "nodes": nodes,
        "edges": copy.deepcopy(workflow.get("edges", [])),
    }
    return {"definition": definition, "missing": sorted(set(missing))}


def _normalize_value(value):
    """Make stored and rendered values comparable (AO stores positions as floats)."""
    if isinstance(value, dict):
        return {k: _normalize_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_normalize_value(v) for v in value]
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def _normalize_node(node):
    node = copy.deepcopy(node)
    params = node.get("parameters") or {}
    # AO accepts responseSchema but stores response_schema.
    if "response_schema" in params:
        params["responseSchema"] = params.pop("response_schema")
    if "position" in node:
        node["position"] = {k: round(float(v)) for k, v in node["position"].items()}
    if node.get("settings") == {} and node.get("type") != "approval":
        node.pop("settings")
    return _normalize_value(node)


def _canonical(definition):
    definition = definition or {}
    return json.dumps({
        "description": (definition.get("description") or "").strip(),
        "triggers": sorted((_normalize_node(t) for t in definition.get("triggers", [])),
                           key=lambda n: n["id"]),
        "nodes": sorted((_normalize_node(n) for n in definition.get("nodes", [])), key=lambda n: n["id"]),
        "edges": sorted((_normalize_value(e) for e in definition.get("edges", [])),
                        key=lambda e: json.dumps(e, sort_keys=True)),
    }, sort_keys=True)


def ao_workflow_differs(stored, rendered):
    """True when the stored AO definition differs from the rendered one."""
    return _canonical(stored) != _canonical(rendered)


class FilterModule:
    """automation orchestrator workflow filters."""

    def filters(self):
        return {
            "ao_render_workflow": ao_render_workflow,
            "ao_workflow_differs": ao_workflow_differs,
        }
