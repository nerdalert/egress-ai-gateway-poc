# End-to-End Architecture: API Key Injection for External Models

## Overview

This POC demonstrates how MaaS (Models-as-a-Service) on OpenShift can route
inference requests to external model providers while automatically injecting
provider API keys - without the user ever seeing or managing those keys.

The user authenticates with their OpenShift identity, receives a MaaS token,
and makes inference requests. Behind the scenes, the platform swaps the user's
MaaS token for the provider's API key before the request reaches the external model.

## Why Hardcoded Keys (for now)

The upstream Kubernetes SIG WG AI Gateway (`wg-ai-gateway`) prototype does not
yet support TLS origination. All `XBackendDestination` FQDN backends use plain
HTTP. This means real external providers (OpenAI, Anthropic, etc.) which require
HTTPS cannot be reached directly.

To validate the key injection mechanism end-to-end, we built a key-validating
simulator (`provider-sim`) that:
- Runs inside the cluster over plain HTTP (no TLS needed)
- Requires `X-Provider-Api-Key` header with a specific value
- Returns 401 if the key is missing or wrong
- Returns OpenAI-compatible chat completions if the key is correct

Each provider simulator has a different API key:
- OpenAI simulator: `sk-openai-key-for-demo`
- Anthropic simulator: `sk-ant-claude-key-for-demo`

When TLS origination is implemented upstream, the same AuthPolicy mechanism
works unchanged - just point the `XBackendDestination` at the real provider
FQDN with TLS enabled.

## Component Diagram

```
Client (curl / app)
  │
  │  HTTPS (TLS terminated by Istio)
  │  Host: maas.$CLUSTER_DOMAIN
  │  Path: /external/openai/v1/chat/completions
  │  Header: Authorization: Bearer <maas-sa-token>
  │
  ▼
┌──────────────────────────────────────────┐
│  MaaS Gateway (Istio)                    │
│  openshift-ingress namespace             │
│  GatewayClass: openshift-default         │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │  Kuadrant / Authorino             │  │
│  │                                    │  │
│  │  1. Validate SA token             │  │
│  │  2. Extract tier from namespace   │  │
│  │  3. Inject X-Provider-Api-Key     │  │  ◄── KEY SWAP HAPPENS HERE
│  │     (per-provider key injected)   │  │
│  └────────────────────────────────────┘  │
│                                          │
│  Per-provider HTTPRoute:                 │
│    /external/openai/* → envoy:80         │
│    URL rewrite: /external/openai/ → /openai/│
│    (separate route + AuthPolicy per provider)│
└──────────────────┬───────────────────────┘
                   │
                   │  HTTP (internal, no TLS)
                   │  Path: /openai/v1/chat/completions
                   │  Headers:
                   │    Authorization: Bearer <sa-token> (original)
                   │    X-Provider-Api-Key: sk-openai-... (INJECTED)
                   │
                   ▼
┌──────────────────────────────────────────┐
│  wg-ai-gateway Envoy Proxy              │
│  default namespace                       │
│  GatewayClass: wg-ai-gateway            │
│                                          │
│  HTTPRoute: /openai/* → openai-backend   │
│  URL rewrite: /openai/* → /*             │
│    → XBackendDestination (FQDN)          │
│      openai-simulator                    │
│      .external-models.svc.cluster.local  │
│      port 8000                           │
└──────────────────┬───────────────────────┘
                   │
                   │  HTTP (internal)
                   │  Path: /v1/chat/completions  ← matches real provider API
                   │  Headers:
                   │    X-Provider-Api-Key: sk-openai-... (passed through)
                   │
                   ▼
┌──────────────────────────────────────────┐
│  Key-Validating Simulator               │
│  (ghcr.io/nerdalert/provider-sim)       │
│  external-models namespace               │
│                                          │
│  Checks X-Provider-Api-Key header:       │
│    Missing  → 401 {"error":"missing"}    │
│    Wrong    → 401 {"error":"invalid"}    │
│    Correct  → 200 {chat completion}      │
│                                          │
│  Simulates a real provider (OpenAI,      │
│  Anthropic) validating its API key.      │
└──────────────────────────────────────────┘
```

## URL Rewrite Chain

Each external provider request goes through two URL rewrites so the backend
receives clean `/v1/*` paths matching real provider API conventions:

```
Client sends:         /external/openai/v1/chat/completions
  ↓ MaaS Gateway HTTPRoute URLRewrite filter
wg-ai-gateway receives: /openai/v1/chat/completions
  ↓ wg-ai-gateway Envoy HTTPRoute URLRewrite filter
Simulator receives:   /v1/chat/completions    ← matches api.openai.com path
```

On-prem models do not use URL rewriting or the wg-ai-gateway. They route
directly from the MaaS Gateway to KServe.

## User Flow

### Step 1: Authenticate

```bash
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
HOST="maas.${CLUSTER_DOMAIN}"
```

### Step 2: Mint a MaaS Token

The user exchanges their OpenShift identity for a scoped MaaS service account
token. The token encodes the user's tier (free/premium/enterprise) in the
service account namespace.

```bash
TOKEN=$(curl -sSk -H "Authorization: Bearer $(oc whoami -t)" \
  --json '{"expiration": "10m"}' "https://${HOST}/maas-api/v1/tokens" | jq -r .token)
```

### Step 3: List Available Models

The unified model listing includes both on-prem KServe models and external
models from the ConfigMap registry.

```bash
curl -sSk -H "Authorization: Bearer $TOKEN" "https://${HOST}/v1/models" | jq
```

### Step 4: Send Inference Request

The user sends a standard OpenAI-compatible chat completion request. The
platform handles key injection transparently. The user never sees the
provider API key.

```bash
# External model (OpenAI simulator)
curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
  "https://${HOST}/external/openai/v1/chat/completions" | jq

# External model (Anthropic simulator)
curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-3-sonnet","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
  "https://${HOST}/external/anthropic/v1/chat/completions" | jq

# On-prem model (KServe, no wg-ai-gateway, no key injection)
curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
  "https://${HOST}/llm/facebook-opt-125m-simulated/v1/chat/completions" | jq
```

### Step 5: Verify Key Enforcement

These tests prove the simulator rejects requests without the correct key,
and only accepts when Authorino injects it through the MaaS Gateway:

```bash
ENVOY_ELB=$(kubectl get svc envoy-poc-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Direct to simulator - NO key → 401
curl -s http://${ENVOY_ELB}/openai/v1/models

# Direct to simulator - WRONG key → 401
curl -s -H "X-Provider-Api-Key: wrong-key" http://${ENVOY_ELB}/openai/v1/models

# Direct to simulator - CORRECT key → 200
curl -s -H "X-Provider-Api-Key: sk-openai-key-for-demo" \
  http://${ENVOY_ELB}/openai/v1/models

# Via MaaS Gateway (Authorino injects key) → 200
curl -sSk -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}' \
  "https://${HOST}/external/openai/v1/chat/completions"

# Via MaaS Gateway - NO MaaS token → 401
curl -sSk -o /dev/null -w "%{http_code}\n" \
  "https://${HOST}/external/openai/v1/models"
```

### Expected Results

| # | Test | Path | Key Source | Expected |
|---|------|------|-----------|----------|
| 1 | Direct, no key | `/openai/v1/models` | None | 401 `missing_api_key` |
| 2 | Direct, wrong key | `/openai/v1/models` | Manual (wrong) | 401 `invalid_api_key` |
| 3 | Direct, correct key | `/openai/v1/models` | Manual (correct) | 200 model list |
| 4 | MaaS Gateway with token | `/external/openai/v1/chat/completions` | Authorino (injected) | 200 chat completion |
| 5 | MaaS Gateway without token | `/external/openai/v1/models` | None (no auth) | 401 MaaS auth |

## How Key Injection Works (Kuadrant AuthPolicy)

```yaml
# Per-provider AuthPolicy on the MaaS Gateway:
response:
  success:
    headers:
      X-Provider-Api-Key:
        plain:
          expression: "'sk-openai-key-for-demo'"  # CEL string literal
```

Authorino's `response.success.headers` adds headers to Envoy's
`CheckResponse.OkResponse.Headers`. The Istio proxy injects them
into the upstream request before forwarding.

**Important:** Use `expression: "'string'"` (CEL literal with single
quotes inside double quotes). Using `value: "string"` serializes as
a byte array.

## Production Path

When TLS origination is added to the wg-ai-gateway upstream and MaaS gets
Postgres-backed key storage:

1. Replace `XBackendDestination` hostname with real provider FQDN
   (`api.openai.com:443` with `tls.mode: Simple`)
2. Replace hardcoded key expression with `metadata.http` callout to
   MaaS API (`/v1/provider-keys?provider=openai&tier=free`)
3. Change injected header name from `X-Provider-Api-Key` to
   `Authorization` (for OpenAI) or `x-api-key` (for Anthropic)
4. No changes to the HTTPRoute structure, AuthPolicy mechanism, or
   wg-ai-gateway controller

The AuthPolicy `response.success.headers` mechanism is the same in
production as in this POC - only the value source changes.
