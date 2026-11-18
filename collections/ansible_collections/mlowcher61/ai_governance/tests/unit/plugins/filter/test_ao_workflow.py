"""Unit tests for the ao_workflow filter plugin."""

import copy
import importlib.util
import pathlib

PLUGIN = pathlib.Path(__file__).resolve().parents[4] / "plugins" / "filter" / "ao_workflow.py"
_spec = importlib.util.spec_from_file_location("ao_workflow", PLUGIN)
ao = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ao)

LOOKUPS = {
    "credentials": {"AAP Admin": "cred-aap", "LiteMaaS API Key": "cred-llm"},
    "integrations": {"Ansible Automation Platform": "int-aap", "LiteMaaS": "int-llm"},
    "job_templates": {"AI Governance - Check Environment": 133},
    "workflow_job_templates": {},
    "models": {"LiteMaaS": {"llama-scout-17b": "model-1"}},
    "approvers": ["admin-abc123"],
    "defaults": {
        "aap_integration": "Ansible Automation Platform",
        "aap_credential": "AAP Admin",
        "llm_integration": "LiteMaaS",
        "llm_credential": "LiteMaaS API Key",
        "llm_model": "llama-scout-17b",
        "organization": "AI Governance",
    },
}

WORKFLOW = {
    "name": "Test (as code)",
    "description": "  test  ",
    "triggers": [{"id": "trigger_manual", "name": "Start", "type": "manual_trigger", "parameters": {}}],
    "nodes": [
        {"id": "activity_check", "name": "Check", "type": "aap_job_template",
         "position": {"x": 300, "y": 100}, "job_template": "AI Governance - Check Environment",
         "extra_vars": {"run": "${trigger.run_id}"}},
        {"id": "activity_explain", "name": "Explain", "type": "agentic", "prompt": " Say hi \n",
         "response_schema": {"type": "object"}, "settings": {"continue_on_failure": True}},
        {"id": "approval_go", "name": "Approve", "type": "approval", "prompt": "Go?", "decision_window": 3600},
        {"id": "logic_route", "name": "Route", "type": "switch",
         "parameters": {"cases": [{"port": "case_0", "condition": "${a.b} == 'x'"}]}},
    ],
    "edges": [{"from": "trigger_manual", "to": "activity_check"}],
}


def test_render_resolves_names():
    result = ao.ao_render_workflow(WORKFLOW, LOOKUPS)
    assert result["missing"] == []
    d = result["definition"]
    assert d["schema_version"] == "2.0.0"
    assert d["description"] == "test"
    jt, agent, approval, switch = d["nodes"]
    assert jt["parameters"]["job_template_id"] == 133
    assert jt["parameters"]["credential_id"] == "cred-aap"
    assert jt["parameters"]["organization_name"] == "AI Governance"
    assert jt["parameters"]["extra_vars"] == {"run": "${trigger.run_id}"}
    assert agent["parameters"]["llm_model_id"] == "model-1"
    assert agent["parameters"]["prompt"] == "Say hi"
    assert agent["parameters"]["responseSchema"] == {"type": "object"}
    assert agent["parameters"]["tool_selection_strategy"] == "NONE"
    assert agent["settings"] == {"continue_on_failure": True}
    assert approval["parameters"]["approver_users"] == ["admin-abc123"]
    assert approval["parameters"]["decision_window"] == 3600
    assert switch["parameters"]["cases"][0]["port"] == "case_0"


def test_render_reports_every_missing_name():
    wf = copy.deepcopy(WORKFLOW)
    wf["nodes"][0]["job_template"] = "Nope"
    wf["nodes"][1]["llm_credential"] = "Missing Key"
    result = ao.ao_render_workflow(wf, LOOKUPS)
    assert "AAP job template: Nope" in result["missing"]
    assert "LLM credential: Missing Key" in result["missing"]


def test_differs_ignores_storage_normalization():
    rendered = ao.ao_render_workflow(WORKFLOW, LOOKUPS)["definition"]
    stored = copy.deepcopy(rendered)
    stored["nodes"][0]["position"] = {"x": 300.0, "y": 100.0}
    params = stored["nodes"][1]["parameters"]
    params["response_schema"] = params.pop("responseSchema")
    stored["nodes"].reverse()
    stored["edges"].reverse()
    assert ao.ao_workflow_differs(stored, rendered) is False


def test_differs_detects_change():
    rendered = ao.ao_render_workflow(WORKFLOW, LOOKUPS)["definition"]
    stored = copy.deepcopy(rendered)
    stored["nodes"][0]["parameters"]["extra_vars"]["run"] = "changed"
    assert ao.ao_workflow_differs(stored, rendered) is True
    assert ao.ao_workflow_differs(None, rendered) is True
