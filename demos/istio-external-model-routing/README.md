# External Model Routing with Istio ServiceEntry & DestinationRule

## Overview

This PoC validates routing requests to external AI model endpoints (e.g., OpenAI,
Anthropic, self-hosted vLLM) using native Istio networking primitives combined with
the Kubernetes Gateway API. The goal is to understand the exact Kubernetes and Istio
resources required so that MaaS can auto-generate them when a user creates an
ExternalModel CR.

### What This PoC Proves

| Question | Answer |
|----------|--------|
| Can we route mesh traffic to an external HTTPS endpoint? | Yes, via ServiceEntry + DestinationRule |
| Can the gateway inject API keys without the client providing them? | Yes, via HTTPRoute `RequestHeaderModifier` |
| What resources does the MaaS controller need to create per provider? | 4 resources (see [The 4-Resource Pattern](#the-4-resource-pattern)) |
| Does this work with standard Istio (no custom changes)? | Yes, all APIs are GA/stable |
| Does this require any custom controllers or CRDs? | No, only native Kubernetes + Istio resources |

### Scope

| In Scope | Out of Scope |
|----------|-------------|
| Istio 1.29.0 on Kubernetes and OpenShift | LLM-D, vSR, InferencePool |
| ServiceEntry, DestinationRule, ExternalName Service | Kuadrant AuthPolicy / RateLimitPolicy |
| HTTPRoute (Gateway API v1) | Kuadrant AuthPolicy / RateLimitPolicy |
| Manual API key injection via RequestHeaderModifier | Automatic key injection via Authorino |
| TLS origination to external HTTPS endpoints | mTLS, egress gateway topology |

> **Istio Version:** This PoC uses Istio **1.29.0** because the Sail Operator
> does not yet have 1.29.1 available. Update `ISTIO_VERSION` in
> `scripts/install-istio.sh` and `manifests/openshift/istio-cr.yaml` when
> 1.29.1 becomes available. Product-side testing will use the Istio version
> included in OpenShift (minimum 1.26 with GIE backport).

> **No Custom Istio Changes:** This work uses only existing Istio releases. Custom
> changes would trigger downstream dependencies on Service Mesh team + OpenShift.

---

## Architecture

```
                                        ┌──────────────────────────┐
                                        │  External AI Provider    │
                                        │  (api.openai.com :443)   │
                                        └────────────▲─────────────┘
                                                     │
                                                     │ HTTPS (TLS originated
                                                     │ by DestinationRule)
                                                     │
┌──────────┐         ┌───────────────────────────────┴───────────────┐
│          │  HTTP   │  Istio Gateway (Envoy)                        │
│  Client  │────────▶│                                               │
│  (curl)  │         │  1. HTTPRoute matches path                    │
│          │         │  2. RequestHeaderModifier injects Host + Auth  │
│          │         │  3. backendRef -> ExternalName Service         │
└──────────┘         │  4. ServiceEntry registers external host      │
                     │  5. DestinationRule originates TLS             │
                     └───────────────────────────────────────────────┘
```

### Traffic Flow

| Step | Component | What Happens |
|------|-----------|-------------|
| 1 | **Client** | Sends `POST /v1/chat/completions` to the Istio gateway (plain HTTP) |
| 2 | **HTTPRoute** | Matches the path, applies `RequestHeaderModifier` to set `Host: api.openai.com` and `Authorization: Bearer sk-...` |
| 3 | **ExternalName Service** | Maps the in-cluster service name (`openai-external`) to the real FQDN (`api.openai.com`) |
| 4 | **ServiceEntry** | Tells Istio that `api.openai.com` is a valid destination (required when `outboundTrafficPolicy.mode=REGISTRY_ONLY`) |
| 5 | **DestinationRule** | Originates TLS (`mode: SIMPLE`) so the outbound connection is HTTPS |
| 6 | **External Provider** | Receives a standard HTTPS request with valid Host and Authorization headers |

---

## The 4-Resource Pattern

Every external AI provider requires exactly **4 Kubernetes/Istio resources**. This is
the pattern the MaaS controller should generate when an ExternalModel CR is created.

| # | Resource | API | Purpose | Key Fields |
|---|----------|-----|---------|------------|
| 1 | **ExternalName Service** | `v1/Service` | DNS bridge so HTTPRoute `backendRef` can reference a standard k8s Service | `type: ExternalName`, `externalName: <fqdn>`, `ports[].port: 443` |
| 2 | **ServiceEntry** | `networking.istio.io/v1` | Registers the external FQDN in Istio's service registry | `hosts: [<fqdn>]`, `location: MESH_EXTERNAL`, `protocol: HTTPS`, `resolution: DNS` |
| 3 | **DestinationRule** | `networking.istio.io/v1` | Configures TLS origination for the outbound connection | `host: <fqdn>`, `trafficPolicy.tls.mode: SIMPLE` |
| 4 | **HTTPRoute** | `gateway.networking.k8s.io/v1` | Routes requests and injects headers (Host, Authorization) | `backendRef -> ExternalName Svc`, `RequestHeaderModifier` filter |

### How They Connect

```
HTTPRoute                 ExternalName Service       ServiceEntry           DestinationRule
(routing + headers)       (DNS bridge)               (mesh registration)    (TLS origination)
─────────────────         ────────────────────       ─────────────────      ─────────────────
backendRef:               type: ExternalName         hosts:                 host: api.openai.com
  name: openai-external     externalName:              - api.openai.com    trafficPolicy:
  port: 443                   api.openai.com          protocol: HTTPS        tls:
filters:                  ports:                      resolution: DNS          mode: SIMPLE
  RequestHeaderModifier     - port: 443               location:
    Host: api.openai.com                                MESH_EXTERNAL
    Authorization: Bearer sk-...
```

### Per-Provider Examples

| Provider | ExternalName | ServiceEntry Host | DestinationRule TLS | HTTPRoute Auth Header |
|----------|-------------|-------------------|--------------------|-----------------------|
| OpenAI | `api.openai.com` | `api.openai.com` | `SIMPLE` (HTTPS) | `Authorization: Bearer <key>` |
| Anthropic | `api.anthropic.com` | `api.anthropic.com` | `SIMPLE` (HTTPS) | `x-api-key: <key>` + `anthropic-version: 2023-06-01` |
| Self-hosted vLLM | `vllm.internal:8000` | `vllm.internal` | `DISABLE` (HTTP) | None (or custom) |
| AWS Bedrock | `bedrock-runtime.us-east-1.amazonaws.com` | same | `SIMPLE` (HTTPS) | AWS SigV4 (requires separate handling) |


---

## Quick Start

For OpenShift, run ClusterBot and start a cluster with `rosa create 4.20.6` (or whatever version you want). There isnt a sail 1.29.1 version for OpenShift yet but 1.29.0 appeared to work fine. I havent debugged the deployment on vanilla kube yet but should generally for vanilla as well with a kind deploy.

### Phase 0: Install Istio 1.29.0

```bash
# Download and install
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.29.0 sh -
export PATH=$PWD/istio-1.29.0/bin:$PATH

# Verify
istioctl version --remote=false
# Expected: 1.29.0

# Install Istio with REGISTRY_ONLY mode
istioctl install --set profile=minimal \
  --set values.pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true \
  --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY \
  -y

# Install Gateway API CRDs if not present
kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null || \
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# Verify
kubectl get pods -n istio-system
```

| Istio Setting | Value | Why |
|---------------|-------|-----|
| `profile` | `minimal` | Sufficient for gateway + control plane |
| `PILOT_ENABLE_ALPHA_GATEWAY_API` | `true` | Required for some Gateway API features |
| `outboundTrafficPolicy.mode` | `REGISTRY_ONLY` | Only ServiceEntry-registered hosts are reachable (validates our config) |

### Phase 1: Deploy Base Resources

```bash
kubectl apply -f manifests/base/gateway.yaml
kubectl wait --for=condition=programmed gateway/external-model-gateway \
  -n external-model-demo --timeout=120s
```

### Phase 2: Iteration 1 (httpbin.org — No Auth)

```bash
kubectl apply -f manifests/iteration-1-no-auth/

# Get gateway address
export GATEWAY_IP=$(kubectl get gateway external-model-gateway \
  -n external-model-demo -o jsonpath='{.status.addresses[0].value}')
export GATEWAY_PORT=80

# Test
curl -s "http://${GATEWAY_IP}:${GATEWAY_PORT}/get" \
  -H "Host: ai-gateway.example.com" | jq .
```

### Phase 3: Iteration 2 (api.openai.com — With API Key)

You need an OpenAI API key. Get one at https://platform.openai.com/api-keys.

```bash
# 1. Set your OpenAI API key
export OPENAI_API_KEY="sk-proj-your-key-here"

# 2. Verify the key works (direct test, bypasses the mesh)
curl -s https://api.openai.com/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY" | jq '.data[:2]'
# Expected: JSON list of models (not a 401 or 429 error)

# 3. Generate the HTTPRoute manifest from the template
#    This injects your key into the RequestHeaderModifier
sed "s|{{OPENAI_API_KEY}}|$OPENAI_API_KEY|g" \
  manifests/iteration-2-with-apikey/httproute-openai.template \
  > manifests/iteration-2-with-apikey/httproute-openai.yaml

# 4. Deploy (use the script — it skips .template files automatically)
./scripts/deploy.sh iteration-2

# 5. Test — no Authorization header needed (injected by gateway)
curl -s "http://${GATEWAY_IP}:${GATEWAY_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Say hello in one word."}],
    "max_tokens": 5
  }' | jq .
# Expected: {"choices":[{"message":{"content":"Hello!"}}], ...}
```

| Step | What It Does |
|------|-------------|
| `export OPENAI_API_KEY` | Set your key in the environment |
| `curl ... api.openai.com` | Verify the key works before involving the mesh |
| `sed ... template > yaml` | Inject the key into the HTTPRoute `RequestHeaderModifier` |
| `deploy.sh iteration-2` | Apply ExternalName Service, ServiceEntry, DestinationRule, HTTPRoute |
| `curl ... GATEWAY_IP` | Send a request through the mesh (gateway injects the key) |

---

## Iteration 1: External Endpoint Without API Key

**Goal:** Validate the ServiceEntry + DestinationRule + HTTPRoute pipeline by
routing to an external endpoint that requires no authentication.

**Target:** `httpbin.org` — a public HTTP testing service that echoes request
details back, allowing us to verify headers, routing, and TLS origination.

### Resources Deployed

| Resource | Name | File | Key Configuration |
|----------|------|------|-------------------|
| ExternalName Service | `httpbin-external` | `svc-httpbin.yaml` | `externalName: httpbin.org`, port 443 |
| ServiceEntry | `httpbin-external` | `serviceentry-httpbin.yaml` | `hosts: [httpbin.org]`, `protocol: HTTPS`, `resolution: DNS` |
| DestinationRule | `httpbin-tls` | `destinationrule-httpbin.yaml` | `host: httpbin.org`, `tls.mode: SIMPLE` |
| HTTPRoute | `httpbin-route` | `httproute-httpbin.yaml` | Matches `/get`, `/post`, `/headers`, `/status`; sets `Host: httpbin.org` |

### What Each Resource Does

| Resource | Without It | With It |
|----------|-----------|---------|
| ExternalName Service | HTTPRoute has no valid backendRef target | HTTPRoute can reference `httpbin-external` as a standard k8s Service |
| ServiceEntry | Istio blocks traffic (`REGISTRY_ONLY`), returns 503 | `httpbin.org` is registered in the mesh, traffic is allowed |
| DestinationRule | Connection to httpbin.org:443 fails (no TLS handshake) | Outbound connection is upgraded to TLS with `mode: SIMPLE` |
| HTTPRoute | No routing rules, gateway returns 404 | Requests matching `/get` etc. are forwarded to httpbin.org |

### Validation

```bash
# Verify resources exist
kubectl get serviceentry,destinationrule,httproute,svc -n external-model-demo

# Test GET (echoes request details)
curl -s "http://${GATEWAY_IP}:${GATEWAY_PORT}/get" \
  -H "Host: ai-gateway.example.com" | jq .

# Test POST (echoes posted body)
curl -s "http://${GATEWAY_IP}:${GATEWAY_PORT}/post" \
  -H "Host: ai-gateway.example.com" \
  -H "Content-Type: application/json" \
  -d '{"test": "hello from istio mesh"}' | jq .

# Test headers (shows all headers received by httpbin)
curl -s "http://${GATEWAY_IP}:${GATEWAY_PORT}/headers" \
  -H "Host: ai-gateway.example.com" | jq .

# Verify in proxy config
istioctl proxy-config clusters \
  deployment/external-model-gateway-istio -n external-model-demo | grep httpbin
# Expected: outbound|443||httpbin.org
```

### Expected Results


| Test | Expected Response |
|------|-------------------|
| `GET /get` | JSON with request details from httpbin.org |
| `POST /post` | Echoed body: `{"test": "hello from istio mesh"}` |
| `GET /headers` | All headers including `Host: httpbin.org` |
| Proxy clusters | `outbound\|443\|\|httpbin.org` cluster visible |
| Proxy logs | Successful outbound connections to `httpbin.org:443` |

---

## Iteration 2: External Model With API Key

**Goal:** Route to a real AI model endpoint that requires authentication, with the
API key injected at the gateway level (client does not provide it).

**Target:** `api.openai.com` — requires a valid OpenAI API key.

### Resources Deployed

| Resource | Name | File | Key Configuration |
|----------|------|------|-------------------|
| ExternalName Service | `openai-external` | `svc-openai.yaml` | `externalName: api.openai.com`, port 443 |
| ServiceEntry | `openai-api` | `serviceentry-openai.yaml` | `hosts: [api.openai.com]`, `protocol: HTTPS`, `resolution: DNS` |
| DestinationRule | `openai-tls` | `destinationrule-openai.yaml` | `host: api.openai.com`, `tls.mode: SIMPLE` |
| HTTPRoute | `openai-route` | `httproute-openai.yaml` | Matches `/v1/*`; injects `Host` + `Authorization` headers |

### API Key Injection via RequestHeaderModifier

The HTTPRoute uses a `RequestHeaderModifier` filter to inject the API key at the
gateway level. The client never sees or provides the key.

| Header | Value | Purpose |
|--------|-------|---------|
| `Host` | `api.openai.com` | Required so the external endpoint receives the correct virtual host |
| `Authorization` | `Bearer <OPENAI_API_KEY>` | Authenticates with the OpenAI API |

```
Client                      Istio Gateway               api.openai.com
  │                              │                            │
  │  POST /v1/chat/completions   │                            │
  │  (no Authorization header)   │                            │
  │ ────────────────────────────▶│                            │
  │                              │                            │
  │                       RequestHeaderModifier:               │
  │                         Host: api.openai.com              │
  │                         Authorization: Bearer sk-...      │
  │                              │                            │
  │                              │  POST /v1/chat/completions │
  │                              │  Authorization: Bearer sk-...
  │                              │  Host: api.openai.com      │
  │                              │ ──────────────────────────▶│
  │                              │                            │
  │                              │◀─────────── 200 OK ────────│
  │◀─────────── 200 OK ─────────│                            │
```

### HTTPRoute Template Workflow

The API key is stored outside the manifest using a template file:

| File | Purpose |
|------|---------|
| `httproute-openai.template` | Template with `{{OPENAI_API_KEY}}` placeholder |
| `httproute-openai.yaml` | Generated manifest (should be git-ignored) |

```bash
# Generate the manifest from template (uses | delimiter to handle / in keys)
sed "s|{{OPENAI_API_KEY}}|$OPENAI_API_KEY|g" \
  manifests/iteration-2-with-apikey/httproute-openai.template \
  > manifests/iteration-2-with-apikey/httproute-openai.yaml
```

> **Production path:** In MaaS, AuthPolicy + Authorino will replace the
> `RequestHeaderModifier` approach. Authorino reads the API key from a Kubernetes
> Secret and injects it via response headers. The underlying ServiceEntry +
> DestinationRule + ExternalName Service pattern remains unchanged.

### Validation

Example results in this gist [egress-workstream-validation-output.md](https://gist.github.com/nerdalert/896716f4776fd5d49b6a8455c67ea20e) from a shift cluster.

**Prerequisites:** You need an OpenAI API key. For other models you need to swap the auth header etc.


```bash
# 1. Set your API key and generate the HTTPRoute
export OPENAI_API_KEY="sk-proj-your-key-here"

# 2. (Optional) Verify the key works directly first
curl -s https://api.openai.com/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY" | jq '.data[:2]'

# 3. Generate HTTPRoute from template and deploy
sed "s|{{OPENAI_API_KEY}}|$OPENAI_API_KEY|g" \
  manifests/iteration-2-with-apikey/httproute-openai.template \
  > manifests/iteration-2-with-apikey/httproute-openai.yaml
./scripts/deploy.sh iteration-2

# 4. Send a chat completion request through the Istio gateway
#    This is the primary validation — the request must be handled
#    properly by the external model and return a valid response.
#    Note: NO Authorization header is provided by the client.
#    The gateway injects it via RequestHeaderModifier.
curl -s "http://${GATEWAY_IP}:${GATEWAY_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Say hello in one word."}],
    "max_tokens": 5,
    "temperature": 0
  }' | jq .

# 5. (Optional) Additional validation
curl -s "http://${GATEWAY_IP}:${GATEWAY_PORT}/v1/models" | jq '.data[:3]'

# 6. Verify proxy config
istioctl proxy-config clusters \
  deployment/external-model-gateway-istio -n external-model-demo | grep openai
```


## Istio Resource Reference

### ServiceEntry

| Field | Value | Explanation |
|-------|-------|-------------|
| `apiVersion` | `networking.istio.io/v1` | Stable Istio networking API |
| `spec.hosts` | `["api.openai.com"]` | The external FQDN(s) to register |
| `spec.location` | `MESH_EXTERNAL` | Indicates the service is outside the mesh |
| `spec.ports[].protocol` | `HTTPS` | The protocol the external service speaks |
| `spec.resolution` | `DNS` | Resolve via DNS lookup (vs `STATIC` for fixed IPs) |

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: openai-api
spec:
  hosts:
    - api.openai.com
  ports:
    - number: 443
      name: https
      protocol: HTTPS
  resolution: DNS
  location: MESH_EXTERNAL
```

### DestinationRule

| Field | Value | Explanation |
|-------|-------|-------------|
| `spec.host` | `api.openai.com` | Must match a ServiceEntry host exactly |
| `spec.trafficPolicy.tls.mode` | `SIMPLE` | Standard TLS origination (HTTP -> HTTPS) |

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: openai-tls
spec:
  host: api.openai.com
  trafficPolicy:
    tls:
      mode: SIMPLE
```

**All TLS Modes:**

| Mode | Description | Use Case |
|------|-------------|----------|
| `DISABLE` | No TLS | Plain HTTP backends (self-hosted vLLM) |
| `SIMPLE` | Standard TLS | External HTTPS endpoints (OpenAI, Anthropic) |
| `MUTUAL` | mTLS with client certificate | Endpoints requiring client cert auth |
| `ISTIO_MUTUAL` | Istio-managed mTLS | Mesh-internal communication only |

### ExternalName Service

| Field | Value | Explanation |
|-------|-------|-------------|
| `spec.type` | `ExternalName` | k8s Service that acts as a DNS alias |
| `spec.externalName` | `api.openai.com` | The real FQDN to resolve to |
| `spec.ports[].port` | `443` | The port exposed by the Service |

```yaml
apiVersion: v1
kind: Service
metadata:
  name: openai-external
spec:
  type: ExternalName
  externalName: api.openai.com
  ports:
    - port: 443
      targetPort: 443
```

### HTTPRoute

| Field | Value | Explanation |
|-------|-------|-------------|
| `spec.parentRefs` | `external-model-gateway` | Attaches to the Istio Gateway |
| `spec.rules[].matches` | `PathPrefix: /v1/` | Matches all `/v1/*` API paths |
| `spec.rules[].backendRefs` | `name: openai-external, port: 443` | Routes to the ExternalName Service |
| `spec.rules[].filters` | `RequestHeaderModifier` | Injects Host and Authorization headers |
| `spec.rules[].timeouts.request` | `300s` | Prevents timeout on long inference requests |

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openai-route
spec:
  parentRefs:
    - name: external-model-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/
      backendRefs:
        - name: openai-external
          port: 443
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: Host
                value: "api.openai.com"
              - name: Authorization
                value: "Bearer {{OPENAI_API_KEY}}"
      timeouts:
        request: 300s
```

---

## Extending to Multiple Providers

The 4-resource pattern works for any provider. The only differences are the FQDN,
port, TLS mode, and auth header format.

### Provider Comparison

| Provider | FQDN | Port | TLS | Auth Header | Extra Headers |
|----------|------|------|-----|-------------|---------------|
| OpenAI | `api.openai.com` | 443 | `SIMPLE` | `Authorization: Bearer <key>` | None |
| Anthropic | `api.anthropic.com` | 443 | `SIMPLE` | `x-api-key: <key>` | `anthropic-version` |
| Self-hosted vLLM | `vllm.example.com` | 8000 | None | None | None |

### Anthropic

Anthropic uses `x-api-key` instead of `Authorization: Bearer` and requires an
`anthropic-version` header.

```yaml
# svc-anthropic.yaml
apiVersion: v1
kind: Service
metadata:
  name: anthropic-external
  namespace: external-model-demo
spec:
  type: ExternalName
  externalName: api.anthropic.com
  ports:
    - port: 443
      targetPort: 443
---
# serviceentry-anthropic.yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: anthropic-api
  namespace: external-model-demo
spec:
  hosts:
    - api.anthropic.com
  ports:
    - number: 443
      name: https
      protocol: HTTPS
  resolution: DNS
  location: MESH_EXTERNAL
---
# destinationrule-anthropic.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: anthropic-tls
  namespace: external-model-demo
spec:
  host: api.anthropic.com
  trafficPolicy:
    tls:
      mode: SIMPLE
---
# httproute-anthropic.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: anthropic-route
  namespace: external-model-demo
spec:
  parentRefs:
    - name: external-model-gateway
      namespace: external-model-demo
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/messages
      backendRefs:
        - name: anthropic-external
          port: 443
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: Host
                value: "api.anthropic.com"
              - name: x-api-key
                value: "YOUR_ANTHROPIC_API_KEY"
              - name: anthropic-version
                value: "2023-06-01"
      timeouts:
        request: 300s
```

### Self-Hosted vLLM (External to the Cluster)

For a vLLM instance running on a separate machine (e.g., a GPU node at
`vllm.example.com:8000`), no TLS and no auth headers are needed. Skip the
DestinationRule entirely.

```yaml
# svc-vllm.yaml
apiVersion: v1
kind: Service
metadata:
  name: vllm-external
  namespace: external-model-demo
spec:
  type: ExternalName
  externalName: vllm.example.com
  ports:
    - port: 8000
      targetPort: 8000
---
# serviceentry-vllm.yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: vllm-api
  namespace: external-model-demo
spec:
  hosts:
    - vllm.example.com
  ports:
    - number: 8000
      name: http
      protocol: HTTP
  resolution: DNS
  location: MESH_EXTERNAL
---
# httproute-vllm.yaml — no DestinationRule needed (plain HTTP)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vllm-route
  namespace: external-model-demo
spec:
  parentRefs:
    - name: external-model-gateway
      namespace: external-model-demo
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/
      backendRefs:
        - name: vllm-external
          port: 8000
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: Host
                value: "vllm.example.com"
      timeouts:
        request: 300s
```

---

## MaaS Integration Path

When integrated with MaaS, creating an ExternalModel CR should auto-generate the
4-resource pattern:

| ExternalModel CR Field | Generated Resource | Generated Field |
|------------------------|--------------------|-----------------|
| `spec.provider.url` | ExternalName Service | `externalName` |
| `spec.provider.url` | ServiceEntry | `hosts` |
| `spec.provider.tls` (true/false) | DestinationRule | `tls.mode: SIMPLE` or `DISABLE` |
| `spec.provider.apiKeySecret` | AuthPolicy (replaces RequestHeaderModifier) | `response.success.headers` |
| `spec.models[].path` | HTTPRoute | `matches[].path` |

```
ExternalModel CR (user creates)
        │
        ▼
MaaS Controller (reconciles)
        │
        ├── creates ExternalName Service
        ├── creates ServiceEntry
        ├── creates DestinationRule
        ├── creates/updates HTTPRoute rules
        └── creates AuthPolicy (reads key from Secret, injects via Authorino)
```

---

## Cleanup

```bash
# Use the deploy script (handles .template files correctly)
./scripts/deploy.sh clean

# Or manually:
# kubectl delete -f manifests/iteration-1-no-auth/ --ignore-not-found
# kubectl delete -f manifests/iteration-2-with-apikey/httproute-openai.yaml --ignore-not-found
# kubectl delete -f manifests/iteration-2-with-apikey/svc-openai.yaml --ignore-not-found
# kubectl delete -f manifests/iteration-2-with-apikey/serviceentry-openai.yaml --ignore-not-found
# kubectl delete -f manifests/iteration-2-with-apikey/destinationrule-openai.yaml --ignore-not-found
# kubectl delete -f manifests/base/ --ignore-not-found
# kubectl delete namespace external-model-demo

# (Optional) Uninstall Istio
# Kubernetes:  istioctl uninstall --purge -y && kubectl delete ns istio-system
# OpenShift:   kubectl delete istio default -n istio-system && \
#              kubectl delete subscription sailoperator -n openshift-operators && \
#              kubectl delete ns istio-system
```

---

## Validated On

This PoC was deployed and validated end-to-end on the following environment:

| Component | Version / Detail |
|-----------|-----------------|
| Platform | OpenShift 4.20.6 (ROSA on AWS, us-east-1) |
| Istio | v1.29-latest via Sail Operator 1.29.0 |
| Gateway API CRDs | v1.2.1 (pre-installed by OpenShift) |
| Outbound policy | `REGISTRY_ONLY` (ServiceEntry required for egress) |
| Iteration 1 target | `httpbin.org` (GET, POST, headers, status — all passed) |
| Iteration 2 target | `api.openai.com` `/v1/chat/completions` |
| Iteration 2 model | `gpt-4o-mini` — responded `"Hello!"` (15 tokens) |
| API key injection | `RequestHeaderModifier` in HTTPRoute — client sent no auth header |

---
