# MaaS External Models via Native Istio Resources

## Overview

This demo adds external AI model routing to an existing MaaS deployment using
native Istio resources (ServiceEntry, DestinationRule, ExternalName Service)
and Gateway API HTTPRoute. No custom controllers or CRDs beyond what MaaS and
Istio already provide.

## What This Demo Does

Routes requests from the MaaS gateway directly to external AI providers
(OpenAI, Anthropic) using the same 4-resource pattern validated in the
[istio-external-model-routing](../istio-external-model-routing/) demo, but
integrated with the MaaS auth and gateway infrastructure.

| Component | Source |
|-----------|--------|
| Gateway | MaaS gateway (`maas-default-gateway` in `openshift-ingress`) |
| Auth | Kuadrant AuthPolicy (validates MaaS SA token, injects provider API key) |
| External routing | ServiceEntry + DestinationRule + ExternalName Service |
| Path routing | HTTPRoute on the MaaS gateway |
| API key injection | AuthPolicy `response.success.headers` |

## Architecture

```
Client                   MaaS Gateway                             External Provider
  |                      (openshift-ingress)                      (api.openai.com)
  |                           |                                        |
  | POST /external/openai/    |                                        |
  |   v1/chat/completions     |                                        |
  | Auth: Bearer <maas-token> |                                        |
  |-------------------------->|                                        |
  |                           |                                        |
  |                    1. HTTPRoute matches                            |
  |                       /external/openai/*                           |
  |                                                                    |
  |                    2. AuthPolicy validates                         |
  |                       maas-token via                               |
  |                       TokenReview                                  |
  |                                                                    |
  |                    3. AuthPolicy injects                           |
  |                       Authorization: Bearer <openai-key>           |
  |                                                                    |
  |                    4. RequestHeaderModifier sets                    |
  |                       Host: api.openai.com                         |
  |                                                                    |
  |                    5. ExternalName Service                         |
  |                       resolves to api.openai.com                   |
  |                                                                    |
  |                    6. ServiceEntry allows                          |
  |                       egress to api.openai.com                     |
  |                                                                    |
  |                    7. DestinationRule                               |
  |                       originates TLS                               |
  |                           |                                        |
  |                           | POST /v1/chat/completions              |
  |                           | Auth: Bearer <openai-key>              |
  |                           | Host: api.openai.com                   |
  |                           |--------------------------------------->|
  |                           |                                        |
  |                           |<----------------------- 200 OK --------|
  |<---------- 200 OK -------|                                        |
```

### How It Works

| Aspect | Detail |
|--------|--------|
| External backend | ServiceEntry + DestinationRule + ExternalName Service (native Istio) |
| Hop count | 1 hop (MaaS GW -> provider directly) |
| Controller dependency | None (native Istio resources) |
| TLS origination | DestinationRule on MaaS gateway |
| API key injection | AuthPolicy injects Authorization header directly |

## Prerequisites

### MaaS Deployment

MaaS must be deployed on the cluster. Follow the [MaaS Quickstart](../../maas-quickstart.md)
to deploy MaaS with a sample model and validate the setup.

Verify MaaS is running:
```bash
kubectl get gateway maas-default-gateway -n openshift-ingress
kubectl get pods -n opendatahub | grep maas
kubectl get authpolicy -n openshift-ingress
```

### API Keys

You need API keys for the providers you want to route to:

| Provider | Where to get a key |
|----------|--------------------|
| OpenAI | https://platform.openai.com/api-keys |
| Anthropic | https://console.anthropic.com/settings/keys |

## Quick Start

### 1. Deploy Istio Egress Resources

These register the external hosts in the mesh and configure TLS origination.
No secrets — safe to commit.

```bash
kubectl apply -f manifests/istio-egress-openai.yaml
kubectl apply -f manifests/istio-egress-anthropic.yaml
```

### 2. Set Your API Keys

```bash
export OPENAI_API_KEY="sk-proj-your-key-here"
export ANTHROPIC_API_KEY="sk-ant-your-key-here"
```

### 3. Generate and Deploy Bridge Resources

The bridge templates contain `{{OPENAI_API_KEY}}` and `{{ANTHROPIC_API_KEY}}`
placeholders. Generate the final manifests with your keys:

```bash
sed "s|{{OPENAI_API_KEY}}|$OPENAI_API_KEY|g" \
  manifests/openai-bridge.template > manifests/openai-bridge.yaml

sed "s|{{ANTHROPIC_API_KEY}}|$ANTHROPIC_API_KEY|g" \
  manifests/anthropic-bridge.template > manifests/anthropic-bridge.yaml

kubectl apply -f manifests/openai-bridge.yaml
kubectl apply -f manifests/anthropic-bridge.yaml
```

The generated YAML files contain your API keys in plaintext — do not commit them.
They are listed in `.gitignore`.

### 4. Get MaaS Gateway URL and Token

```bash
# Gateway hostname (needed for Host header)
export MAAS_HOST=$(kubectl get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')

# Gateway address (ELB or IP)
export MAAS_URL=$(kubectl get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.addresses[0].value}')

# MaaS SA token (valid for 1 hour)
export MAAS_TOKEN=$(kubectl create token default \
  --audience=maas-default-gateway-sa --duration=1h)

echo "Host: ${MAAS_HOST}"
echo "URL:  ${MAAS_URL}"
```

### 5. Test OpenAI Through MaaS

```bash
curl -s "http://${MAAS_URL}/external/openai/v1/chat/completions" \
  -H "Host: ${MAAS_HOST}" \
  -H "Authorization: Bearer ${MAAS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "What is 2+2? Reply with just the number."}],
    "max_tokens": 5
  }' | jq .
```

Expected: `{"choices":[{"message":{"content":"4"}}], ...}`

### 6. Test Anthropic Through MaaS

```bash
curl -s "http://${MAAS_URL}/external/anthropic/v1/messages" \
  -H "Host: ${MAAS_HOST}" \
  -H "Authorization: Bearer ${MAAS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "messages": [{"role": "user", "content": "What is 2+2? Reply with just the number."}],
    "max_tokens": 5
  }' | jq .
```

Expected: `{"content":[{"text":"4"}], ...}`

## Resources Created

### Per Provider: Istio Egress Resources (no secrets, safe to commit)

| # | Resource | Purpose |
|---|----------|---------|
| 1 | ExternalName Service | DNS bridge for HTTPRoute backendRef |
| 2 | ServiceEntry | Registers external host in Istio mesh (REGISTRY_ONLY allowlist) |
| 3 | DestinationRule | TLS origination (HTTP inside mesh -> HTTPS to provider) |

### Per Provider: Bridge Resources (contain API keys, use templates)

| # | Resource | Purpose |
|---|----------|---------|
| 4 | HTTPRoute | Routes `/external/<provider>/*` on the MaaS gateway, rewrites path to `/`, sets Host header |
| 5 | AuthPolicy | Validates MaaS token, injects provider API key via `response.success.headers` |
| 6 | TokenRateLimitPolicy | Overrides the gateway-level deny, allows requests for authenticated users |

## Auth Flow

| Step | What Happens |
|------|-------------|
| 1 | Client sends request with MaaS SA token (`Authorization: Bearer <maas-token>`) |
| 2 | AuthPolicy on the HTTPRoute validates the token via `kubernetesTokenReview` |
| 3 | AuthPolicy extracts userid from the SA token |
| 4 | AuthPolicy replaces the Authorization header with the provider API key |
| 5 | HTTPRoute RequestHeaderModifier sets the Host header to the provider FQDN |
| 6 | Request forwards to the ExternalName Service -> ServiceEntry -> DestinationRule -> provider |

The client authenticates with MaaS. The gateway authenticates with the provider.
The client never sees the provider API key.

## Provider Differences

| Aspect | OpenAI | Anthropic |
|--------|--------|-----------|
| Auth header injected | `Authorization: Bearer <key>` | `x-api-key: <key>` |
| Extra headers | None | `anthropic-version: 2023-06-01` |
| Chat endpoint | `/v1/chat/completions` | `/v1/messages` |
| Request path | `/external/openai/v1/chat/completions` | `/external/anthropic/v1/messages` |

## Files

```
manifests/
  istio-egress-openai.yaml        # ServiceEntry + DestinationRule + ExternalName Svc for OpenAI
  istio-egress-anthropic.yaml     # ServiceEntry + DestinationRule + ExternalName Svc for Anthropic
  openai-bridge.template          # HTTPRoute + AuthPolicy + TRLP (template, {{OPENAI_API_KEY}})
  openai-bridge.yaml              # Generated from template (git-ignored)
  anthropic-bridge.template       # HTTPRoute + AuthPolicy + TRLP (template, {{ANTHROPIC_API_KEY}})
  anthropic-bridge.yaml           # Generated from template (git-ignored)
```

## Cleanup

```bash
kubectl delete -f manifests/openai-bridge.yaml --ignore-not-found
kubectl delete -f manifests/anthropic-bridge.yaml --ignore-not-found
kubectl delete -f manifests/istio-egress-openai.yaml --ignore-not-found
kubectl delete -f manifests/istio-egress-anthropic.yaml --ignore-not-found
```

## Validated On

| Component | Version / Detail |
|-----------|-----------------|
| Platform | OpenShift 4.20.6 (ROSA on AWS) |
| Istio | v1.29-latest via Sail Operator 1.29.0 |
| MaaS | Deployed via quickstart with sample model |
| OpenAI | `gpt-4o-mini` responded `"4"` to `"What is 2+2?"` |
| Anthropic | `claude-sonnet-4-20250514` responded `"4"` to `"What is 2+2?"` |
| Auth | MaaS SA token validated, provider key injected by AuthPolicy |
