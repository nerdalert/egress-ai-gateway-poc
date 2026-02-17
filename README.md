# Egress AI Gateway POC: WG AI Gateway with External Model Routing on OpenShift

Proof of concept integrating the Kubernetes SIG WG AI Gateway with
OpenShift AI Models-as-a-Service (MaaS) to route inference requests to
external model endpoints alongside on-prem KServe/vLLM models.

**[Demo: On-Prem + Simulated Providers + External vLLM](demos/mixed-providers/)** -
Four providers behind a single gateway with per-provider API key injection,
unified model listing, and token rate limiting.

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
  |-- /external/vllm/*       -> Authorino validates token + overrides Authorization header
  |     URL rewrite: /external/vllm/* -> /vllm/*
  |     -> wg-ai-gateway Envoy
  |          URL rewrite: /vllm/* -> /*
  |          -> remote vLLM instance (HTTP, real GPU inference)
  |
  |-- /llm/<model>/*          -> KServe LLMInferenceService (on-prem, single gateway)
```

## Prerequisites

- OpenShift cluster with MaaS deployed (`deploy-rhoai-stable.sh`)
- `kubectl`/`oc` with cluster-admin access
- [wg-ai-gateway](https://github.com/kubernetes-sigs/wg-ai-gateway) repo cloned (for CRDs)

**Forked images** (used until upstream PRs merge):
- Controller: `ghcr.io/nerdalert/wg-ai-gateway:prefix-rewrite-fix` — includes
  [prefix rewrite fix](https://github.com/kubernetes-sigs/wg-ai-gateway/pull/38)
- MaaS API: `ghcr.io/nerdalert/maas-api:external-models` — adds
  ConfigMap-based external model discovery

## What Works

| Capability | Status |
|-----------|--------|
| wg-ai-gateway controller on OpenShift | Working |
| FQDN backend routing to external model simulators | Working |
| Per-provider API key injection | Working (Authorino `response.success.headers`) |
| Multi-provider routing (OpenAI + Anthropic + vLLM + on-prem) | Working |
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
