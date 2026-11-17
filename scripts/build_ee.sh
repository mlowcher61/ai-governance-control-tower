#!/usr/bin/env bash
# Build and push the AI Governance execution environment (task T0.04).
#
# Prerequisites:
#   podman login registry.redhat.io          # Red Hat registry (base image)
#   export AAP_SERVER=aap.example.com         # gateway host; also the private hub registry
#   export AAP_API_TOKEN=<token>              # or AIGOV_HUB_TOKEN: private hub API + registry token
#   pip install 'ansible-builder>=3.1'
# Usage: scripts/build_ee.sh [version]        # default version from VERSION below
set -euo pipefail

VERSION="${1:-0.1.0}"
HUB_TOKEN="${AIGOV_HUB_TOKEN:-${AAP_API_TOKEN:?Set AIGOV_HUB_TOKEN or AAP_API_TOKEN}}"
REGISTRY="${AIGOV_EE_REGISTRY:-${AAP_SERVER:?Set AAP_SERVER}}"
IMAGE="${REGISTRY}/ai-governance-ee:${VERSION}"
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
  --verbosity 1

# Smoke test: the AgentCore client and the certified collections must be present.
podman run --rm "$IMAGE" python3 -c "import boto3; s=boto3.session.Session().get_available_services(); assert 'bedrock-agentcore-control' in s, 'AgentCore client missing'; print('boto3', boto3.__version__, 'AgentCore client OK')"
podman run --rm "$IMAGE" ansible-galaxy collection list amazon.aws amazon.ai

printf '%s' "$HUB_TOKEN" | podman login "$REGISTRY" -u admin --password-stdin >/dev/null
podman push "$IMAGE"
echo "Pushed $IMAGE"
