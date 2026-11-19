#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: jwt_hs256
short_description: Sign a JSON Web Token with HMAC-SHA256
version_added: "0.1.0"
description:
  - Builds and signs a compact JWT (RFC 7519) with the C(HS256) algorithm. The project uses it to
    issue one token per Governance Inventory API role (PostgREST selects the PostgreSQL role from
    the C(role) claim).
  - Adds C(iat) and C(exp) claims from O(ttl_seconds). Uses only the Python standard library.
  - The token is a secret. Always run this module with C(no_log: true).
  - This module exists because no certified Ansible collection signs JWTs.
options:
  secret:
    description: Shared HMAC secret (the PostgREST C(jwt-secret)). At least 32 characters.
    type: str
    required: true
    no_log: true
  claims:
    description: Claims to sign, for example C({"role": "aigov_discovery", "sub": "aap-discovery"}).
    type: dict
    required: true
  ttl_seconds:
    description: Lifetime of the token in seconds. Use 0 for no C(exp) claim (not recommended).
    type: int
    default: 7776000
notes:
  - Supports check mode. The module never changes anything.
author:
  - AI Governance Control Tower contributors
"""

EXAMPLES = r"""
- name: Issue the discovery API token
  mlowcher61.ai_governance.jwt_hs256:
    secret: "{{ aigov_jwt_secret }}"
    claims:
      role: aigov_discovery
      sub: aap-aigov-discovery
    ttl_seconds: "{{ 90 * 86400 }}"
  register: aigov_token
  no_log: true
"""

RETURN = r"""
token:
  description: The signed compact JWT.
  returned: always
  type: str
expires_at:
  description: Expiry as seconds since the epoch (C(exp) claim), or null without expiry.
  returned: always
  type: int
"""

import base64
import hashlib
import hmac
import json
import time

from ansible.module_utils.basic import AnsibleModule


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def encode(claims, secret, ttl_seconds=0, now=None):
    """Return (token, exp) for the claims signed with HS256."""
    issued = int(time.time() if now is None else now)
    body = dict(claims)
    body["iat"] = issued
    exp = None
    if ttl_seconds and ttl_seconds > 0:
        exp = issued + int(ttl_seconds)
        body["exp"] = exp
    header = {"alg": "HS256", "typ": "JWT"}
    signing_input = ".".join(
        _b64url(json.dumps(part, separators=(",", ":"), sort_keys=True).encode("utf-8")) for part in (header, body)
    )
    signature = hmac.new(secret.encode("utf-8"), signing_input.encode("ascii"), hashlib.sha256).digest()
    return signing_input + "." + _b64url(signature), exp


def main():
    module = AnsibleModule(
        argument_spec=dict(
            secret=dict(type="str", required=True, no_log=True),
            claims=dict(type="dict", required=True),
            ttl_seconds=dict(type="int", default=7776000),
        ),
        supports_check_mode=True,
    )
    if len(module.params["secret"]) < 32:
        module.fail_json(msg="secret must be at least 32 characters (PostgREST requirement)")
    if module.params["ttl_seconds"] < 0:
        module.fail_json(msg="ttl_seconds must be 0 or more")
    token, exp = encode(module.params["claims"], module.params["secret"], module.params["ttl_seconds"])
    module.exit_json(changed=False, token=token, expires_at=exp)


if __name__ == "__main__":
    main()
