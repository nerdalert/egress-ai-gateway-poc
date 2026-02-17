# Mixed Providers Demo: On-Prem + Simulated Providers + External vLLM

Demonstrates four model providers behind a single MaaS gateway:

| Provider | Model | Type | API Key | Endpoint |
|----------|-------|------|---------|----------|
| OpenAI (simulated) | `gpt-4` | External | `sk-openai-key-for-demo` | `/external/openai/v1/chat/completions` |
| Anthropic (simulated) | `claude-3-sonnet` | External | `sk-ant-claude-key-for-demo` | `/external/anthropic/v1/chat/completions` |
| vLLM (remote, optional) | `Qwen/Qwen3-0.6B` | External | `change-me-super-secret` | `/external/vllm/v1/chat/completions` |
| On-prem (KServe) | `facebook/opt-125m` | Local | None (MaaS SA token only) | `/llm/facebook-opt-125m-simulated/v1/chat/completions` |

Each external provider has its own API key injected by Authorino. The user
authenticates once with a MaaS SA token and accesses all providers.

**Prerequisites:**
- MaaS is deployed via `deploy-rhoai-stable.sh`
- [wg-ai-gateway](https://github.com/kubernetes-sigs/wg-ai-gateway) repo cloned (for CRDs)

**Forked images** (used until upstream PRs merge):
- Controller: `ghcr.io/nerdalert/wg-ai-gateway:latest` — includes
  [prefix rewrite fix](https://github.com/kubernetes-sigs/wg-ai-gateway/pull/38)
- MaaS API: `ghcr.io/nerdalert/maas-api:external-models` — adds
  ConfigMap-based external model discovery

```bash
# Adjust these to match your clone locations
export WG_DIR=<path-to>/wg-ai-gateway/prototypes/backend-control-plane
export POC_DIR=<path-to>/egress-ai-gateway-poc
```

---

## Deployment

### Step 1: Install CRDs + Controller + Gateway

Installs the `XBackendDestination` CRD (defines external FQDN backends),
deploys the wg-ai-gateway controller (reconciles Gateway/HTTPRoute into
Envoy xDS config), and creates a Gateway resource (triggers Envoy proxy
pod + LoadBalancer service deployment).

```bash
kubectl apply -f $WG_DIR/../internal/backend/k8s/crds/
kubectl apply -f $POC_DIR/manifests/openshift/controller.yaml
kubectl wait --for=condition=available deployment/ai-gateway-controller \
  -n ai-gateway-system --timeout=120s
kubectl apply -f $POC_DIR/manifests/common/gateway.yaml
```

### Step 2: Deploy the local on-prem model

Deploys the MaaS sample LLMInferenceService (`facebook/opt-125m`) using the
`llm-d-inference-sim` simulator. KServe creates an HTTPRoute on the MaaS gateway
automatically. This model is served directly by KServe/vLLM - no wg-ai-gateway involved.

```bash
kubectl create namespace llm
kustomize build 'https://github.com/opendatahub-io/models-as-a-service.git/docs/samples/models/simulator?ref=main' | kubectl apply -f -
```

### Step 3: Deploy external provider simulators + backends + routes

Deploys two `provider-sim` instances - one simulating OpenAI (validates key
`sk-openai-key-for-demo`, serves model `gpt-4`) and one simulating Anthropic
(validates key `sk-ant-claude-key-for-demo`, serves model `claude-3-sonnet`).

Then creates `XBackendDestination` resources pointing to each simulator via
cluster DNS FQDN, and `HTTPRoute` resources on the wg-ai-gateway Envoy that
route `/openai/*` and `/anthropic/*` to the correct backend with URL rewrite
stripping the prefix (so the simulator receives `/v1/chat/completions`).

```bash
# Simulators - key-validating pods in external-models namespace
kubectl apply -f $POC_DIR/demos/mixed-providers/manifests/openai-simulator.yaml
kubectl apply -f $POC_DIR/demos/mixed-providers/manifests/anthropic-simulator.yaml
kubectl wait --for=condition=ready pod -l app=openai-simulator -n external-models --timeout=120s
kubectl wait --for=condition=ready pod -l app=anthropic-simulator -n external-models --timeout=120s

# XBackendDestination (FQDN targets) + HTTPRoute (Envoy routing with URL rewrite)
kubectl apply -f $POC_DIR/demos/mixed-providers/manifests/backends.yaml
kubectl apply -f $POC_DIR/demos/mixed-providers/manifests/routes.yaml
```

### Step 3a (Optional): Deploy external vLLM backend

Adds a real remote vLLM instance as a 4th provider. Requires a vLLM server
running on a GPU machine accessible from the cluster over HTTP.

**Start vLLM on the remote host:**

```bash
export VLLM_API_KEY="change-me-super-secret"
docker run --rm -it \
  --gpus all \
  --ipc=host \
  -p 8000:8000 \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  vllm/vllm-openai:latest \
  --model Qwen/Qwen3-0.6B \
  --host 0.0.0.0 \
  --port 8000 \
  --api-key "$VLLM_API_KEY"
```

**Verify the vLLM instance is reachable:**

```bash
curl http://<VLLM_HOST>:8000/v1/chat/completions \
  -H "Authorization: Bearer change-me-super-secret" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Say hi in one sentence."}]}'
```

**Update the hardcoded vLLM host** in `backends.yaml` to match your server.
The default is `ec2-34-202-9-189.compute-1.amazonaws.com` — feel free to use
this endpoint for testing if it is still up at the time of reading. Files to
update:

| File | Field | Default |
|------|-------|---------|
| `backends.yaml` | `vllm-backend` → `spec.destination.fqdn.hostname` | `ec2-34-202-9-189.compute-1.amazonaws.com` |
| `bridge.yaml` | `vllm-bridge-auth` → `response.success.headers.Authorization` | `Bearer change-me-super-secret` |

```bash
kubectl apply -f $POC_DIR/demos/mixed-providers/manifests/backends.yaml
```

Unlike the simulators, vLLM uses standard `Authorization: Bearer` auth. The
bridge AuthPolicy overrides the `Authorization` header (replacing the MaaS SA
token with the vLLM API key) after authentication is complete.

### Step 4: Deploy per-provider routes + API key injection on MaaS Gateway

Creates per-provider HTTPRoutes on the MaaS Gateway that route
`/external/openai/*`, `/external/anthropic/*`, and `/external/vllm/*` to the
wg-ai-gateway Envoy. Each route has its own Kuadrant AuthPolicy that validates
the user's MaaS SA token and injects the provider-specific API key into the
upstream request via Authorino's `response.success.headers`.

```bash
kubectl apply -f $POC_DIR/demos/mixed-providers/manifests/bridge.yaml
```

### Step 5: Enable external model discovery in MaaS API

Deploys a ConfigMap listing external models (`gpt-4`, `claude-3-sonnet`, and
optionally `Qwen/Qwen3-0.6B`) and patches the MaaS API with a modified image
that reads it. The patched MaaS API merges these external models with
KServe-discovered local models so `GET /v1/models` returns all providers in a
single response.

```bash
kubectl apply -f $POC_DIR/demos/mixed-providers/manifests/external-model-registry.yaml
kubectl annotate deployment maas-api -n opendatahub opendatahub.io/managed="false" --overwrite
kubectl set image deployment/maas-api -n opendatahub \
  maas-api=ghcr.io/nerdalert/maas-api:external-models
kubectl rollout status deployment/maas-api -n opendatahub --timeout=120s
```

---

## Validation

```bash
# 1. Get gateway endpoint
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
HOST="maas.${CLUSTER_DOMAIN}"

# 2. Mint token
TOKEN=$(curl -sSk -H "Authorization: Bearer $(oc whoami -t)" \
  --json '{"expiration": "10m"}' "https://${HOST}/maas-api/v1/tokens" | jq -r .token)

# 3. List all models (local + external unified listing)
curl -sSk -H "Authorization: Bearer $TOKEN" "https://${HOST}/v1/models" | jq

# 4. Chat with OpenAI (external, key: sk-openai-key-for-demo)
curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"Hello from OpenAI"}],"max_tokens":10}' \
  "https://${HOST}/external/openai/v1/chat/completions" | jq

# 5. Chat with Anthropic (external, key: sk-ant-claude-key-for-demo)
curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-3-sonnet","messages":[{"role":"user","content":"Hello from Claude"}],"max_tokens":10}' \
  "https://${HOST}/external/anthropic/v1/chat/completions" | jq

# 6. Chat with vLLM (external, real model - requires Step 3a)
curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Say hi in one sentence."}],"max_tokens":20}' \
  "https://${HOST}/external/vllm/v1/chat/completions" | jq

# 7. Chat with local model (on-prem KServe, no external key needed)
curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"Hello from on-prem"}],"max_tokens":10}' \
  "https://${HOST}/llm/facebook-opt-125m-simulated/v1/chat/completions" | jq

# 8. No auth -> 401 (all providers)
curl -sSk -o /dev/null -w "%{http_code}\n" "https://${HOST}/external/openai/v1/models"
curl -sSk -o /dev/null -w "%{http_code}\n" "https://${HOST}/external/anthropic/v1/models"
curl -sSk -o /dev/null -w "%{http_code}\n" "https://${HOST}/external/vllm/v1/models"

# 9. Wrong API key -> 401 from vLLM (proves key injection is required)
curl -sSk -H "Authorization: Bearer bogus-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
  "http://ec2-34-202-9-189.compute-1.amazonaws.com:8000/v1/chat/completions"

# 10. Rate limiting (free tier: 100 tokens/min across all providers)
for i in {1..16}; do
  curl -sSk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
    "https://${HOST}/external/openai/v1/chat/completions"
done
```

### Example Output

**Model listing** (step 3) - all providers in a single response:

```shell
curl -sSk -H "Authorization: Bearer $TOKEN" "https://${HOST}/v1/models" | jq
{
  "data": [
    {
      "id": "facebook/opt-125m",
      "created": 1771301116,
      "object": "model",
      "owned_by": "vllm",
      "url": "http://maas.apps.ci-ln-xbmcth2-76ef8.aws-2.ci.openshift.org/llm/facebook-opt-125m-simulated",
      "ready": true
    },
    {
      "id": "gpt-4",
      "created": 1771301116,
      "object": "model",
      "owned_by": "openai",
      "ready": true
    },
    {
      "id": "claude-3-sonnet",
      "created": 1771301116,
      "object": "model",
      "owned_by": "anthropic",
      "ready": true
    },
    {
      "id": "Qwen/Qwen3-0.6B",
      "created": 1771305975,
      "object": "model",
      "owned_by": "vllm",
      "ready": true
    }
  ],
  "object": "list"
}
```

**OAI simulator inference** (step 4):

```shell
$ curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"Hello from OpenAI"}],"max_tokens":10}' \
  "https://${HOST}/external/openai/v1/chat/completions" | jq
{
  "choices": [
    {
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "content": "The API key was validated successfully. This is a simulated response.",
        "role": "assistant"
      }
    }
  ],
  "created": 1771301210,
  "id": "chatcmpl-1771301210831536425",
  "model": "gpt-4",
  "object": "chat.completion",
  "usage": {
    "completion_tokens": 23,
    "prompt_tokens": 2,
    "total_tokens": 25
  }
}
```

**External vLLM inference** (step 6):

```shell
curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Say hi in one sentence."}],"max_tokens":20}' \
  "https://${HOST}/external/vllm/v1/chat/completions" | jq
{
  "id": "chatcmpl-dba5b1cc-67e8-4afc-9bdf-590667f7f444",
  "object": "chat.completion",
  "created": 1771307402,
  "model": "Qwen/Qwen3-0.6B",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "reasoning_content": null,
        "content": "<think>\nOkay, the user wants a one-sentence greeting. Let me think. It should be",
        "tool_calls": []
      },
      "logprobs": null,
      "finish_reason": "length",
      "stop_reason": null
    }
  ],
  "usage": {
    "prompt_tokens": 14,
    "total_tokens": 34,
    "completion_tokens": 20,
    "prompt_tokens_details": null
  },
  "prompt_logprobs": null
}
```

**External vLLM negative test** pass an invalid key to vLLM

```shell
curl http://ec2-34-202-9-189.compute-1.amazonaws.com.:8000/v1/chat/completions   -H "Authorization: Bearer invalid-key" -H "Content-Type: application/json"   -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Say hi in one sentence."}]}'
{"error":"Unauthorized"}
```

**On-prem inference** (step 7):

Note: `facebook/opt-125m` is auto-discovered by MaaS via KServe. The external models come from the `external-model-registry` ConfigMap.

```shell
$ curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"Hello from on-prem"}],"max_tokens":10}' \
  "https://${HOST}/llm/facebook-opt-125m-simulated/v1/chat/completions" | jq
{
  "id": "chatcmpl-05bbc6c5-a28b-54d7-9958-86f8ac62b6c6",
  "created": 1771301329,
  "model": "facebook/opt-125m",
  "usage": {
    "prompt_tokens": 5,
    "completion_tokens": 5,
    "total_tokens": 10
  },
  "object": "chat.completion",
  "kv_transfer_params": null,
  "choices": [
    {
      "index": 0,
      "finish_reason": "stop",
      "message": {
        "role": "assistant",
        "content": "Testing@, #testing "
      }
    }
  ]
}
```

### Expected Results

| # | Test | Expected |
|---|------|----------|
| 3 | List models | `facebook/opt-125m` (local) + `gpt-4` + `claude-3-sonnet` + `Qwen/Qwen3-0.6B` (external) |
| 4 | OpenAI chat | 200, completion from gpt-4 simulator |
| 5 | Anthropic chat | 200, completion from claude-3-sonnet simulator |
| 6 | vLLM chat | 200, real completion from Qwen3-0.6B (requires Step 3a) |
| 7 | Local model chat | 200, completion from KServe/vLLM simulator |
| 8 | No auth | 401, 401, 401 |
| 9 | Wrong API key to vLLM | 401, `{"error":"..."}` |
| 10 | Rate limiting | 200s then 429s |

---

## Architecture

### Routing Overview

```
User (single MaaS SA token)
  │
  ▼
MaaS Gateway (maas.$CLUSTER_DOMAIN, Istio)
  │
  ├── /external/openai/*     → Authorino injects sk-openai-key-for-demo
  │                            → wg-ai-gateway Envoy → openai-simulator
  │
  ├── /external/anthropic/*  → Authorino injects sk-ant-claude-key-for-demo
  │                            → wg-ai-gateway Envoy → anthropic-simulator
  │
  ├── /external/vllm/*       → Authorino overrides Authorization header
  │                            → wg-ai-gateway Envoy → remote vLLM (HTTP)
  │
  ├── /llm/<model>/*         → Authorino validates SA token + SubjectAccessReview
  │                            → KServe InferenceService (on-prem vLLM)
  │
  └── /v1/models             → MaaS API (unified listing: local + external)
```

### E2E Traffic Flow: External Provider (e.g., OpenAI)

Shows the exact path and URL rewriting at each hop for a request to
`POST /external/openai/v1/chat/completions`:

```
Client
  │  POST https://maas.$CLUSTER_DOMAIN/external/openai/v1/chat/completions
  │  Header: Authorization: Bearer <maas-sa-token>
  │  Body: {"model":"gpt-4","messages":[...],"max_tokens":10}
  │
  ▼
MaaS Istio Gateway (openshift-ingress)
  │  1. TLS termination
  │  2. HTTPRoute matches /external/openai/*
  │  3. Kuadrant AuthPolicy:
  │       a) Validates SA token (kubernetesTokenReview)
  │       b) Extracts tier from SA namespace
  │       c) Injects header: X-Provider-Api-Key: sk-openai-key-for-demo
  │  4. URL rewrite: /external/openai/* → /openai/*
  │  5. Forward to envoy-poc-gateway:80
  │
  │  Path is now: /openai/v1/chat/completions
  │  Headers now include: X-Provider-Api-Key: sk-openai-key-for-demo
  │
  ▼
wg-ai-gateway Envoy (default namespace, xDS-configured)
  │  1. HTTPRoute "openai-route" matches /openai/*
  │  2. URL rewrite: /openai/* → /*
  │  3. Resolves XBackendDestination "openai-backend" FQDN via DNS
  │  4. Forward to openai-simulator.external-models.svc.cluster.local:8000
  │
  │  Path is now: /v1/chat/completions  (matches real provider API)
  │  Headers: X-Provider-Api-Key: sk-openai-key-for-demo (passed through)
  │
  ▼
OpenAI Simulator (external-models namespace)
  │  1. Checks X-Provider-Api-Key header
  │       Missing → 401 {"error":"missing_api_key"}
  │       Wrong   → 401 {"error":"invalid_api_key"}
  │       Correct → process request
  │  2. Returns chat completion response
  │
  ▼
Response flows back: Simulator → Envoy → Istio → Client
  {"model":"gpt-4","choices":[{"message":{"content":"..."}}],"usage":{...}}
```

### E2E Traffic Flow: External vLLM (Optional)

Similar to the OpenAI flow, but the key difference is auth header handling:
vLLM uses standard `Authorization: Bearer` auth, so the AuthPolicy overrides
the `Authorization` header instead of adding `X-Provider-Api-Key`. The backend
is a remote machine (HTTP, not cluster-local).

```
Client
  │  POST https://maas.$CLUSTER_DOMAIN/external/vllm/v1/chat/completions
  │  Header: Authorization: Bearer <maas-sa-token>
  │
  ▼
MaaS Gateway
  │  1. AuthPolicy validates MaaS SA token
  │  2. Overrides Authorization header → Bearer change-me-super-secret
  │  3. URL rewrite: /external/vllm/* → /vllm/*
  │  4. Forward to envoy-poc-gateway:80
  │
  ▼
wg-ai-gateway Envoy
  │  1. URL rewrite: /vllm/* → /*
  │  2. Resolves vllm-backend → ec2-34-202-9-189.compute-1.amazonaws.com
  │  3. K8s Endpoints routes to remote IP (e.g., 34.202.9.189:8000)
  │
  ▼
Remote vLLM Instance (HTTP, real GPU inference)
  │  Validates Authorization: Bearer change-me-super-secret
  │  Runs Qwen/Qwen3-0.6B inference
  │
  ▼
Response: {"model":"Qwen/Qwen3-0.6B","choices":[...],"usage":{...}}
```

### E2E Traffic Flow: On-Prem Model

The on-prem path does NOT traverse the wg-ai-gateway. It goes directly from
the MaaS Istio gateway to the KServe InferenceService.

```
Client
  │  POST https://maas.$CLUSTER_DOMAIN/llm/facebook-opt-125m-simulated/v1/chat/completions
  │  Header: Authorization: Bearer <maas-sa-token>
  │
  ▼
MaaS Gateway (single gateway, Istio-based)
  │  1. TLS termination
  │  2. Gateway-level AuthPolicy validates SA token
  │  3. SubjectAccessReview checks RBAC for llminferenceservices resource
  │  4. TokenRateLimitPolicy checks token budget
  │  5. KServe-created HTTPRoute matches /llm/facebook-opt-125m-simulated/*
  │  6. Istio DestinationRule handles TLS to the model backend (HTTPS)
  │  7. Routes directly to KServe workload Service (no wg-ai-gateway)
  │
  ▼
KServe/vLLM (llm namespace, port 8000 HTTPS)
  │  Returns chat completion response
  │
  ▼
Response flows back to client
  {"model":"facebook/opt-125m","choices":[{"message":{"content":"..."}}],"usage":{...}}
```

### Key Design: URL Rewriting (External Providers Only)

External provider requests go through two URL rewrites so the backend
receives clean `/v1/*` paths matching real provider API conventions.
On-prem models do not use URL rewriting.

```
Client sends:         /external/openai/v1/chat/completions
  ↓ MaaS Gateway HTTPRoute URLRewrite filter
wg-ai-gateway receives: /openai/v1/chat/completions
  ↓ wg-ai-gateway Envoy rewrite (provider HTTPRoute URLRewrite filter)
Simulator receives:   /v1/chat/completions    ← matches real OpenAI API path
```

This means the simulator (or a real provider once TLS is implemented) sees
the same `/v1/chat/completions` path that `api.openai.com` expects.

## Teardown

```bash
# Core resources
kubectl delete -f demos/mixed-providers/manifests/bridge.yaml
kubectl delete -f demos/mixed-providers/manifests/routes.yaml
kubectl delete -f demos/mixed-providers/manifests/backends.yaml
kubectl delete -f demos/mixed-providers/manifests/anthropic-simulator.yaml
kubectl delete -f demos/mixed-providers/manifests/openai-simulator.yaml
kubectl delete -f demos/mixed-providers/manifests/external-model-registry.yaml
kubectl delete namespace llm
```
