# PR #662 Validation: payload-processing as MaaS Sub-Component

_Validated 04/05/2026_

PR #662 adds BBR (Body-Based Router) as a MaaS sub-component deployed in the gateway namespace (`openshift-ingress`). BBR runs as an Envoy ext-proc filter that intercepts inference requests and executes a plugin chain: `body-field-to-header` (extract model name) → `model-provider-resolver` (lookup ExternalModel CR for provider + credentials) → `api-translation` (convert OpenAI format to provider-native) → `apikey-injection` (swap MaaS API key with provider key from Secret). Validated end-to-end: MaaS API key minting (201), internal model inference (200), and external model inference to OpenAI gpt-4o and Anthropic claude-sonnet-4 via BBR key injection (200).

### Changes required beyond PR #662 to get working

- **payload-processing image override** — The `params.env` contains a stale image built before the GIE fix. Replaced with `ghcr.io/nerdalert/payload-processing:latest` (built from `ai-gateway-payload-processing` main @ `ee12d8d`, includes PR #101 GIE update + PR #98 skip fix). Required until the `odh-stable` CI pipeline is fixed.
- **DestinationRule `insecureSkipVerify: true`** — PR ships `caCertificates: /etc/ssl/certs/ca-bundle.crt` with `subjectAltNames`, but BBR's self-signed cert is not in the system CA bundle. Added `insecureSkipVerify: true` and removed `caCertificates`/`subjectAltNames` to fix `rq_error: 100%` on the gateway-to-BBR gRPC connection.
- **maas-api supplemental RBAC** — Pre-existing issue (not PR #662): `maas-api` SA can't read `maas-db-config` secret or list MaaS CRDs. Applied supplemental Role + ClusterRole ([gist](https://gist.github.com/nerdalert/66a3c739f8b201298d35b199639786b4)).

## Quick Validate

```bash
# Discover gateway
HOST="https://maas.$(kubectl get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}')"
TOKEN=$(oc whoami -t)

# List models
curl -sSk "$HOST/maas-api/v1/models" -H "Authorization: Bearer $TOKEN" | jq '.data[].id'

# Mint API key
API_KEY=$(curl -sSk -X POST "$HOST/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"test","expiresIn":"2h"}' | jq -r '.key')
echo "API_KEY=$API_KEY"

# Internal model
curl -sSk "$HOST/llm/facebook-opt-125m-simulated/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"hello"}],"max_tokens":8}' | jq .

# External model (OpenAI via BBR)
curl -sSk "$HOST/gpt-4o/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"say hi in one word"}],"max_tokens":8}' | jq .
```

## PR Under Review

- **PR:** [opendatahub-io/models-as-a-service#662](https://github.com/opendatahub-io/models-as-a-service/pull/662)
- **Title:** feat: add payload-processing as MaaS sub-component
- **Branch:** `gatewat_payload_proc`

## Related PRs

| PR | Repo | Title | Status | Required For |
|----|------|-------|--------|-------------|
| [#662](https://github.com/opendatahub-io/models-as-a-service/pull/662) | models-as-a-service | Add payload-processing deployment manifests | Open | Deploys BBR alongside MaaS |
| [#3371](https://github.com/opendatahub-io/opendatahub-operator/pull/3371) | opendatahub-operator | Add `RELATED_IMAGE_ODH_PAYLOAD_PROCESSING_IMAGE` + EnvoyFilter watch | Open | Operator auto-deploys payload-processing |
| [#101](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/101) | ai-gateway-payload-processing | Update GIE reference to include body-field-to-header fix | **Merged** | Fixes 500 on non-inference traffic |
| [#98](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/98) | ai-gateway-payload-processing | model-provider-resolver: skip non-inference requests | **Merged** | Fixes model-provider-resolver error on missing model |
| [#682](https://github.com/opendatahub-io/models-as-a-service/pull/682) | models-as-a-service | Include ExternalModel in /v1/models listing | Open | External models appear in model listing |

## Issues Found and Status

### Issue 1: RBAC — secrets needs `list` + `watch`

- **Status:** Fixed in latest PR commits
- **Root cause:** ClusterRole had `get` only for secrets, but the `apikey-injection` plugin uses a controller-runtime informer that requires `list` + `watch`. Without them, the cache sync times out and the pod CrashLoopBackOfs.

### Issue 2: 500 on non-inference traffic (body-field-to-header error)

- **Status:** Fixed by upstream GIE + new image (not yet in PR's pinned image)
- **Root cause:** The upstream `body-field-to-header` plugin returned a hard error when the request body had no `model` field. With the global EnvoyFilter, every non-inference request was sent to ext-proc and returned 500.
- **Fix:** GIE commit `faee4624e0fe` changed `body-field-to-header` to return `nil` on missing field. PR #101 updates `go.mod` to reference this fix.
- **Blocker:** The `odh-stable` image tag hasn't updated (CI pipeline issue). The sha256 digest in `params.env` points to the old image.
- **Workaround:** Built `ghcr.io/nerdalert/payload-processing:latest` from latest `main` which includes both fixes.

### Issue 3: TLS — DestinationRule CA cert mismatch

- **Status:** Not fixed in PR
- **Root cause:** DestinationRule uses `caCertificates: /etc/ssl/certs/ca-bundle.crt` but BBR's self-signed cert is not in the system CA bundle. Gateway proxy rejects TLS handshake, causing `rq_error: 100%`.
- **Fix applied during validation:** Patched DestinationRule with `insecureSkipVerify: true`.

## Image Build

Since the `odh-stable` tag is stale, we built the payload-processing image from the latest `ai-gateway-payload-processing` main branch:

```
Image: ghcr.io/nerdalert/payload-processing:latest
Tag:   ghcr.io/nerdalert/payload-processing:ee12d8d
Source: opendatahub-io/ai-gateway-payload-processing @ ee12d8d (main)
GIE:   v0.0.0-20260403073909-faee4624e0fe (includes body-field-to-header fix)
Includes: PR #101 (GIE update) + PR #98 (model-provider-resolver skip)
```

## Deployment Steps (Validated)

```bash
# 0. Clone and checkout
cd ~/istio-gw/review
git clone https://github.com/opendatahub-io/models-as-a-service.git
git clone https://github.com/opendatahub-io/ai-gateway-payload-processing.git
cd models-as-a-service
gh pr checkout 662 --repo opendatahub-io/models-as-a-service --force

# 0b. Build payload-processing image (optional — skip if ghcr.io/nerdalert/payload-processing:latest is available)
cd ../ai-gateway-payload-processing
docker build \
  --build-arg BUILDPLATFORM=linux/amd64 \
  --build-arg TARGETPLATFORM=linux/amd64 \
  --build-arg TARGETOS=linux \
  --build-arg TARGETARCH=amd64 \
  --build-arg COMMIT_SHA=$(git rev-parse --short HEAD) \
  -t ghcr.io/nerdalert/payload-processing:latest .
docker push ghcr.io/nerdalert/payload-processing:latest
cd ../models-as-a-service

# 1. Deploy MaaS
./scripts/deploy.sh --operator-type odh

# 2. Override stale image
sed -i 's|payload-processing-image=.*|payload-processing-image=ghcr.io/nerdalert/payload-processing:latest|' \
  deployment/overlays/common/params.env

# 3. Apply PR overlay
kubectl apply -k deployment/overlays/odh

# 4. Fix maas-api RBAC (pre-existing, not PR #662)
#    See: https://gist.github.com/nerdalert/66a3c739f8b201298d35b199639786b4
kubectl apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: maas-api-db-secret-reader
  namespace: opendatahub
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["maas-db-config"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: maas-api-db-secret-reader
  namespace: opendatahub
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: maas-api-db-secret-reader
subjects:
- kind: ServiceAccount
  name: maas-api
  namespace: opendatahub
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: maas-api-supplemental
rules:
- apiGroups: ["maas.opendatahub.io"]
  resources: ["maasmodelrefs", "maassubscriptions"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: maas-api-supplemental
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: maas-api-supplemental
subjects:
- kind: ServiceAccount
  name: maas-api
  namespace: opendatahub
YAML
kubectl rollout restart deployment/maas-api -n opendatahub
kubectl rollout status deployment/maas-api -n opendatahub --timeout=120s

# 5. Fix DestinationRule TLS (BBR self-signed cert)
kubectl apply -f - <<'YAML'
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payload-processing
  namespace: openshift-ingress
  labels:
    app.kubernetes.io/component: payload-processing
    app.kubernetes.io/name: payload-processing
    app.kubernetes.io/part-of: models-as-a-service
spec:
  host: payload-processing.openshift-ingress.svc.cluster.local
  trafficPolicy:
    tls:
      mode: SIMPLE
      insecureSkipVerify: true
YAML

# 6. Deploy baseline models
kubectl create ns llm --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns models-as-a-service --dry-run=client -o yaml | kubectl apply -f -
kustomize build docs/samples/maas-system | kubectl apply -f -
kubectl wait --for=condition=Ready llminferenceservice/facebook-opt-125m-simulated -n llm --timeout=300s

# 7. Validate
HOST="https://maas.$(kubectl get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}')"
TOKEN=$(oc whoami -t)

# API key minting (expect 201)
curl -sSk -w '\nHTTP %{http_code}\n' -X POST "$HOST/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"validate","expiresIn":"2h"}'

# Internal model (expect 200)
API_KEY=$(curl -sSk -X POST "$HOST/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"test","expiresIn":"2h"}' | jq -r '.key')

curl -sSk -w '\nHTTP %{http_code}\n' "$HOST/llm/facebook-opt-125m-simulated/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"hello"}],"max_tokens":8}'

# BBR health (expect rq_error: 0)
POD=$(kubectl get pod -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n openshift-ingress "$POD" -c istio-proxy -- \
  pilot-agent request GET clusters 2>/dev/null | grep "payload-processing" | grep "rq_"
```

## Validation Results (2026-04-05)

### MaaS API Coverage

| # | Test | Endpoint | Result |
|---|------|----------|--------|
| 1 | List models (OC token) | `GET /maas-api/v1/models` | **200** |
| 2 | Mint API key | `POST /maas-api/v1/api-keys` | **201** |
| 3 | List subscriptions (OC token) | `GET /maas-api/v1/subscriptions` | **200** |
| 4 | Internal model inference | `POST /llm/.../v1/chat/completions` | **200** |
| 5 | External model (OpenAI gpt-4o) | `POST /gpt-4o/v1/chat/completions` | **200** |
| 6 | External model (Anthropic claude-sonnet-4) | `POST /claude-sonnet-4-20250514/v1/chat/completions` | **200** |
| 7 | Revoke API key | `DELETE /maas-api/v1/api-keys/:id` | **200** |
| 8 | Inference with revoked key | `POST /llm/.../v1/chat/completions` | **403** |

### BBR / Ext-proc Validation

| # | Test | Result |
|---|------|--------|
| 1 | payload-processing pod | **Running** 1/1, no restarts |
| 2 | BBR cluster health | `rq_error: 0` |
| 3 | Ext-proc filter chain order | Kuadrant WasmPlugin → `ext_proc.bbr` → router |
| 4 | BBR plugin execution | All 4 plugins executed in order |
| 5 | API key injection (OpenAI) | `auth headers injected`, `provider: openai` |
| 6 | API key injection (Anthropic) | `auth headers injected`, `provider: anthropic` |
| 7 | ExternalModel reconciler | All 4 resources created in `llm` per model |

### Multi-Turn Chat

| Provider | Turns completed | Name recall | Rate limited at |
|----------|----------------|-------------|-----------------|
| OpenAI gpt-4o | 7/10 | Correct across all turns | Turn 8 (429, TRLP 1000 tokens/min) |
| Anthropic claude-sonnet-4 | 8/10 | Correct across all turns | Turn 9 (429, TRLP 1000 tokens/min) |

### Notes

- **Ext-proc ordering confirmed:** Kuadrant → payload-processing (BBR) → router. The full 3-ext-proc chain (+ InferencePool) requires GPU nodes.
- **maas-api RBAC gap:** Pre-existing. The operator reconciles away RBAC rules. Workaround: supplemental ClusterRole ([gist](https://gist.github.com/nerdalert/66a3c739f8b201298d35b199639786b4)).
- **ExternalModel naming:** The ExternalModel CR name must match the real provider model ID (e.g., `claude-sonnet-4-20250514`, not `claude-sonnet`). BBR passes the `model` field through to the provider as-is.

## Multi-Provider External Model Validation

[Example results from a validated run](https://gist.github.com/nerdalert/dc64a1ab159d229bb7a5e8e370f0a4b1)

Validates BBR api-translation and apikey-injection across multiple providers.
Set your API keys before running:

```bash
export OPENAI_API_KEY="sk-proj-..."
export ANTHROPIC_API_KEY="sk-ant-..."
```

### Create Secrets

```bash
kubectl create secret generic openai-api-key -n llm \
  --from-literal=api-key="$OPENAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret openai-api-key -n llm \
  inference.networking.k8s.io/bbr-managed=true --overwrite

kubectl create secret generic anthropic-api-key -n llm \
  --from-literal=api-key="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret anthropic-api-key -n llm \
  inference.networking.k8s.io/bbr-managed=true --overwrite
```

### Create ExternalModel CRs + MaaSModelRefs

```bash
kubectl apply -f - <<'YAML'
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: gpt-4o
  namespace: llm
spec:
  provider: openai
  endpoint: api.openai.com
  credentialRef:
    name: openai-api-key
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: claude-sonnet-4-20250514
  namespace: llm
spec:
  provider: anthropic
  endpoint: api.anthropic.com
  credentialRef:
    name: anthropic-api-key
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: gpt-4o
  namespace: llm
spec:
  modelRef:
    kind: ExternalModel
    name: gpt-4o
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: claude-sonnet-4-20250514
  namespace: llm
spec:
  modelRef:
    kind: ExternalModel
    name: claude-sonnet-4-20250514
YAML
```

### Add to Auth and Subscription

```bash
kubectl patch maasauthpolicy simulator-access -n models-as-a-service --type=merge -p '{
  "spec": {
    "modelRefs": [
      {"name":"facebook-opt-125m-simulated","namespace":"llm"},
      {"name":"gpt-4o","namespace":"llm"},
      {"name":"claude-sonnet-4-20250514","namespace":"llm"}
    ]
  }
}'

kubectl patch maassubscription simulator-subscription -n models-as-a-service --type=merge -p '{
  "spec": {
    "modelRefs": [
      {"name":"facebook-opt-125m-simulated","namespace":"llm","tokenRateLimits":[{"limit":100,"window":"1m"}]},
      {"name":"gpt-4o","namespace":"llm","tokenRateLimits":[{"limit":1000,"window":"1m"}]},
      {"name":"claude-sonnet-4-20250514","namespace":"llm","tokenRateLimits":[{"limit":1000,"window":"1m"}]}
    ]
  }
}'
```

### Verify and Validate

```bash
sleep 15
kubectl get maasmodelref -n llm -o wide

HOST="https://maas.$(kubectl get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}')"
TOKEN=$(oc whoami -t)
API_KEY=$(curl -sSk -X POST "$HOST/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"multi-provider-test","expiresIn":"2h"}' | jq -r '.key')

# OpenAI (expect 200)
curl -sSk "$HOST/gpt-4o/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"say hi in one word"}],"max_tokens":8}' | jq '{model: .model, content: .choices[0].message.content}'

# Anthropic (expect 200)
curl -sSk "$HOST/claude-sonnet-4-20250514/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"claude-sonnet-4-20250514","messages":[{"role":"user","content":"say hi in one word"}],"max_tokens":8}' | jq '{model: .model, content: .choices[0].message.content}'
```

### Multi-Turn Chat Validation (10 messages)

Tests that BBR's api-translation correctly handles multi-turn conversations
with accumulated message history — not just single-shot completions.

```bash
# Multi-turn: OpenAI gpt-4o
echo "=== OpenAI multi-turn (10 messages) ==="
MESSAGES='[{"role":"user","content":"My name is Alice. Remember it."}]'
for i in $(seq 1 10); do
  echo "--- Turn $i ---"
  RESP=$(curl -sSk "$HOST/gpt-4o/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $API_KEY" \
    -d "{\"model\":\"gpt-4o\",\"messages\":$MESSAGES,\"max_tokens\":50}")
  CONTENT=$(echo "$RESP" | jq -r '.choices[0].message.content // .error.message // "ERROR"')
  HTTP_CODE=$(echo "$RESP" | jq -r '.error.code // "ok"')
  echo "  Assistant: $CONTENT"
  if [[ "$HTTP_CODE" != "ok" && "$HTTP_CODE" != "null" ]]; then
    echo "  ERROR: $HTTP_CODE — aborting multi-turn"
    break
  fi
  MESSAGES=$(echo "$MESSAGES" | jq --arg c "$CONTENT" '. + [{"role":"assistant","content":$c},{"role":"user","content":"Turn '"$i"': What is my name? Also tell me what turn number this is."}]')
done
```

```bash
# Multi-turn: Anthropic claude-sonnet-4-20250514
echo "=== Anthropic multi-turn (10 messages) ==="
MESSAGES='[{"role":"user","content":"My name is Bob. Remember it."}]'
for i in $(seq 1 10); do
  echo "--- Turn $i ---"
  RESP=$(curl -sSk "$HOST/claude-sonnet-4-20250514/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $API_KEY" \
    -d "{\"model\":\"claude-sonnet-4-20250514\",\"messages\":$MESSAGES,\"max_tokens\":50}")
  CONTENT=$(echo "$RESP" | jq -r '.choices[0].message.content // .error.message // "ERROR"')
  HTTP_CODE=$(echo "$RESP" | jq -r '.error.code // "ok"')
  echo "  Assistant: $CONTENT"
  if [[ "$HTTP_CODE" != "ok" && "$HTTP_CODE" != "null" ]]; then
    echo "  ERROR: $HTTP_CODE — aborting multi-turn"
    break
  fi
  MESSAGES=$(echo "$MESSAGES" | jq --arg c "$CONTENT" '. + [{"role":"assistant","content":$c},{"role":"user","content":"Turn '"$i"': What is my name? Also tell me what turn number this is."}]')
done
```

**Note:** TRLP (token rate limiting) may return 429 before all 10 turns complete. With a 1000 tokens/min limit, the accumulated message history typically hits the limit around turn 7-8. This is expected — increase the limit to 10000 tokens/min in the subscription if you want to complete all 10 turns. A `jq: parse error` on the 429 response is normal (the response body is plain text `Too Many Requests`, not JSON).

### Cleanup

```bash
kubectl delete maasmodelref gpt-4o claude-sonnet-4-20250514 -n llm
kubectl delete externalmodel gpt-4o claude-sonnet-4-20250514 -n llm
kubectl delete secret openai-api-key anthropic-api-key -n llm
```

## Remaining Items for PR Author

1. **DestinationRule:** Add `insecureSkipVerify: true` or implement proper cert provisioning. Current `caCertificates`/`subjectAltNames` config fails because BBR's self-signed cert isn't in the system CA bundle.

2. **Image digest in `params.env`:** Update sha256 digest once `odh-stable` CI pipeline is fixed and publishes an image that includes the GIE fix (PR #101).

3. **Operator PR #3371:** Must merge for `deploy.sh` to create payload-processing automatically. Until then, `kubectl apply -k deployment/overlays/odh` is required as a separate step.
