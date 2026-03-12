# Egress AI Gateway POC

Integrates MaaS (Models-as-a-Service) with the [wg-ai-gateway](https://github.com/kubernetes-sigs/wg-ai-gateway) project to route inference requests to multiple external AI providers behind a single MaaS gateway, with Kuadrant policy enforcement (auth, per-model rate limiting, token budgets).

## Demos

| Demo | Endpoint Pattern | Description |
|------|-----------------|-------------|
| [mixed-providers](demos/mixed-providers/) | `/external/<provider>/v1/chat/completions` | Per-provider URL paths. Each provider has its own HTTPRoute and AuthPolicy. Authorino injects API keys via `response.success.headers`. |
| [mixed-providers-unified-path](demos/mixed-providers-unified-path/) | `/v1/chat/completions` | Single endpoint for all external providers. Model field in request body determines provider. Envoy Lua filter handles key injection and routing header. |
| [istio-external-model-routing](demos/istio-external-model-routing/) | `/v1/chat/completions` | Routes to external AI models using native Istio resources (ServiceEntry, DestinationRule) and Gateway API HTTPRoute with API key injection via RequestHeaderModifier — no custom controllers or CRDs required. |
| [maas-istio-only-external](demos/maas-istio-only-external/) | `/external/<provider>/*` | Integrates external model routing with a live MaaS deployment. Uses native Istio resources (no wg-ai-gateway) with MaaS auth (Kuadrant AuthPolicy) for API key injection. Single hop from MaaS gateway to provider. |

The unified-path demo exists because pure Kuadrant AuthPolicy cannot perform body-based key injection due to the wasm-shim timing constraint described below.

## Components

- **MaaS Gateway:** `openshift-ingress/maas-default-gateway` (Istio)
- **Kuadrant:** Authorino (auth) + Limitador (rate limiting) in `kuadrant-system`
- **wg-ai-gateway:** Controller in `ai-gateway-system`, Envoy proxy `envoy-poc-gateway` in `default`
- **Provider backends:** `XBackendDestination` CRDs pointing to simulators and remote vLLM

## Kuadrant Wasm-Shim Body Access Limitation

A single `/v1/chat/completions` endpoint requires reading the `model` field from the request body to determine which provider API key to inject. Kuadrant's wasm-shim cannot do this for auth decisions because of how Envoy processes HTTP requests in phases:

1. **Client sends the request.** Headers arrive first, body arrives separately after.

2. **`on_http_request_headers()` fires.** Envoy calls the wasm-shim as soon as headers arrive. The wasm-shim sees an AuthPolicy on this route and immediately makes a gRPC call to Authorino, sending method, path, and headers. The body has not arrived from the client yet, so it is not included.

3. **Authorino validates the token but cannot see the body.** It receives the gRPC call, validates the bearer token from the `Authorization` header, and returns "authorized." The field `input.request.body` is an empty string. Any OPA policy attempting `json.unmarshal("")` on the body fails. Authorino cannot determine the model and cannot inject a model-specific API key.

4. **`on_http_request_body()` fires.** The body is now available. The wasm-shim evaluates rate-limit actions in this phase. `requestBodyJSON('/model')` parses the body and extracts the model name. Per-model rate-limit predicates work because they run here.

5. **The request continues upstream.** The `Authorization` header still contains whatever Authorino set in step 3, which could not be model-specific because Authorino did not know the model.

The gap is between steps 2 and 4. The wasm-shim calls Authorino at step 2 but does not have the body until step 4. Rate limiting works because it evaluates at step 4. Auth key injection does not work because it evaluates at step 2.

### What works in Kuadrant today

- **Auth token validation** on a unified endpoint (does not need the body)
- **Per-model rate limiting** via `requestBodyJSON('/model')` in `RateLimitPolicy` predicates (runs in the body phase)
- **OPA Rego** in AuthPolicy compiles and enforces correctly (syntax: `allow { true }`, avoid hyphens in evaluator names)
- **CEL ternary expressions** in `response.success.headers` for conditional header injection

### What does not work

- **Body-based key injection via AuthPolicy** — `input.request.body` is empty when Authorino is called via the wasm-shim
- **EnvoyFilter `with_request_body`** only affects native Envoy ext_authz filters, not the wasm-shim's gRPC call

### Resolution

The `mixed-providers-unified-path` demo works around this by adding an Envoy Lua filter that runs after the wasm-shim (in the body phase). The Lua filter reads the model from the body, sets the `Authorization` header with the correct provider key, and sets an `X-Target-Provider` header for downstream routing. Auth and rate limiting remain in Kuadrant.

A wasm-shim change to delay the auth call until after body buffering (or to support body-aware header injection via `requestBodyJSON()`) would eliminate the need for the Lua filter.

## What This Proves

### Path-based demo (`mixed-providers`)

- wg-ai-gateway controller runs on OpenShift alongside MaaS
- `XBackendDestination` (FQDN type) routes traffic to external model endpoints
- MaaS Gateway routes `/external/<provider>/*` to the wg-ai-gateway via per-provider HTTPRoutes
- Per-provider API key injection via Kuadrant AuthPolicy `response.success.headers`
- MaaS SA token auth is enforced on all external provider routes
- MaaS API `/v1/models` returns both local and external models in a unified listing
- `TokenRateLimitPolicy` enforces per-tier token budgets on external models
- URL rewriting ensures backends receive clean `/v1/*` paths matching real provider APIs
- The external backend is FQDN-based — simulators can be replaced by any resolvable hostname (external host, VM, or real provider once TLS is implemented)

### Unified endpoint demo (`mixed-providers-unified-path`)

All of the above, plus:

- Single `/v1/chat/completions` endpoint for all external providers — no per-provider URL paths
- Model field in the request body (`{"model":"gpt-4"}`) determines the provider, not the URL
- Envoy Lua filter performs body-based model dispatch and per-provider API key injection at the gateway layer
- Per-model rate limiting via Kuadrant `RateLimitPolicy` with `requestBodyJSON('/model')` predicates — independent buckets per model
- Clients never change URLs when models move between providers — only the gateway configuration changes
- Demonstrates the wasm-shim body access limitation and a working Lua-based workaround

## Documentation

Install, architecture, and validation steps are maintained in each demo directory:

- `demos/mixed-providers/README.md`
- `demos/mixed-providers-unified-path/README.md`
