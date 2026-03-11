#!/usr/bin/env bash
# deploy.sh — Deploy the external model routing demo
#
# Usage:
#   ./scripts/deploy.sh base                 # Deploy namespace + gateway only
#   ./scripts/deploy.sh iteration-1          # Deploy base + httpbin routing
#   ./scripts/deploy.sh iteration-2          # Deploy base + OpenAI routing
#   ./scripts/deploy.sh all                  # Deploy everything
#   ./scripts/deploy.sh clean                # Remove all demo resources

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
NAMESPACE="external-model-demo"

echo "============================================"
echo "  External Model Routing — Deploy"
echo "============================================"
echo ""

deploy_base() {
    echo "[base] Deploying namespace and gateway..."
    kubectl apply -f "${MANIFESTS_DIR}/base/gateway.yaml"

    echo "[base] Waiting for gateway to be programmed..."
    kubectl wait --for=condition=programmed gateway/external-model-gateway \
        -n "${NAMESPACE}" --timeout=120s 2>/dev/null || \
        echo "  WARNING: Gateway not yet programmed (may take a moment)"

    echo "[base] Gateway deployed."
    kubectl get gateway -n "${NAMESPACE}"
    echo ""
}

deploy_iteration_1() {
    echo "[iteration-1] Deploying httpbin.org routing (no auth)..."
    kubectl apply -f "${MANIFESTS_DIR}/iteration-1-no-auth/"

    echo "[iteration-1] Resources created:"
    echo "  ServiceEntry:"
    kubectl get serviceentry -n "${NAMESPACE}"
    echo "  DestinationRule:"
    kubectl get destinationrule -n "${NAMESPACE}"
    echo "  HTTPRoute:"
    kubectl get httproute -n "${NAMESPACE}"
    echo ""
}

deploy_iteration_2() {
    echo "[iteration-2] Deploying api.openai.com routing (with API key)..."

    # Apply only .yaml files (skip .template files)
    for f in "${MANIFESTS_DIR}/iteration-2-with-apikey/"*.yaml; do
        [[ -f "$f" ]] && kubectl apply -f "$f"
    done

    echo "[iteration-2] Resources created:"
    echo "  ServiceEntry:"
    kubectl get serviceentry -n "${NAMESPACE}"
    echo "  DestinationRule:"
    kubectl get destinationrule -n "${NAMESPACE}"
    echo "  HTTPRoute:"
    kubectl get httproute -n "${NAMESPACE}"
    echo ""
}

deploy_iteration_3() {
    echo "[iteration-3] Deploying api.anthropic.com routing (with API key)..."

    # Apply only .yaml files (skip .template files)
    for f in "${MANIFESTS_DIR}/iteration-3-anthropic/"*.yaml; do
        [[ -f "$f" ]] && kubectl apply -f "$f"
    done

    echo "[iteration-3] Resources created:"
    echo "  ServiceEntry:"
    kubectl get serviceentry -n "${NAMESPACE}"
    echo "  DestinationRule:"
    kubectl get destinationrule -n "${NAMESPACE}"
    echo "  HTTPRoute:"
    kubectl get httproute -n "${NAMESPACE}"
    echo ""
}

clean() {
    echo "[clean] Removing all demo resources..."
    for dir in iteration-3-anthropic iteration-2-with-apikey iteration-1-no-auth; do
        for f in "${MANIFESTS_DIR}/${dir}/"*.yaml; do
            [[ -f "$f" ]] && kubectl delete -f "$f" --ignore-not-found 2>/dev/null || true
        done
    done
    kubectl delete -f "${MANIFESTS_DIR}/base/gateway.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
    echo "[clean] Done."
    echo ""
}

case "${1:-}" in
    base)
        deploy_base
        ;;
    iteration-1|1)
        deploy_base
        deploy_iteration_1
        ;;
    iteration-2|2)
        deploy_base
        deploy_iteration_2
        ;;
    iteration-3|3)
        deploy_base
        deploy_iteration_3
        ;;
    all)
        deploy_base
        deploy_iteration_1
        deploy_iteration_2
        deploy_iteration_3
        ;;
    clean)
        clean
        ;;
    *)
        echo "Usage: $0 {base|iteration-1|iteration-2|iteration-3|all|clean}"
        echo ""
        echo "Commands:"
        echo "  base         Deploy namespace + Istio gateway"
        echo "  iteration-1  Deploy base + httpbin.org routing (no auth)"
        echo "  iteration-2  Deploy base + api.openai.com routing (OpenAI)"
        echo "  iteration-3  Deploy base + api.anthropic.com routing (Anthropic)"
        echo "  all          Deploy everything"
        echo "  clean        Remove all demo resources"
        exit 1
        ;;
esac

echo "============================================"
echo "  Deploy complete!"
echo ""
echo "  Next: Run validation tests"
echo "    ./scripts/validate.sh ${1:-all}"
echo "============================================"
