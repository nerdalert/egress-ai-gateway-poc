# Mixed Providers Demo: Single External Endpoint with Lua Dispatch

All external models are served behind one endpoint:

```
POST /v1/chat/completions
```

The `model` field in the request body determines which provider receives the request and which API key is injected. Clients never change URLs when models move between providers.

| Provider | Model | Type |
|----------|-------|------|
| OpenAI (simulated) | `gpt-4` | External |
| Anthropic (simulated) | `claude-3-sonnet` | External |
| vLLM (remote GPU) | `Qwen/Qwen3-0.6B` | External |
| On-prem (KServe) | `facebook/opt-125m` | Local (separate path) |

## Why Lua Instead of Pure Kuadrant AuthPolicy

Kuadrant's wasm-shim processes requests in two phases inside Envoy's filter chain. The auth call to Authorino happens before the request body is available, so Authorino cannot read the `model` field to decide which API key to inject. The rate-limit evaluation happens after the body arrives, so `requestBodyJSON('/model')` works for per-model rate limiting. This phase split is the reason a Lua filter is used for key injection.

### Detailed Envoy Filter Chain Timeline

1. **Client sends the request.** `POST /v1/chat/completions` with `Authorization: Bearer <maas-sa-token>` in the headers and `{"model":"gpt-4",...}` in the body. Envoy receives the headers first; the body arrives separately after.

2. **Envoy calls the wasm-shim's `on_http_request_headers()` callback** as soon as headers arrive. The Kuadrant wasm-shim is an HTTP filter in the Envoy filter chain.

3. **The wasm-shim triggers the auth action.** Inside `on_http_request_headers()`, the wasm-shim sees an AuthPolicy configured for this route. It immediately makes a gRPC call to Authorino, sending request metadata (method, path, headers). The body has not arrived from the client yet, so it cannot be included in the gRPC request.

4. **Authorino validates the token but cannot see the body.** Authorino receives the gRPC call, validates the bearer token from the `Authorization` header, and returns "authorized." The field `input.request.body` is an empty string because the wasm-shim did not send it. Any OPA policy trying `json.unmarshal("")` on the body fails silently.

5. **Envoy receives the full request body from the client.** It calls the wasm-shim's `on_http_request_body()` callback. The body is now available.

6. **The wasm-shim evaluates rate-limit actions.** Inside `on_http_request_body()`, it calls `requestBodyJSON('/model')` which parses the body and extracts `"gpt-4"`. The predicate `requestBodyJSON('/model') == "gpt-4"` matches, so the `gpt4-requests-per-user` rate-limit counter increments. Per-model rate limiting works because it runs in this phase.

7. **The Lua filter runs.** After the wasm-shim completes, the Lua filter's `envoy_on_request()` fires. It calls `request_handle:body()` to access the buffered body, extracts the `model` field via string matching, and overwrites the `Authorization` header with the correct provider API key. It also sets the `X-Target-Provider` header for downstream routing.

8. **Envoy forwards the request upstream** to the wg-ai-gateway Envoy (`envoy-poc-gateway:80`). The request now has the provider's API key in the `Authorization` header and the provider name in `X-Target-Provider`.

9. **wg-ai-gateway Envoy matches the `X-Target-Provider` header** and routes to the correct `XBackendDestination` (e.g., `openai-backend` which resolves to `openai-simulator.external-models.svc.cluster.local:8000`).

10. **The provider backend validates the API key and returns a response.** The response flows back through wg-ai-gateway, the MaaS gateway, and to the client.

The gap is between steps 3 and 5. The wasm-shim makes the auth call at step 3 but does not have the body until step 5. If the wasm-shim delayed the auth call to step 5 (or re-sent it with the body), Authorino could parse the model and inject the correct key natively, eliminating the need for the Lua filter. This would require a wasm-shim code change.

## Architecture

```
Client
  |  POST /v1/chat/completions
  |  Authorization: Bearer <maas-sa-token>
  |  Body: {"model":"gpt-4","messages":[...],"max_tokens":10}
  |
  v
MaaS Gateway Envoy (openshift-ingress)
  |
  |  Step 1: TLS termination
  |  Step 2: HTTPRoute/default/unified-inference matches /v1/chat/completions
  |  Step 3: Kuadrant wasm-shim auth action (headers phase)
  |           -> gRPC to Authorino, validates MaaS SA token
  |           -> body not available yet, no model-based logic possible
  |  Step 4: Kuadrant wasm-shim rate-limit action (body phase)
  |           -> requestBodyJSON('/model') == "gpt-4" matches
  |           -> gpt4-requests-per-user counter increments
  |  Step 5: Lua filter (body phase, after wasm-shim)
  |           -> parses model from body: "gpt-4"
  |           -> sets Authorization: Bearer sk-openai-key-for-demo
  |           -> sets X-Target-Provider: openai
  |  Step 6: Forward to envoy-poc-gateway:80
  |
  v
wg-ai-gateway Envoy (default namespace)
  |  HTTPRoute matches header X-Target-Provider: openai
  |  -> openai-backend XBackendDestination
  |  -> openai-simulator.external-models.svc.cluster.local:8000
  |
  v
OpenAI Simulator
  |  Validates Authorization: Bearer sk-openai-key-for-demo
  |  Returns chat completion response
  |
  v
Response returns: simulator -> wg-ai-gateway -> MaaS gateway -> client
```

On-prem model traffic does not traverse the Lua filter or wg-ai-gateway:
- `POST /llm/facebook-opt-125m-simulated/v1/chat/completions` routes directly through MaaS gateway to KServe.

## Manifests

| File | Purpose |
|------|---------|
| `bridge.yaml` | `HTTPRoute` for `/v1/chat/completions` + `AuthPolicy` (token validation, tier lookup) + `RateLimitPolicy` (per-model request limits via `requestBodyJSON('/model')`) |
| `lua-key-injector.yaml` | Istio `EnvoyFilter` — Lua script on MaaS gateway that reads the body, maps model to provider key, sets `Authorization` and `X-Target-Provider` headers |
| `routes.yaml` | wg-ai-gateway `HTTPRoute` resources matching `X-Target-Provider` header to route to provider backends |
| `backends.yaml` | `XBackendDestination` resources pointing to provider FQDNs (simulators + vLLM) |
| `openai-simulator.yaml` | OpenAI simulator deployment + service in `external-models` namespace |
| `anthropic-simulator.yaml` | Anthropic simulator deployment + service in `external-models` namespace |
| `external-model-registry.yaml` | ConfigMap listing external models for unified `/v1/models` response |

### Key Manifest: `lua-key-injector.yaml`

The Lua filter is an Istio `EnvoyFilter` that targets the MaaS gateway workload. It inserts a Lua HTTP filter before `envoy.filters.http.router` so it runs after the wasm-shim (auth + rate limiting) but before upstream forwarding.

The Lua script:
- Only activates on `/v1/chat/completions` paths
- Calls `request_handle:body()` to buffer the full request body
- Extracts the `model` field via pattern matching (`"model"%s*:%s*"([^"]+)"`)
- Looks up the model in `MODEL_KEYS` and `MODEL_PROVIDERS` tables
- Replaces the `Authorization` header with the provider's API key
- Sets `X-Target-Provider` header for wg-ai-gateway routing
- Returns HTTP 400 for missing body, missing model, or unsupported model

### Key Manifest: `bridge.yaml`

Contains three resources on a single `HTTPRoute`:

- **AuthPolicy** (`unified-inference-auth`): Validates the MaaS SA token via `kubernetesTokenReview`, looks up user tier via metadata HTTP callout.

- **RateLimitPolicy** (`unified-inference-request-rate-limits`): Independent per-model request buckets using `requestBodyJSON('/model')` predicates. Each model has its own limit (5 req/min per user):
  - `gpt4-requests-per-user`: `requestBodyJSON('/model') == "gpt-4"`
  - `claude-requests-per-user`: `requestBodyJSON('/model') == "claude-3-sonnet"`
  - `qwen-requests-per-user`: `requestBodyJSON('/model') == "Qwen/Qwen3-0.6B"`

- **HTTPRoute** (`unified-inference`): Routes `/v1/chat/completions` to `envoy-poc-gateway:80`.

Gateway-level `TokenRateLimitPolicy` remains active for token budget enforcement.

## Prerequisites

- MaaS deployed (`deploy-rhoai-stable.sh` or equivalent)
- `kubectl`, `oc`, `jq`
- `wg-ai-gateway` repo cloned for CRDs

```bash
git clone https://github.com/kubernetes-sigs/wg-ai-gateway.git
git clone https://github.com/nerdalert/egress-ai-gateway-poc.git

cd egress-ai-gateway-poc
export POC_DIR=$(pwd)
export WG_DIR=../wg-ai-gateway/prototypes/backend-control-plane
```

## Install

### 1) Install wg-ai-gateway CRDs, controller, and gateway

```bash
kubectl apply -f $WG_DIR/backend/k8s/crds/
kubectl apply -f $POC_DIR/manifests/openshift/controller.yaml
kubectl wait --for=condition=available deployment/ai-gateway-controller \
  -n ai-gateway-system --timeout=120s
kubectl apply -f $POC_DIR/manifests/common/gateway.yaml
```

> **ROSA clusters:** If the Envoy proxy pod stays `Pending` with `Insufficient cpu`:
> ```bash
> kubectl patch deployment envoy-poc-gateway -n default --type='json' \
>   -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"10m"}]'
> ```

### 2) Deploy on-prem model (KServe simulator)

```bash
kubectl create namespace llm --dry-run=client -o yaml | kubectl apply -f -
kustomize build 'https://github.com/opendatahub-io/models-as-a-service.git/docs/samples/models/simulator?ref=main' | kubectl apply -f -
```

### 3) Deploy external provider simulators

```bash
kubectl apply -f $POC_DIR/demos/mixed-providers-unified-path/manifests/openai-simulator.yaml
kubectl apply -f $POC_DIR/demos/mixed-providers-unified-path/manifests/anthropic-simulator.yaml
kubectl wait --for=condition=ready pod -l app=openai-simulator -n external-models --timeout=120s
kubectl wait --for=condition=ready pod -l app=anthropic-simulator -n external-models --timeout=120s
```

### 4) Deploy backends, header-based routes, bridge policies, and Lua filter

```bash
kubectl apply -f $POC_DIR/demos/mixed-providers-unified-path/manifests/backends.yaml
kubectl apply -f $POC_DIR/demos/mixed-providers-unified-path/manifests/routes.yaml
kubectl apply -f $POC_DIR/demos/mixed-providers-unified-path/manifests/bridge.yaml
kubectl apply -f $POC_DIR/demos/mixed-providers-unified-path/manifests/lua-key-injector.yaml
```

### 5) Enable external model listing in MaaS API

```bash
kubectl apply -f $POC_DIR/demos/mixed-providers-unified-path/manifests/external-model-registry.yaml
kubectl annotate deployment maas-api -n opendatahub opendatahub.io/managed="false" --overwrite
kubectl set image deployment/maas-api -n opendatahub \
  maas-api=ghcr.io/nerdalert/maas-api:external-models
kubectl rollout status deployment/maas-api -n opendatahub --timeout=120s
```

## Validation

### Setup

```bash
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
HOST="maas.${CLUSTER_DOMAIN}"

TOKEN=$(curl -sSk -H "Authorization: Bearer $(oc whoami -t)" \
  --json '{"expiration":"10m"}' \
  "https://${HOST}/maas-api/v1/tokens" | jq -r .token)
```

### Model listing

```bash
curl -sSk -H "Authorization: Bearer $TOKEN" "https://${HOST}/maas-api/v1/models" | jq
```

### Inference — all models via single endpoint

```bash
# OpenAI (simulated)
curl -sSk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hello"}],"max_tokens":10}' \
  "https://${HOST}/v1/chat/completions" | jq

# Anthropic (simulated)
curl -sSk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"claude-3-sonnet","messages":[{"role":"user","content":"hello"}],"max_tokens":10}' \
  "https://${HOST}/v1/chat/completions" | jq

# vLLM (real GPU inference)
curl -sSk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"hello"}],"max_tokens":10}' \
  "https://${HOST}/v1/chat/completions" | jq

# On-prem (KServe, separate path)
curl -sSk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"hello"}],"max_tokens":10}' \
  "https://${HOST}/llm/facebook-opt-125m-simulated/v1/chat/completions" | jq
```

### Per-model rate limiting (independent buckets)

Apply the gateway-scoped rate-limit policy before running the loops:

```bash
kubectl apply -f $POC_DIR/demos/mixed-providers-unified-path/manifests/gateway-rate-limits.yaml
kubectl delete ratelimitpolicy unified-inference-request-rate-limits -n default --ignore-not-found=true
```

Each model has a separate 5 req/min budget per user. Hitting the gpt-4 limit does not affect claude-3-sonnet or Qwen.

```bash
# gpt-4 over unified endpoint (expect 200s then 429s)
for i in {1..16}; do
  curl -sSk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
    "https://${HOST}/v1/chat/completions"
done

# claude-3-sonnet over unified endpoint (independent bucket)
for i in {1..16}; do
  curl -sSk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"model":"claude-3-sonnet","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
    "https://${HOST}/v1/chat/completions"
done

# Qwen/Qwen3-0.6B over unified endpoint (independent bucket)
for i in {1..16}; do
  curl -sSk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
    "https://${HOST}/v1/chat/completions"
done

# local on-prem model (separate /llm path, same gateway token budget)
for i in {1..16}; do
  curl -sSk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
    "https://${HOST}/llm/facebook-opt-125m-simulated/v1/chat/completions"
done
```

### Expected Results

| Test | Expected |
|------|----------|
| Model listing | All 4 models (1 local + 3 external) |
| gpt-4 inference | 200 |
| claude-3-sonnet inference | 200 |
| Qwen/Qwen3-0.6B inference | 200 |
| On-prem inference | 200 |
| Per-model rate limits | 200s then 429s, independent per model |

## Troubleshooting

### Lua filter not taking effect

```bash
# Check EnvoyFilter exists
kubectl get envoyfilter -n openshift-ingress

# Check for Lua errors in gateway pod logs
GATEWAY_POD=$(oc get pods -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
  -o jsonpath='{.items[0].metadata.name}')
oc logs $GATEWAY_POD -n openshift-ingress --tail=20
```

### 404 from wg-ai-gateway

The `X-Target-Provider` header is not being set or does not match any route. Check:
- Lua filter is loaded (see above)
- `routes.yaml` header values match exactly (`openai`, `anthropic`, `vllm`)
- The Envoy pod `envoy-poc-gateway` is running

### ROSA blocks EnvoyFilter

If `EnvoyFilter` creation is denied in `openshift-ingress`, use the path-based demo in `demos/mixed-providers/` instead, which does not require `EnvoyFilter`.

## Teardown

```bash
kubectl delete -f $POC_DIR/demos/mixed-providers-unified-path/manifests/lua-key-injector.yaml
kubectl delete -f $POC_DIR/demos/mixed-providers-unified-path/manifests/bridge.yaml
kubectl delete -f $POC_DIR/demos/mixed-providers-unified-path/manifests/routes.yaml
kubectl delete -f $POC_DIR/demos/mixed-providers-unified-path/manifests/backends.yaml
kubectl delete -f $POC_DIR/demos/mixed-providers-unified-path/manifests/anthropic-simulator.yaml
kubectl delete -f $POC_DIR/demos/mixed-providers-unified-path/manifests/openai-simulator.yaml
kubectl delete -f $POC_DIR/demos/mixed-providers-unified-path/manifests/external-model-registry.yaml
kubectl delete namespace llm
```
