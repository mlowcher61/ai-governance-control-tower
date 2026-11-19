# -*- coding: utf-8 -*-

# Copyright: Contributors to the AI Governance Control Tower project
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

"""Evidence status helpers shared by the read-only governance modules.

docs/plan/03 section 3.3 and schemas/common.v1.json#/$defs/evidence_value: each evidence domain is
collected, not_collected, access_denied, not_supported or error. A permission problem must be recorded
as access_denied, never treated as "nothing found", so policies return unknown instead of pass.
"""

COLLECTED = "collected"
NOT_COLLECTED = "not_collected"
ACCESS_DENIED = "access_denied"
NOT_SUPPORTED = "not_supported"
ERROR = "error"

ACCESS_DENIED_CODES = frozenset(
    [
        "AccessDenied",
        "AccessDeniedException",
        "UnauthorizedOperation",
        "UnauthorizedAccess",
        "AuthorizationError",
        "Forbidden",
    ]
)

# Worst first: when several calls feed one domain, the domain gets the worst status.
_RANK = {ERROR: 0, ACCESS_DENIED: 1, NOT_SUPPORTED: 2, NOT_COLLECTED: 3, COLLECTED: 4}


def error_code(exc):
    """The AWS error code of a botocore ClientError, or the exception class name."""
    response = getattr(exc, "response", None) or {}
    return (response.get("Error") or {}).get("Code") or type(exc).__name__


def status_for(exc):
    """Map an exception from an AWS call to an evidence status."""
    return ACCESS_DENIED if error_code(exc) in ACCESS_DENIED_CODES else ERROR


def worst(*statuses):
    """Combine statuses for one domain (the least complete wins)."""
    present = [s for s in statuses if s]
    return min(present, key=lambda s: _RANK[s]) if present else NOT_COLLECTED


class EvidenceTracker:
    """Collects per-domain statuses and a list of errors while a module gathers evidence."""

    def __init__(self, *domains):
        self.status = dict((d, COLLECTED) for d in domains)
        self.errors = []

    def failed(self, domain, operation, exc, target=None):
        status = status_for(exc)
        self.status[domain] = worst(self.status.get(domain), status)
        self.errors.append(
            dict(
                domain=domain,
                operation=operation,
                target=target,
                code=error_code(exc),
                status=status,
                message=str(exc)[:500],
            )
        )
        return status

    def set(self, domain, status):
        self.status[domain] = status
