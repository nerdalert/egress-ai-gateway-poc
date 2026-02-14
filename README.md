# Egress AI Gateway POC: WG AI Gateway with External Model Routing on OpenShift

Proof of concept integrating the Kubernetes SIG WG AI Gateway with Red Hat
OpenShift AI Models-as-a-Service (MaaS) to route inference requests to
external model endpoints alongside on-prem KServe/vLLM models.

**[Quickstart Guide](quickstart.md)** - Single-provider deployment in 4 steps.

**[Mixed Providers Demo](demos/mixed-providers/)** - On-prem + OpenAI + Anthropic behind a single gateway.

## What This Proves

- wg-ai-gateway controller runs on OpenShift alongside MaaS
- `XBackendDestination` (FQDN type) routes traffic to external model endpoints
- MaaS Gateway routes `/external/<provider>/*` to the wg-ai-gateway via per-provider HTTPRoutes
- Per-provider API key injection via Kuadrant AuthPolicy `response.success.headers`
- MaaS SA token auth is enforced on all external provider routes
- MaaS API `/v1/models` returns both local and external models in a unified listing
- TokenRateLimitPolicy enforces per-tier token budgets on external models
- URL rewriting ensures backends receive clean `/v1/*` paths matching real provider APIs
- The external backend is FQDN-based -- simulators can be replaced by any
  resolvable hostname (external host, VM, or real provider once TLS is implemented)

## Architecture

External model requests traverse two gateways. On-prem requests go directly
through the MaaS Gateway to KServe (single gateway).

```
Client (single MaaS SA token)
  |
  v
MaaS Gateway (maas.$CLUSTER_DOMAIN, Istio-based)
  |
  |-- /v1/models              -> MaaS API (unified listing: local + external)
  |-- /maas-api/*              -> MaaS API (tokens, tiers, api-keys)
  |
  |-- /external/openai/*       -> Authorino validates token + injects OpenAI API key
  |     URL rewrite: /external/openai/* -> /openai/*
  |     -> wg-ai-gateway Envoy
  |          URL rewrite: /openai/* -> /*
  |          -> openai-simulator (or api.openai.com once TLS supported)
  |
  |-- /external/anthropic/*   -> Authorino validates token + injects Anthropic API key
  |     URL rewrite: /external/anthropic/* -> /anthropic/*
  |     -> wg-ai-gateway Envoy
  |          URL rewrite: /anthropic/* -> /*
  |          -> anthropic-simulator (or api.anthropic.com once TLS supported)
  |
  |-- /llm/<model>/*          -> KServe LLMInferenceService (on-prem, single gateway)
```

## Quick Start

See [quickstart.md](quickstart.md) for step-by-step deployment and validation.

**Prerequisites:**
- OpenShift cluster with MaaS deployed (`deploy-rhoai-stable.sh`)
- `kubectl`/`oc` with cluster-admin access
- wg-ai-gateway repo cloned (for CRDs)

## What Works

| Capability | Status |
|-----------|--------|
| wg-ai-gateway controller on OpenShift | Working |
| FQDN backend routing to external model simulators | Working |
| Per-provider API key injection | Working (Authorino `response.success.headers`) |
| Multi-provider routing (OpenAI + Anthropic + on-prem) | Working |
| MaaS SA token auth on external routes | Working |
| Unified model listing (local + external) | Working |
| TokenRateLimitPolicy on external models | Working (free: 100 tokens/min) |
| URL rewriting (clean `/v1/*` paths to backends) | Working |

## What's Next

| Item | Status |
|------|--------|
| TLS origination | Needs upstream wg-ai-gateway translator work |
| Dynamic key lookup from Postgres | Needs MaaS API `/v1/provider-keys` endpoint |
| Body-based routing | Route by model name in JSON body |
| Real provider endpoints | Requires TLS origination |

## Directory Structure

```
egress-ai-gateway-poc/
  README.md                   This file
  quickstart.md               Single-provider deployment (4 steps)
  architecture.md             E2E traffic flows + component diagrams
  simulator/                  Key-validating provider-sim (Go source + Dockerfile)
  manifests/
    common/
      gateway.yaml            POC Gateway (port 80, GatewayClass wg-ai-gateway)
    openshift/
      controller.yaml         wg-ai-gateway controller (SCC-adapted)
      simulator.yaml          Inference simulator (llm-d-inference-sim, no key validation)
      external-model.yaml     XBackendDestination + HTTPRoutes for simulator
      maas-bridge.yaml        HTTPRoute + AuthPolicy (MaaS Gateway -> wg-ai-gateway)
      external-model-registry.yaml  ConfigMap listing external models for MaaS API
      httpbin-echo.yaml       httpbin.org backend for header echo testing
      key-validating-simulator.yaml  provider-sim with API key validation
      key-validating-backend.yaml    XBackendDestination + HTTPRoute for key-validating-sim
  demos/
    mixed-providers/          Multi-provider demo (OpenAI + Anthropic + local)
      README.md               Demo deployment + validation (5 steps)
      manifests/              Per-provider simulators, backends, routes, auth policies
  patches/
    README.md                 Patch description
    maas-api-external-models.patch  MaaS API patch for ConfigMap-based model discovery
```
