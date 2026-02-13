# Egress AI Gateway POC: WG AI Gateway with External Model Routing on OpenShift

Proof of concept integrating the Kubernetes SIG WG AI Gateway with Red Hat
OpenShift AI Models-as-a-Service (MaaS) to route inference requests to
external model endpoints alongside on-prem KServe/vLLM models.

**[Quickstart Guide](quickstart.md)** - Deploy and validate in 4 steps.

## What This Proves

- wg-ai-gateway controller runs on OpenShift alongside MaaS
- `XBackendDestination` (FQDN type) routes traffic to external model endpoints
- MaaS gateway bridges to wg-ai-gateway via HTTPRoute (`/external/*`)
- MaaS SA token auth is enforced on the bridge path
- MaaS API `/v1/models` returns both local and external models in a unified listing
- The external backend is FQDN-based -- the simulator could be replaced by any
  resolvable hostname (external host, VM, or real provider once TLS is implemented)

## Architecture

```
Client
  |
  v
MaaS Gateway (maas.$CLUSTER_DOMAIN, Istio-based)
  |-- /v1/models         -> MaaS API (unified local + external listing)
  |-- /maas-api/*         -> MaaS API (tokens, tiers, api-keys)
  |-- /external/*         -> HTTPRoute bridge (URL rewrite strips /external/)
  |     |                    AuthPolicy: validates MaaS SA token
  |     v
  |   envoy-poc-gateway Service (ClusterIP)
  |     |
  |     v
  |   wg-ai-gateway Envoy proxy (xDS-configured)
  |     |-- /v1/models            -> XBackendDestination (FQDN)
  |     |-- /v1/chat/completions  -> XBackendDestination (FQDN)
  |     v
  |   External model simulator (or any OpenAI-compatible endpoint)
  |
  |-- /<ns>/<model>/*     -> KServe LLMInferenceService (on-prem models)
```

## Quick Start

See [quickstart.md](quickstart.md) for step-by-step deployment and validation.

**Prerequisites:**
- OpenShift cluster with MaaS deployed (`deploy-rhoai-stable.sh`)
- `kubectl`/`oc` with cluster-admin access
- wg-ai-gateway repo cloned (for CRDs)

## Directory Structure

```
egress-ai-gateway-poc/
  README.md                 This file
  quickstart.md             Step-by-step deployment + validation (7 steps)
  status.md                 Current integration status + next steps
  manifests/
    common/                 Shared manifests (any cluster)
      gateway.yaml          POC Gateway (port 80, GatewayClass wg-ai-gateway)
    openshift/              OpenShift-specific manifests
      controller.yaml       wg-ai-gateway controller (SCC-adapted)
      simulator.yaml        Inference simulator Deployment+Service
      external-model.yaml   XBackendDestination + HTTPRoutes for simulator
      maas-bridge.yaml      HTTPRoute bridge + AuthPolicy (MaaS -> wg-ai-gateway)
      external-model-registry.yaml  ConfigMap listing external models for MaaS API
  scripts/                  Kind deployment scripts (local dev)
    start-simulator.sh      Start Docker simulator container
    setup.sh                Kind cluster setup
    test.sh                 Kind E2E tests
    teardown.sh             Kind teardown
```

## What Works

| Capability | Status |
|-----------|--------|
| wg-ai-gateway controller on OpenShift | Working |
| FQDN backend routing to external model simulator | Working |
| `/v1/models`, `/v1/chat/completions` | Working |
| MaaS gateway -> wg-ai-gateway bridge | Working |
| MaaS SA token auth on bridge | Working |
| Unified model listing (local + external) | Working |
| TokenRateLimitPolicy on external models | Working (free: 100 tokens/min -> 429 after ~6 requests) |

## What's Next

| Item | Status |
|------|--------|
| TLS origination | Needs upstream wg-ai-gateway translator work |
| Provider API key injection | Design documented, not implemented |
| Body-based routing | Route by model name in JSON body |
| Real provider endpoints | Requires TLS origination |
