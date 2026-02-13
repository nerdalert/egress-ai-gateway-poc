#!/usr/bin/env bash
# Set up the full POC environment:
#   1. Build and deploy the wg-ai-gateway controller (Kind cluster)
#   2. Apply the POC manifests (Gateway, Backends, HTTPRoutes)
#
# Prerequisites:
#   - Docker running
#   - Kind installed
#   - kubectl installed
#   - Simulator running (./scripts/start-simulator.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WG_DIR="${WG_DIR:-$(cd "${SCRIPT_DIR}/../../wg-ai-gateway/prototypes/backend-control-plane" 2>/dev/null && pwd)}"
if [ -z "${WG_DIR}" ] || [ ! -d "${WG_DIR}" ]; then
  echo "Error: WG_DIR not set or not found. Set it to the wg-ai-gateway backend-control-plane directory." >&2
  exit 1
fi
CONTEXT="kind-wg-ai-gateway"

echo "==> POC Setup"
echo "    WG AI Gateway: ${WG_DIR}"
echo "    POC manifests: ${POC_DIR}/manifests"
echo ""

# Check prerequisites
for cmd in docker kind kubectl; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "Error: ${cmd} is required but not installed." >&2
    exit 1
  fi
done

# Check simulator is running
SIM_PORT="${SIM_PORT:-9090}"
if ! curl -s "http://127.0.0.1:${SIM_PORT}/v1/models" >/dev/null 2>&1; then
  echo "NOTE: Simulator not detected on port ${SIM_PORT}."
  echo "  The httpbin backend will work without it."
  echo "  When ready to test external model routing, run:"
  echo ""
  echo "    ./scripts/start-simulator.sh"
  echo ""
  echo "  Then re-run ./scripts/setup.sh to wire it in, or apply the manifest manually:"
  echo "    sed \"s|__SIM_ADDR__|<simulator-ip>|g\" manifests/external-model.yaml | kubectl --context kind-wg-ai-gateway apply -f -"
  echo ""
  echo "  Continuing with httpbin-only setup..."
  echo ""
  SKIP_SIMULATOR=true
fi

# Resolve simulator address for Kind containers
# Inside Kind, the simulator container is reachable via its container name on the kind network
SIM_CONTAINER="external-model-sim"
SIM_ADDR=""
if docker ps --format '{{.Names}}' | grep -q "^${SIM_CONTAINER}$"; then
  SIM_ADDR=$(docker inspect "${SIM_CONTAINER}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
  if [ -n "${SIM_ADDR}" ]; then
    echo "==> Simulator container IP on kind network: ${SIM_ADDR}"
  fi
fi

if [ -z "${SIM_ADDR}" ]; then
  # Fallback: use host.docker.internal (works on Mac/Windows Docker Desktop)
  # or the docker bridge gateway for Linux
  SIM_ADDR=$(docker network inspect kind 2>/dev/null | \
    python3 -c "import sys,json; nets=json.load(sys.stdin); print(nets[0]['IPAM']['Config'][0]['Gateway'])" 2>/dev/null || echo "172.18.0.1")
  echo "==> Using gateway IP for simulator: ${SIM_ADDR}"
fi

echo ""

# Step 1: Build and deploy wg-ai-gateway on Kind
echo "==> Setting up wg-ai-gateway dev environment..."
cd "${WG_DIR}"
make dev-setup

echo ""
echo "==> Waiting for controller to be ready..."
kubectl --context "${CONTEXT}" wait --for=condition=available deployment/ai-gateway-controller \
  -n ai-gateway-system --timeout=120s

echo ""
echo "==> Waiting for GatewayClass to be accepted..."
for i in $(seq 1 30); do
  STATUS=$(kubectl --context "${CONTEXT}" get gatewayclass wg-ai-gateway \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  if [ "${STATUS}" = "True" ]; then
    echo "    GatewayClass accepted."
    break
  fi
  sleep 2
done

# Step 2: Apply POC manifests with the simulator address substituted
echo ""
echo "==> Applying POC manifests..."

# Apply gateway first
kubectl --context "${CONTEXT}" apply -f "${POC_DIR}/manifests/common/gateway.yaml"

# Apply httpbin backend (static, no substitution needed)
kubectl --context "${CONTEXT}" apply -f "${POC_DIR}/manifests/common/httpbin.yaml"

# Apply external model backend with simulator address (only if simulator is running)
if [ "${SKIP_SIMULATOR:-false}" = "true" ]; then
  echo "  Skipping external-model.yaml (simulator not running)."
  echo "  Start the simulator and re-run setup.sh to add it later."
else
  sed "s|__SIM_ADDR__|${SIM_ADDR}|g" "${POC_DIR}/manifests/kind/external-model.yaml" | \
    kubectl --context "${CONTEXT}" apply -f -
fi

echo ""
echo "==> Waiting for Gateway to be programmed..."
for i in $(seq 1 30); do
  STATUS=$(kubectl --context "${CONTEXT}" get gateway poc-gateway -n default \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  if [ "${STATUS}" = "True" ]; then
    echo "    Gateway programmed."
    break
  fi
  sleep 2
done

echo ""
echo "==> Waiting for Envoy proxy pod..."
kubectl --context "${CONTEXT}" wait --for=condition=ready pod \
  -l app=envoy-poc-gateway --timeout=120s 2>/dev/null || \
  sleep 10

echo ""
echo "==> POC environment ready."
echo ""
echo "Run tests:    ./scripts/test.sh"
echo "View logs:    cd ${WG_DIR} && make logs"
echo "Tear down:    ./scripts/teardown.sh"
