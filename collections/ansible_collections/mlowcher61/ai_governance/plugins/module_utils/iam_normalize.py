# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

"""Normalize IAM policy documents into the contract shape (schemas/common.v1.json#/$defs/policy_statement).

IAM lets Action, NotAction, Resource and NotResource be a string or a list, and Statement be an object or
a list. Policies (Rego) should not have to handle both, so every field becomes a list here.
"""

import json

try:
    from urllib.parse import unquote
except ImportError:  # pragma: no cover - Python 2
    from urllib import unquote


def _as_list(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return [str(v) for v in value]
    return [str(value)]


def parse_document(document):
    """Return a policy document as a dict. Accepts a dict, JSON text, or URL-encoded JSON text."""
    if document is None:
        return {}
    if isinstance(document, dict):
        return document
    text = document
    if "%" in text and not text.lstrip().startswith("{"):
        text = unquote(text)
    return json.loads(text)


def normalize_statements(document):
    """List of normalized statements for a policy document (dict or text)."""
    statements = parse_document(document).get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]
    out = []
    for st in statements:
        out.append(
            dict(
                sid=str(st.get("Sid", "")),
                effect=st.get("Effect", "Allow"),
                actions=_as_list(st.get("Action")),
                not_actions=_as_list(st.get("NotAction")),
                resources=_as_list(st.get("Resource")),
                not_resources=_as_list(st.get("NotResource")),
                has_conditions=bool(st.get("Condition")),
            )
        )
    return out


def managed_policy_type(policy_arn):
    """aws_managed for AWS-owned policies (arn:<partition>:iam::aws:policy/...), else customer_managed."""
    return "aws_managed" if ":iam::aws:policy/" in (policy_arn or "") else "customer_managed"


def role_name_from_arn(role_arn):
    """Role name from a role ARN (the path is dropped: arn:aws:iam::1:role/path/name -> name)."""
    return role_arn.rsplit("/", 1)[-1]
