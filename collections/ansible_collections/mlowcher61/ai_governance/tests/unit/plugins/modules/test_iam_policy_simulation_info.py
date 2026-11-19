"""Unit tests for iam_policy_simulation_info helper logic (no AWS calls)."""

import pytest

from ansible_collections.mlowcher61.ai_governance.plugins.modules import iam_policy_simulation_info as mod


@pytest.mark.parametrize(
    "decision,expected,result",
    [
        ("allowed", "allowed", True),
        ("implicitDeny", "allowed", False),
        ("explicitDeny", "denied", True),
        ("implicitDeny", "denied", True),
        ("allowed", "denied", False),
        ("allowed", "any", True),
        (None, "denied", False),
    ],
)
def test_passed(decision, expected, result):
    assert mod._passed(decision, expected) is result


def test_context_entries_defaults_type_and_stringifies():
    entries = mod._context_entries([{"key": "iam:ResourceTag/aigov:managed", "values": [True]}])
    assert entries == [
        {"ContextKeyName": "iam:ResourceTag/aigov:managed", "ContextKeyValues": ["True"], "ContextKeyType": "string"}
    ]


def test_context_entries_empty():
    assert mod._context_entries([]) == []
    assert mod._context_entries(None) == []


class _FakePaginator:
    def __init__(self, results):
        self._results = results
        self.calls = []

    def paginate(self, **params):
        self.calls.append(params)
        return self

    def build_full_result(self):
        return {"EvaluationResults": self._results}


class _FakeClient:
    def __init__(self, results):
        self.paginator = _FakePaginator(results)

    def get_paginator(self, name):
        assert name == "simulate_principal_policy"
        return self.paginator


def test_simulate_passes_context_and_counts_statements():
    client = _FakeClient([{"EvalDecision": "allowed", "MatchedStatements": [{}, {}]}])
    check = {"action": "iam:DetachRolePolicy", "resource": "arn:aws:iam::1:role/x",
             "context": [{"key": "iam:ResourceTag/aigov:managed", "values": ["true"], "type": "string"}]}
    decision, matched = mod.simulate(client, "arn:aws:iam::1:role/aigov/AIGovRemediationRole", check)
    assert (decision, matched) == ("allowed", 2)
    params = client.paginator.calls[0]
    assert params["ActionNames"] == ["iam:DetachRolePolicy"]
    assert params["ContextEntries"][0]["ContextKeyName"] == "iam:ResourceTag/aigov:managed"


def test_simulate_omits_empty_context():
    client = _FakeClient([{"EvalDecision": "implicitDeny"}])
    decision, matched = mod.simulate(client, "arn", {"action": "iam:PassRole", "resource": "*", "context": []})
    assert (decision, matched) == ("implicitDeny", 0)
    assert "ContextEntries" not in client.paginator.calls[0]


def test_simulation_map_keeps_only_unconditional_wildcard_checks():
    results = [
        {"action": "iam:CreateUser", "resource": "*", "decision": "allowed", "has_context": False},
        {"action": "iam:PutRolePolicy", "resource": "*", "decision": "implicitDeny", "has_context": False},
        {"action": "iam:DetachRolePolicy", "resource": "arn:aws:iam::1:role/x", "decision": "allowed", "has_context": False},
        {"action": "iam:TagRole", "resource": "*", "decision": "allowed", "has_context": True},
        {"action": "s3:GetObject", "resource": "*", "decision": None, "has_context": False},
    ]
    assert mod.simulation_map(results) == {"iam:CreateUser": "allowed", "iam:PutRolePolicy": "denied"}
