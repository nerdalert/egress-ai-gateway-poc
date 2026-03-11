# Plan: Feedback Integration

Summary of feedback and action items from the workstream review.

## Feedback Items

### 1. Enable Gateway API Inference Extension (GIE)

**Feedback:** When installing Istio, enable GIE via `ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true`.
Not required for external model routing, but needed if we later combine internal/external
routing with IGW/llm-d.

**Action:** Update `install-istio.sh` and `istio-cr.yaml` to add the env var.

### 2. Add Anthropic Support

**Feedback:** Do we have actual manifests and validation for Anthropic, not just inline
examples in the README?

**Action:** Create `manifests/iteration-3-anthropic/` with full 4-resource manifests
and a template for the API key. Validate on cluster once we have an Anthropic key.

Key differences from OpenAI:

| Difference | OpenAI | Anthropic |
|-----------|--------|-----------|
| Auth header name | `Authorization` | `x-api-key` |
| Auth header format | `Bearer <key>` | `<key>` (no prefix) |
| Extra headers | None | `anthropic-version: 2023-06-01` |
| Chat endpoint | `POST /v1/chat/completions` | `POST /v1/messages` |
| Request body format | `{"model":"...","messages":[...]}` | `{"model":"...","messages":[...],"max_tokens":N}` (max_tokens required) |

### 3. Host Header: Can Istio Set It Automatically?

**Feedback:** Is there a way to have Istio inject the Host header itself, without
RequestHeaderModifier in the HTTPRoute?

**Finding:** No native mechanism in ServiceEntry or DestinationRule sets the Host header.
However, Istio VirtualService supports `rewrite.authority` and `headers.request.set.host`,
which would work if we used VirtualService instead of HTTPRoute. Since we're using
Gateway API HTTPRoute (the product direction), `RequestHeaderModifier` is the correct
and only mechanism. This is not a limitation — it's just where header manipulation
lives in the Gateway API model.

| Approach | Mechanism | Works with HTTPRoute? |
|----------|-----------|----------------------|
| `RequestHeaderModifier` filter | HTTPRoute (Gateway API) | Yes (what we use) |
| `rewrite.authority` | VirtualService (Istio API) | No (Istio-only API) |
| `headers.request.set` | VirtualService (Istio API) | No (Istio-only API) |
| ServiceEntry / DestinationRule | N/A | No host header support |

### 4. Secret-Per-Model for Summit

**Feedback:** For Summit, one API key per model (shared across all users). Will evolve
to per-(user, model) after Summit. Keep the patterns separated since the auth approach
will change.

**Current state:** The RequestHeaderModifier approach bakes the key into the HTTPRoute
manifest. This is correct for the Summit scope (one key per model). The MaaS integration
path (AuthPolicy + Authorino reading from Secrets) replaces this for per-user keys.

No code changes needed — just awareness for future iterations.

## Implementation Order

1. Enable GIE in Istio install (install-istio.sh + istio-cr.yaml)
2. Create Anthropic manifests (iteration-3-anthropic/)
3. Update README with Anthropic iteration
4. Validate Anthropic on cluster when key is available
