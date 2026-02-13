#!/usr/bin/env bash
# Start an OpenAI-compatible inference simulator on the host.
# This acts as the "external model provider" for the POC.
#
# The simulator listens on port 9090 and responds to:
#   GET  /v1/models
#   POST /v1/chat/completions
#   POST /v1/completions
#   GET  /health
#   GET  /ready

set -euo pipefail

CONTAINER_NAME="external-model-sim"
HOST_PORT="${SIM_PORT:-9090}"
IMAGE="ghcr.io/llm-d/llm-d-inference-sim:v0.6.1"
MODEL_NAME="${SIM_MODEL:-gpt-4-external}"

# Check if already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "Simulator already running on port ${HOST_PORT}"
  echo "  Container: ${CONTAINER_NAME}"
  echo "  Model:     ${MODEL_NAME}"
  echo ""
  echo "To restart: docker rm -f ${CONTAINER_NAME} && $0"
  exit 0
fi

# Remove stopped container if exists
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

echo "Starting external model simulator..."
echo "  Image:  ${IMAGE}"
echo "  Port:   ${HOST_PORT}"
echo "  Model:  ${MODEL_NAME}"

# Ensure the kind network exists (setup.sh creates the cluster, but we need the network early)
docker network create kind 2>/dev/null || true

docker run -d \
  --name "${CONTAINER_NAME}" \
  --network kind \
  -p "${HOST_PORT}:8000" \
  "${IMAGE}" \
  /app/llm-d-inference-sim \
  --port 8000 \
  --model "${MODEL_NAME}" \
  --mode random

# Wait for health (use 127.0.0.1 explicitly - IPv6 localhost may get connection reset)
echo -n "Waiting for simulator to be ready"
for i in $(seq 1 30); do
  if curl -s "http://127.0.0.1:${HOST_PORT}/v1/models" >/dev/null 2>&1; then
    echo " ready."
    break
  fi
  echo -n "."
  sleep 1
done

# Verify
echo ""
echo "Verifying simulator..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${HOST_PORT}/v1/models" 2>/dev/null || echo "000")
if [ "${HTTP_CODE}" = "200" ]; then
  echo "  GET /v1/models -> 200 OK"
  curl -s "http://127.0.0.1:${HOST_PORT}/v1/models" | python3 -m json.tool 2>/dev/null || \
    curl -s "http://127.0.0.1:${HOST_PORT}/v1/models"
else
  echo "  WARNING: GET /v1/models -> ${HTTP_CODE}"
fi

echo ""
echo "Simulator is running. Access it at:"
echo "  From host:           http://localhost:${HOST_PORT}"
echo "  From Kind containers: http://${CONTAINER_NAME}:8000"
echo ""
echo "To stop: docker rm -f ${CONTAINER_NAME}"
