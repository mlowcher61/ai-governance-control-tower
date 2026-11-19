"""Unit tests for jwt_hs256 (RFC 7519 HS256 signing, standard library only)."""

import base64
import hashlib
import hmac
import json

from ansible_collections.mlowcher61.ai_governance.plugins.modules import jwt_hs256 as mod

SECRET = "s" * 40


def _decode(part):
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


def test_token_structure_and_claims():
    token, exp = mod.encode({"role": "aigov_reader", "sub": "aap-reader"}, SECRET, ttl_seconds=3600, now=1000)
    header, body, _sig = token.split(".")
    assert _decode(header) == {"alg": "HS256", "typ": "JWT"}
    assert _decode(body) == {"role": "aigov_reader", "sub": "aap-reader", "iat": 1000, "exp": 4600}
    assert exp == 4600
    assert "=" not in token


def test_signature_verifies_with_hmac_sha256():
    token = mod.encode({"role": "aigov_discovery"}, SECRET, now=1)[0]
    signing_input, sig = token.rsplit(".", 1)
    expected = hmac.new(SECRET.encode(), signing_input.encode(), hashlib.sha256).digest()
    assert base64.urlsafe_b64decode(sig + "=" * (-len(sig) % 4)) == expected


def test_no_expiry_when_ttl_zero():
    token, exp = mod.encode({"role": "aigov_reader"}, SECRET, ttl_seconds=0, now=5)
    assert exp is None
    assert "exp" not in _decode(token.split(".")[1])


def test_input_claims_not_mutated():
    claims = {"role": "aigov_reader"}
    mod.encode(claims, SECRET, ttl_seconds=10, now=1)
    assert claims == {"role": "aigov_reader"}
