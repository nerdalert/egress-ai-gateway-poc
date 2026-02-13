# WG AI Gateway + MaaS External Models - OpenShift Quickstart

Deploy the wg-ai-gateway controller alongside MaaS on OpenShift to route
inference requests to external model endpoints. Includes MaaS auth integration,
unified model listing, and token rate limiting.

**Prerequisite:** MaaS is already deployed via `deploy-rhoai-stable.sh`.

```bash
# Adjust these to match your clone locations
export WG_DIR=<path-to>/wg-ai-gateway/prototypes/backend-control-plane
export POC_DIR=<path-to>/egress-ai-gateway-poc
```

---

## Deployment

### Step 1: Install CRDs + Controller

```bash
kubectl apply -f $WG_DIR/../internal/backend/k8s/crds/
kubectl apply -f $POC_DIR/manifests/openshift/controller.yaml
kubectl wait --for=condition=available deployment/ai-gateway-controller \
  -n ai-gateway-system --timeout=120s
```

### Step 2: Deploy Gateway + External Model Simulator

```bash
kubectl apply -f $POC_DIR/manifests/common/gateway.yaml
kubectl apply -f $POC_DIR/manifests/openshift/simulator.yaml
kubectl wait --for=condition=ready pod -l app=model-simulator \
  -n external-models --timeout=120s
```

> **AWS ELB note:** The LoadBalancer may take 2-3 minutes to become reachable
> after provisioning. If curl returns `000` or times out, wait and retry.

### Step 3: Deploy External Model Backend + MaaS Bridge

```bash
kubectl apply -f $POC_DIR/manifests/openshift/external-model.yaml
kubectl apply -f $POC_DIR/manifests/openshift/maas-bridge.yaml
```

### Step 4: Enable External Model Discovery in MaaS API

```bash
kubectl apply -f $POC_DIR/manifests/openshift/external-model-registry.yaml
kubectl annotate deployment maas-api -n opendatahub opendatahub.io/managed="false" --overwrite
kubectl set image deployment/maas-api -n opendatahub \
  maas-api=ghcr.io/nerdalert/maas-api:external-models
kubectl rollout status deployment/maas-api -n opendatahub --timeout=120s
```

---

## End-to-End Validation

```bash
# Get the gateway endpoint
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
HOST="maas.${CLUSTER_DOMAIN}"

# Mint a MaaS SA token (exchanges OpenShift identity for a scoped service account token)
TOKEN_RESPONSE=$(curl -sSk -H "Authorization: Bearer $(oc whoami -t)" \
  --json '{"expiration": "10m"}' "https://${HOST}/maas-api/v1/tokens")
TOKEN=$(echo $TOKEN_RESPONSE | jq -r .token)
echo $TOKEN

# List models - returns unified listing of local KServe models + external models from ConfigMap
MODELS=$(curl -sSk -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" "https://${HOST}/v1/models" | jq -r .)
echo $MODELS
MODEL_NAME=$(echo $MODELS | jq -r '.data[0].id')
echo "Model: $MODEL_NAME"

# Chat completion - routes through MaaS gateway -> bridge -> wg-ai-gateway Envoy -> simulator
curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}" \
  "https://${HOST}/external/v1/chat/completions" | jq

# Auth enforcement - no token returns 401 Unauthorized
curl -sSk -o /dev/null -w "%{http_code}\n" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}" \
  "https://${HOST}/external/v1/chat/completions"

# Token rate limiting - free tier (100 tokens/min), returns 200 then 429 after budget exhausted
for i in {1..16}; do
  curl -sSk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}" \
    "https://${HOST}/external/v1/chat/completions"
done
```

### Example Output

```
$> CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
  HOST="maas.${CLUSTER_DOMAIN}"

$> # 2. Get authentication token
  TOKEN_RESPONSE=$(curl -sSk -H "Authorization: Bearer $(oc whoami -t)" \
    --json '{"expiration": "10m"}' "https://${HOST}/maas-api/v1/tokens")
  TOKEN=$(echo $TOKEN_RESPONSE | jq -r .token)
  echo $TOKEN
eyJhbGciOiJSUzI1NiIsImtpZCI6IkRIYzNiLUItSlR6endxMTFUOHRJRTZNQlpSdEVua2pNb0JzdWNQZkZacGMifQ.eyJhdWQiOlsibWFhcy1kZWZhdWx0LWdhdGV3YXktc2EiXSwiZXhwIjoxNzcxMDAzNTEzLCJpYXQiOjE3NzEwMDI5MTMsImlzcyI6Imh0dHBzOi8va3ViZXJuZXRlcy5kZWZhdWx0LnN2YyIsImp0aSI6IjJlZGFiZmU0LTY0M2QtNDc0Yy1iMTU0LWIxMDdjM2I4YmE5MyIsImt1YmVybmV0ZXMuaW8iOnsibmFtZXNwYWNlIjoibWFhcy1kZWZhdWx0LWdhdGV3YXktdGllci1mcmVlIiwic2VydmljZWFjY291bnQiOnsibmFtZSI6Imt1YmUtYWRtaW4tODEzNzhhZjUiLCJ1aWQiOiIyN2ViMGRhZi0zMjg1LTQzZTUtOGQxZS05MTYwNWJkODMxYjcifX0sIm5iZiI6MTc3MTAwMjkxMywic3ViIjoic3lzdGVtOnNlcnZpY2VhY2NvdW50Om1hYXMtZGVmYXVsdC1nYXRld2F5LXRpZXItZnJlZTprdWJlLWFkbWluLTgxMzc4YWY1In0.snDoUOxGv8dJ236iYinGr8elDt2SL6tMmnjafvIvrxeRJLtI-pTO1FLia76LPLAkXjodEARjJ1PNR7Fcqae8Naf0S1oa3Cb8WrNuVjkOnfnUdhOdIxx7V8CzNy5GRN6TkegEwJ1dqMZv4lVXM_XSwPTzupyHetW8RGGL6PYgvtS1yuWzSXJutzldw5yQp8U1TpqN3kwbr9caYqazNeE2EXrxsuWlofd0TF_61n8r67Qfd882XFLw7wUmyEQLXNfXP5f_jd3hLjN0uup5DTmox2iIgev1rRJymY-H5T3bqoxhiu4D4zD2dMGiMP9U3dfHEEA-k3M0M9gBMWw3v0cd3W0V-b_0Hyo4idPoX5TAiIwCoJziu7j9WCUzouBXyVDEHutwruHUc0vXMiPZflIhvIbbB98VDS9K2Oe3PvB5pLe6XXhA6q9O8W6FPmoEfrMuHJGfDlJBsr5Y_envgCDNf_FCp1vKT-yAXtKERJeM8MWmFva8owGK2kDahPsudyS_4uQuxoX6TCXXfmf66piiB4MdjyZ5V3Oe1vYdl1QJeEVOv3lpyrFhoijL7ey6rsRgwA6r2in50ZjSFZCjSygNhzlBK4-Ig9io27CnXpj2ZrhuczEloeS_oh1c_uQA-RuuRrYCjtcLWjAzx0Nc0ZXXKfCY1qBFDHah5FeJcBKCkqc

$> # 3. List models (unified - local + external)
  MODELS=$(curl -sSk -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" "https://${HOST}/v1/models" | jq -r .)
  echo $MODELS
  MODEL_NAME=$(echo $MODELS | jq -r '.data[0].id')
  echo "Model: $MODEL_NAME"
{ "data": [ { "id": "gpt-4-external", "created": 1771002919, "object": "model", "owned_by": "openai", "ready": true }, { "id": "claude-3-sonnet-external", "created": 1771002919, "object": "model", "owned_by": "anthropic", "ready": true } ], "object": "list" }
Model: gpt-4-external

$>   # 4. Chat completion (external model via bridge)
  curl -sSk -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}" \
    "https://${HOST}/external/v1/chat/completions" | jq
{
  "id": "chatcmpl-3d1bc1b2-b3ed-43eb-893a-275500a9cc21",
  "created": 1771002933,
  "model": "gpt-4-external",
  "usage": {
    "prompt_tokens": 1,
    "completion_tokens": 16,
    "total_tokens": 17
  },
  "object": "chat.completion",
  "do_remote_decode": false,
  "do_remote_prefill": false,
  "remote_block_ids": null,
  "remote_engine_id": "",
  "remote_host": "",
  "remote_port": 0,
  "choices": [
    {
      "index": 0,
      "finish_reason": "stop",
      "message": {
        "role": "assistant",
        "content": "Today it is partially cloudy and raining. Testing, testing 1,2,3"
      }
    }
  ]
}

$> # 5. Test authorization limiting (no token -> 401)
  curl -sSk -o /dev/null -w "%{http_code}\n" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}" \
    "https://${HOST}/external/v1/chat/completions"
401

$> # 6. Test rate limiting (200 OK followed by 429 after token budget exhausted)
  for i in {1..16}; do
    curl -sSk -o /dev/null -w "%{http_code}\n" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}" \
      "https://${HOST}/external/v1/chat/completions"
  done
200
200
200
200
200
429
429
429
429
429
429
429
429
429
429
429
```

---

## Teardown

```bash
kubectl delete -f $POC_DIR/manifests/openshift/maas-bridge.yaml 2>/dev/null
kubectl delete -f $POC_DIR/manifests/openshift/external-model.yaml 2>/dev/null
kubectl delete -f $POC_DIR/manifests/openshift/external-model-registry.yaml 2>/dev/null
kubectl delete -f $POC_DIR/manifests/common/gateway.yaml 2>/dev/null
kubectl delete -f $POC_DIR/manifests/openshift/simulator.yaml 2>/dev/null
kubectl delete -f $POC_DIR/manifests/openshift/controller.yaml 2>/dev/null
kubectl delete -f $WG_DIR/../internal/backend/k8s/crds/ 2>/dev/null
```

---

## Known Issues

| Issue | Fix |
|-------|-----|
| ODH operator reverts MaaS API image | Annotate with `opendatahub.io/managed: "false"` before patching |
| AWS ELB takes 2-3 min to become reachable | Wait and retry |
| TLS origination not implemented | All backends use plain HTTP; needs upstream work |

## Manifest Inventory

```
manifests/
  common/
    gateway.yaml              POC Gateway (port 80, GatewayClass wg-ai-gateway)
  openshift/
    controller.yaml           wg-ai-gateway controller (SCC-adapted)
    simulator.yaml            Inference simulator in external-models namespace
    external-model.yaml       XBackendDestination + HTTPRoutes for simulator
    maas-bridge.yaml          HTTPRoute bridge + AuthPolicy (MaaS -> wg-ai-gateway)
    external-model-registry.yaml  ConfigMap listing external models for MaaS API
```
