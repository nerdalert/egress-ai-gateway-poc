#!/usr/bin/env bash
# Tear down the entire POC environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WG_DIR="${WG_DIR:-$(cd "${SCRIPT_DIR}/../../wg-ai-gateway/prototypes/backend-control-plane" 2>/dev/null && pwd)}"

echo "==> Tearing down POC..."

# Remove POC resources from cluster (if cluster still exists)
CONTEXT="kind-wg-ai-gateway"
if kubectl --context "${CONTEXT}" cluster-info >/dev/null 2>&1; then
  echo "  Deleting POC manifests..."
  kubectl --context "${CONTEXT}" delete httproute external-model-route httpbin-route 2>/dev/null || true
  kubectl --context "${CONTEXT}" delete xbackenddestination external-model-backend httpbin-backend 2>/dev/null || true
  kubectl --context "${CONTEXT}" delete gateway poc-gateway 2>/dev/null || true
fi

# Tear down Kind cluster
echo "  Tearing down Kind cluster..."
cd "${WG_DIR}" && make dev-teardown 2>/dev/null || true

# Stop simulator
echo "  Stopping simulator..."
docker rm -f external-model-sim 2>/dev/null || true

echo ""
echo "Teardown complete."
