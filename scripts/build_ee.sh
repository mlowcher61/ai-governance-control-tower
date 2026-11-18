#!/usr/bin/env bash
# Build and push the AI Governance execution environment (task T0.04).
#
# Prerequisites:
#   podman login registry.redhat.io           # Red Hat registry (base image)
#   podman login "$AAP_SERVER"                # private hub registry: hub USERNAME/PASSWORD
#                                             # (an AAP API token only yields an anonymous
#                                             #  registry token with no pull/push rights)
#   export AAP_SERVER=aap.example.com         # gateway host; also the private hub registry
#   export AAP_API_TOKEN=<token>              # or AIGOV_HUB_TOKEN: private hub *collection* API token
#   pip install 'ansible-builder>=3.1'
# Usage: scripts/build_ee.sh [version]        # SKIP_PUSH=1 builds and tests without pushing
# Builds for linux/amd64 by default (override with AIGOV_EE_PLATFORM), so it also works on
# Apple silicon workstations (emulated build).
set -euo pipefail

VERSION="${1:-0.1.0}"
HUB_TOKEN="${AIGOV_HUB_TOKEN:-${AAP_API_TOKEN:?Set AIGOV_HUB_TOKEN or AAP_API_TOKEN}}"
REGISTRY="${AIGOV_EE_REGISTRY:-${AAP_SERVER:?Set AAP_SERVER}}"
IMAGE="${REGISTRY}/ai-governance-ee:${VERSION}"
PLATFORM="${AIGOV_EE_PLATFORM:-linux/amd64}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CONTEXT="$(mktemp -d)"
trap 'rm -rf "$CONTEXT"' EXIT

ansible-builder build \
  --file "$HERE/execution_environments/ai-governance-ee/execution-environment.yml" \
  --context "$CONTEXT" \
  --container-runtime podman \
  --tag "$IMAGE" \
  --build-arg ANSIBLE_GALAXY_SERVER_LIST=certified,validated \
  --build-arg "ANSIBLE_GALAXY_SERVER_CERTIFIED_URL=https://${AAP_SERVER}/api/galaxy/content/rh-certified/" \
  --build-arg "ANSIBLE_GALAXY_SERVER_CERTIFIED_TOKEN=${HUB_TOKEN}" \
  --build-arg "ANSIBLE_GALAXY_SERVER_VALIDATED_URL=https://${AAP_SERVER}/api/galaxy/content/validated/" \
  --build-arg "ANSIBLE_GALAXY_SERVER_VALIDATED_TOKEN=${HUB_TOKEN}" \
  --extra-build-cli-args "--platform ${PLATFORM}" \
  --verbosity 1

# Smoke test: the AgentCore client and the certified collections must be present.
podman run --rm --platform "$PLATFORM" "$IMAGE" python3 -c "import boto3; s=boto3.session.Session().get_available_services(); assert 'bedrock-agentcore-control' in s, 'AgentCore client missing'; print('boto3', boto3.__version__, 'AgentCore client OK')"
podman run --rm --platform "$PLATFORM" "$IMAGE" ansible-galaxy collection list --format json | python3 -c "import json,sys; d={n:v[\"version\"] for p in json.load(sys.stdin).values() for n,v in p.items()}; req={\"amazon.aws\",\"amazon.ai\",\"ansible.utils\",\"kubernetes.core\"}; missing=req-d.keys(); assert not missing, missing; print({k:d[k] for k in sorted(req)})"

if [ "${SKIP_PUSH:-0}" = "1" ]; then
  echo "Built and tested $IMAGE (push skipped)"
  exit 0
fi
podman push "$IMAGE"
echo "Pushed $IMAGE"
