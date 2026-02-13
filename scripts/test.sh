#!/usr/bin/env bash
# Test the POC: validates routing to both httpbin and the external model simulator.

set -euo pipefail

CONTEXT="kind-wg-ai-gateway"
LOCAL_PORT=8888
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

cleanup() {
  if [ -n "${PF_PID:-}" ] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "==> Checking resource status..."

# GatewayClass
GC_STATUS=$(kubectl --context "${CONTEXT}" get gatewayclass wg-ai-gateway \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
if [ "${GC_STATUS}" = "True" ]; then
  pass "GatewayClass wg-ai-gateway is Accepted"
else
  fail "GatewayClass wg-ai-gateway is not Accepted (status: ${GC_STATUS:-unknown})"
fi

# Gateway
GW_STATUS=$(kubectl --context "${CONTEXT}" get gateway poc-gateway \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
if [ "${GW_STATUS}" = "True" ]; then
  pass "Gateway poc-gateway is Programmed"
else
  fail "Gateway poc-gateway is not Programmed (status: ${GW_STATUS:-unknown})"
fi

# HTTPRoutes
for route in httpbin-route external-model-route; do
  HR_STATUS=$(kubectl --context "${CONTEXT}" get httproute "${route}" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  if [ "${HR_STATUS}" = "True" ]; then
    pass "HTTPRoute ${route} is Accepted"
  else
    fail "HTTPRoute ${route} is not Accepted (status: ${HR_STATUS:-unknown})"
  fi
done

# Backends
for backend in httpbin-backend external-model-backend; do
  if kubectl --context "${CONTEXT}" get xbackenddestination "${backend}" >/dev/null 2>&1; then
    pass "XBackendDestination ${backend} exists"
  else
    fail "XBackendDestination ${backend} not found"
  fi
done

echo ""
echo "==> Testing traffic routing..."

# Port-forward to the gateway's Envoy service
# The deployer names services as "envoy-{gateway-name}" and labels them with aigateway.networking.k8s.io/managed
SVC_NAME=$(kubectl --context "${CONTEXT}" get svc -l "aigateway.networking.k8s.io/managed" -o name 2>/dev/null | head -1 || true)
if [ -z "${SVC_NAME}" ]; then
  # Fallback: look for the expected service name directly
  SVC_NAME="svc/envoy-poc-gateway"
  if ! kubectl --context "${CONTEXT}" get "${SVC_NAME}" >/dev/null 2>&1; then
    SVC_NAME=""
  fi
fi

if [ -z "${SVC_NAME}" ]; then
  echo "  Could not find Envoy service. Trying LoadBalancer IP..."
  GATEWAY_IP=$(kubectl --context "${CONTEXT}" get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "${GATEWAY_IP}" ]; then
    BASE_URL="http://${GATEWAY_IP}"
    echo "  Using LoadBalancer IP: ${GATEWAY_IP}"
  else
    fail "No Envoy service or LoadBalancer IP found"
    echo ""
    echo "Results: ${PASS} passed, ${FAIL} failed"
    exit 1
  fi
else
  kubectl --context "${CONTEXT}" port-forward "${SVC_NAME}" "${LOCAL_PORT}:80" &>/dev/null &
  PF_PID=$!
  sleep 3
  BASE_URL="http://localhost:${LOCAL_PORT}"
  echo "  Port-forwarding ${SVC_NAME} -> localhost:${LOCAL_PORT}"
fi

echo ""
echo "--- httpbin backend tests ---"

# Test httpbin /get
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/get" 2>/dev/null || echo "000")
if [ "${HTTP_CODE}" = "200" ]; then
  pass "GET /get -> 200 (httpbin)"
else
  fail "GET /get -> ${HTTP_CODE} (expected 200)"
fi

# Test httpbin /headers
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/headers" 2>/dev/null || echo "000")
if [ "${HTTP_CODE}" = "200" ]; then
  pass "GET /headers -> 200 (httpbin)"
else
  fail "GET /headers -> ${HTTP_CODE} (expected 200)"
fi

echo ""
echo "--- external model backend tests ---"

# Test /v1/models
RESPONSE=$(curl -s -w "\n%{http_code}" "${BASE_URL}/v1/models" 2>/dev/null || echo -e "\n000")
HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [ "${HTTP_CODE}" = "200" ]; then
  pass "GET /v1/models -> 200 (external model)"
  # Check response contains model data
  if echo "${BODY}" | grep -q "gpt-4-external"; then
    pass "Response contains model 'gpt-4-external'"
  else
    fail "Response missing model 'gpt-4-external'"
    echo "    Body: ${BODY}"
  fi
else
  fail "GET /v1/models -> ${HTTP_CODE} (expected 200)"
fi

# Test /v1/chat/completions
CHAT_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4-external", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 10}' \
  2>/dev/null || echo -e "\n000")
CHAT_CODE=$(echo "${CHAT_RESPONSE}" | tail -1)
CHAT_BODY=$(echo "${CHAT_RESPONSE}" | sed '$d')

if [ "${CHAT_CODE}" = "200" ]; then
  pass "POST /v1/chat/completions -> 200 (external model)"
  if echo "${CHAT_BODY}" | grep -q "choices"; then
    pass "Response contains 'choices' field"
  else
    fail "Response missing 'choices' field"
    echo "    Body: ${CHAT_BODY}"
  fi
else
  fail "POST /v1/chat/completions -> ${CHAT_CODE} (expected 200)"
  echo "    Body: ${CHAT_BODY}"
fi

# Test /health
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health" 2>/dev/null || echo "000")
if [ "${HTTP_CODE}" = "200" ]; then
  pass "GET /health -> 200 (external model)"
else
  fail "GET /health -> ${HTTP_CODE} (expected 200)"
fi

echo ""
echo "--- negative tests ---"

# Non-matching path should 404
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/nonexistent" 2>/dev/null || echo "000")
if [ "${HTTP_CODE}" = "404" ]; then
  pass "GET /nonexistent -> 404 (no route matched)"
else
  fail "GET /nonexistent -> ${HTTP_CODE} (expected 404)"
fi

echo ""
echo "========================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "========================================"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
