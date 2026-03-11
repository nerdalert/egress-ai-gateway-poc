#!/usr/bin/env bash
# validate.sh — Validate external model routing through the Istio gateway
#
# Discovers the gateway address automatically (LoadBalancer hostname/IP,
# NodePort, or ClusterIP) and runs curl commands against it.
#
# Usage:
#   ./scripts/validate.sh iteration-1    # Test httpbin.org routing
#   ./scripts/validate.sh iteration-2    # Test api.openai.com routing
#   ./scripts/validate.sh all            # Test both
#
# Override gateway address:
#   GATEWAY_URL=http://127.0.0.1:8080 ./scripts/validate.sh all

set -euo pipefail

NAMESPACE="external-model-demo"
GATEWAY_NAME="external-model-gateway"

# --- Discover gateway URL ---
discover_gateway() {
    if [[ -n "${GATEWAY_URL:-}" ]]; then
        echo "Using GATEWAY_URL override: ${GATEWAY_URL}"
        return
    fi

    echo "Discovering gateway address..."

    # Try 1: LoadBalancer hostname (AWS ELB, OpenShift)
    local hostname
    hostname=$(kubectl get svc -n "${NAMESPACE}" "${GATEWAY_NAME}-istio" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [[ -n "${hostname}" ]]; then
        GATEWAY_URL="http://${hostname}"
        echo "  Found LoadBalancer hostname: ${GATEWAY_URL}"
        return
    fi

    # Try 2: LoadBalancer IP (GKE, bare metal)
    local ip
    ip=$(kubectl get svc -n "${NAMESPACE}" "${GATEWAY_NAME}-istio" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "${ip}" ]]; then
        GATEWAY_URL="http://${ip}"
        echo "  Found LoadBalancer IP: ${GATEWAY_URL}"
        return
    fi

    # Try 3: Gateway status address
    local gw_addr
    gw_addr=$(kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    if [[ -n "${gw_addr}" ]]; then
        GATEWAY_URL="http://${gw_addr}"
        echo "  Found gateway address: ${GATEWAY_URL}"
        return
    fi

    echo "  ERROR: Could not discover gateway address."
    echo "  Try one of:"
    echo "    kubectl port-forward -n ${NAMESPACE} svc/${GATEWAY_NAME}-istio 8080:80 &"
    echo "    GATEWAY_URL=http://127.0.0.1:8080 ./scripts/validate.sh all"
    exit 1
}

# --- Iteration 1: httpbin.org ---
validate_iteration_1() {
    echo ""
    echo "=========================================="
    echo "  Iteration 1: httpbin.org (no auth)"
    echo "=========================================="

    echo ""
    echo "Resources:"
    kubectl get serviceentry,destinationrule,httproute,svc -n "${NAMESPACE}" 2>/dev/null | grep -E "NAME|httpbin"

    echo ""
    echo "--- GET /get ---"
    echo "curl -s ${GATEWAY_URL}/get -H 'Host: ai-gateway.example.com'"
    echo ""
    curl -s --max-time 15 "${GATEWAY_URL}/get" -H "Host: ai-gateway.example.com" | jq .

    echo ""
    echo "--- POST /post ---"
    echo "curl -s ${GATEWAY_URL}/post -H 'Host: ai-gateway.example.com' -H 'Content-Type: application/json' -d '{\"test\": \"hello from istio mesh\"}'"
    echo ""
    curl -s --max-time 15 "${GATEWAY_URL}/post" \
        -H "Host: ai-gateway.example.com" \
        -H "Content-Type: application/json" \
        -d '{"test": "hello from istio mesh"}' | jq .

    echo ""
    echo "--- GET /headers ---"
    echo "curl -s ${GATEWAY_URL}/headers -H 'Host: ai-gateway.example.com'"
    echo ""
    curl -s --max-time 15 "${GATEWAY_URL}/headers" -H "Host: ai-gateway.example.com" | jq .

    echo ""
    echo "--- GET /status/418 ---"
    echo "curl -s -o /dev/null -w '%{http_code}' ${GATEWAY_URL}/status/418 -H 'Host: ai-gateway.example.com'"
    echo ""
    local code
    code=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" "${GATEWAY_URL}/status/418" -H "Host: ai-gateway.example.com")
    echo "HTTP Status: ${code}"
}

# --- Iteration 2: api.openai.com ---
validate_iteration_2() {
    echo ""
    echo "=========================================="
    echo "  Iteration 2: api.openai.com (with API key)"
    echo "=========================================="
    echo ""
    echo "NOTE: The client does NOT send an Authorization header."
    echo "      The gateway injects it via HTTPRoute RequestHeaderModifier."

    echo ""
    echo "Resources:"
    kubectl get serviceentry,destinationrule,httproute,svc -n "${NAMESPACE}" 2>/dev/null | grep -E "NAME|openai"

    echo ""
    echo "--- GET /v1/models ---"
    echo "curl -s ${GATEWAY_URL}/v1/models"
    echo ""
    curl -s --max-time 15 "${GATEWAY_URL}/v1/models" | jq '.data[:3]'

    echo ""
    echo "--- POST /v1/chat/completions ---"
    echo "curl -s ${GATEWAY_URL}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"gpt-4o-mini\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}], \"max_tokens\": 5, \"temperature\": 0}'"
    echo ""
    curl -s --max-time 30 "${GATEWAY_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{
            "model": "gpt-4o-mini",
            "messages": [{"role": "user", "content": "Say hello in one word."}],
            "max_tokens": 5,
            "temperature": 0
        }' | jq .
}

# --- Iteration 3: api.anthropic.com ---
validate_iteration_3() {
    echo ""
    echo "=========================================="
    echo "  Iteration 3: api.anthropic.com (with API key)"
    echo "=========================================="
    echo ""
    echo "NOTE: The client does NOT send an x-api-key header."
    echo "      The gateway injects it via HTTPRoute RequestHeaderModifier."
    echo "      Anthropic also requires an anthropic-version header (also injected)."

    echo ""
    echo "Resources:"
    kubectl get serviceentry,destinationrule,httproute,svc -n "${NAMESPACE}" 2>/dev/null | grep -E "NAME|anthropic"

    echo ""
    echo "--- POST /v1/messages ---"
    echo "curl -s ${GATEWAY_URL}/v1/messages -H 'Content-Type: application/json' -d '{\"model\": \"claude-sonnet-4-20250514\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}], \"max_tokens\": 5}'"
    echo ""
    curl -s --max-time 30 "${GATEWAY_URL}/v1/messages" \
        -H "Content-Type: application/json" \
        -d '{
            "model": "claude-sonnet-4-20250514",
            "messages": [{"role": "user", "content": "Say hello in one word."}],
            "max_tokens": 5
        }' | jq .
}

# --- Main ---
case "${1:-}" in
    iteration-1|1)
        discover_gateway
        validate_iteration_1
        ;;
    iteration-2|2)
        discover_gateway
        validate_iteration_2
        ;;
    iteration-3|3)
        discover_gateway
        validate_iteration_3
        ;;
    all)
        discover_gateway
        validate_iteration_1
        validate_iteration_2
        validate_iteration_3
        ;;
    *)
        echo "Usage: $0 {iteration-1|iteration-2|iteration-3|all}"
        echo ""
        echo "Discovers the gateway address automatically."
        echo "Override with: GATEWAY_URL=http://host:port $0 all"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "  Validation complete"
echo "=========================================="
echo ""
echo "To run these curl commands manually:"
echo ""
echo "  # httpbin.org (iteration 1)"
echo "  curl -s ${GATEWAY_URL}/get -H 'Host: ai-gateway.example.com' | jq ."
echo "  curl -s ${GATEWAY_URL}/post -H 'Host: ai-gateway.example.com' -H 'Content-Type: application/json' -d '{\"test\": \"hello\"}' | jq ."
echo ""
echo "  # api.openai.com (iteration 2 — no Authorization header needed)"
echo "  curl -s ${GATEWAY_URL}/v1/models | jq '.data[:3]'"
echo "  curl -s ${GATEWAY_URL}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"gpt-4o-mini\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}], \"max_tokens\": 5}' | jq ."
echo ""
echo "  # api.anthropic.com (iteration 3 — no x-api-key header needed)"
echo "  curl -s ${GATEWAY_URL}/v1/messages -H 'Content-Type: application/json' -d '{\"model\": \"claude-sonnet-4-20250514\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}], \"max_tokens\": 5}' | jq ."
