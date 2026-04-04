# MaaS+BBR Validation: payload-processing as MaaS Sub-Component

### Status Summary _Valid as of 4/4/26_

Latest key PR #662, adds BBR (Body-Based Router) as a MaaS sub-component deployed in the gateway namespace (`openshift-ingress`). BBR runs as an Envoy ext-proc filter that intercepts inference requests and executes a plugin chain: `body-field-to-header` (extract model name) → `model-provider-resolver` (lookup ExternalModel CR for provider + credentials) → `api-translation` (convert OpenAI format to provider-native) → `apikey-injection` (swap MaaS API key with provider key from Secret). Validated end-to-end: MaaS API key minting (201), internal model inference (200), and external model inference to OpenAI gpt-4o via BBR key injection (200).

### Changes required beyond PR #662 to get e2e working

- **payload-processing image override** — The `params.env` sha256 digest points to a stale image built before the GIE fix. Replaced with `ghcr.io/nerdalert/payload-processing:latest` (built from `ai-gateway-payload-processing` main @ `ee12d8d`, includes PR #101 GIE update + PR #98 skip fix). Required until the `odh-stable` CI pipeline is fixed.
- **DestinationRule `insecureSkipVerify: true`** — PR ships `caCertificates: /etc/ssl/certs/ca-bundle.crt` with `subjectAltNames`, but BBR's self-signed cert is not in the system CA bundle. Added `insecureSkipVerify: true` and removed `caCertificates`/`subjectAltNames` to fix `rq_error: 100%` on the gateway-to-BBR gRPC connection.
- **maas-api supplemental RBAC** — Pre-existing issue (not PR #662): `maas-api` SA can't read `maas-db-config` secret or list MaaS CRDs. Applied supplemental Role + ClusterRole ([gist](https://gist.github.com/nerdalert/66a3c739f8b201298d35b199639786b4)).
- **ExternalModel + MaaSModelRef + auth/subscription** — Created OpenAI ExternalModel CR, MaaSModelRef, Secret with provider key, and patched MaaSAuthPolicy + MaaSSubscription to include the external model.

## Quick Validate

```bash
# Discover gateway
HOST="https://maas.$(kubectl get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}')"
TOKEN=$(oc whoami -t)

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

## Related PRs (Dependency Chain)

| PR | Repo | Title | Status | Required For |
|----|------|-------|--------|-------------|
| [#662](https://github.com/opendatahub-io/models-as-a-service/pull/662) | models-as-a-service | Add payload-processing deployment manifests | Open | Deploys BBR alongside MaaS |
| [#3371](https://github.com/opendatahub-io/opendatahub-operator/pull/3371) | opendatahub-operator | Add `RELATED_IMAGE_ODH_PAYLOAD_PROCESSING_IMAGE` + EnvoyFilter watch | Open | Operator auto-deploys payload-processing |
| [#101](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/101) | ai-gateway-payload-processing | Update GIE reference to include body-field-to-header fix | **Merged** | Fixes 500 on non-inference traffic |
| [#98](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/98) | ai-gateway-payload-processing | model-provider-resolver: skip non-inference requests | **Merged** | Fixes model-provider-resolver error on missing model |
| [#646](https://github.com/opendatahub-io/models-as-a-service/pull/646) | models-as-a-service | Add tlsInsecureSkipVerify to ExternalModel spec | Open | Simulator/dev testing with self-signed certs |
| [#632](https://github.com/opendatahub-io/models-as-a-service/pull/632) | models-as-a-service | E2E tests for external models | Open | CI test coverage for ExternalModel |

## Issues Found and Status

### Issue 1: RBAC — secrets needs `list` + `watch`

- **Status:** Fixed in latest PR commits
- **Root cause:** ClusterRole had `get` only for secrets, but the `apikey-injection` plugin uses a controller-runtime informer that requires `list` + `watch`. Without them, the cache sync times out after ~5 minutes and the pod exits with CrashLoopBackOff.
- **Fix in PR:** `deployment/base/payload-processing/rbac/clusterrole.yaml` now has `get`, `list`, `watch`.

### Issue 2: 500 on non-inference traffic (body-field-to-header error)

- **Status:** Fixed by upstream GIE + new image (not yet in PR's pinned image)
- **Root cause:** The upstream `body-field-to-header` plugin returned a hard error when the request body had no `model` field. With the global EnvoyFilter, every non-inference request (API key minting, health checks, `/maas-api/*`) was sent to ext-proc, failed, and returned 500.
- **Upstream fix:** GIE commit `faee4624e0fe` changed `body-field-to-header` to return `nil` (skip gracefully) instead of `errcommon.Error` when the field is missing.
- **ai-gateway-payload-processing PR #101:** Updates `go.mod` to reference the fixed GIE version.
- **ai-gateway-payload-processing PR #98:** Also fixes `model-provider-resolver` to return `nil` on missing model.
- **Blocker:** The `odh-stable` image tag at `quay.io/opendatahub/odh-ai-gateway-payload-processing` hasn't updated for 4+ days (CI pipeline issue flagged by Nir). The sha256 digest in `params.env` points to the OLD image without the fix.
- **Workaround:** Built and pushed `ghcr.io/nerdalert/payload-processing:latest` (commit `ee12d8d`) from latest `main` which includes both fixes.

### Issue 3: TLS — DestinationRule CA cert mismatch

- **Status:** Not fixed in PR
- **Root cause:** The DestinationRule uses `tls.mode: SIMPLE` with `caCertificates: /etc/ssl/certs/ca-bundle.crt` and `subjectAltNames`. BBR runs with `--secure-serving=true` (default) and generates a self-signed cert that is NOT in the system CA bundle. The gateway proxy rejects the TLS handshake, causing `rq_error: 100%` on all gRPC calls. With `failure_mode_allow: false`, this returns 500 to clients.
- **Fix applied during validation:** Patched DestinationRule to use `insecureSkipVerify: true` (removed `caCertificates` and `subjectAltNames`).
- **Recommended fix for PR:** Either add `insecureSkipVerify: true` to `destination-rule.yaml`, or provision a proper cert via cert-manager that is in the system CA bundle.

### Pre-existing Issue: maas-api RBAC

- **Not a PR #662 issue** — this is a pre-existing gap in the operator deployment.
- **Root cause:** `maas-api` service account lacks permission to read `maas-db-config` secret and list `maasmodelrefs`/`maassubscriptions`.
- **Fix:** Supplemental RBAC (see [gist](https://gist.github.com/nerdalert/66a3c739f8b201298d35b199639786b4)).

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

# 4. Fix maas-api RBAC (pre-existing)
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

# 8. External model (OpenAI via BBR — full e2e)
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: openai-api-key
  namespace: llm
  labels:
    inference.networking.k8s.io/bbr-managed: "true"
type: Opaque
stringData:
  api-key: "$OPENAI_API_KEY"
---
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
kind: MaaSModelRef
metadata:
  name: gpt-4o
  namespace: llm
spec:
  modelRef:
    kind: ExternalModel
    name: gpt-4o
YAML

sleep 5

# Verify reconciler created resources
kubectl get svc,httproute,serviceentry,destinationrule -n llm | grep gpt-4o

# Add to auth/subscription
kubectl patch maasauthpolicy simulator-access -n models-as-a-service --type=merge -p '{
  "spec": {
    "modelRefs": [
      {"name":"facebook-opt-125m-simulated","namespace":"llm"},
      {"name":"gpt-4o","namespace":"llm"}
    ]
  }
}'
kubectl patch maassubscription simulator-subscription -n models-as-a-service --type=merge -p '{
  "spec": {
    "modelRefs": [
      {"name":"facebook-opt-125m-simulated","namespace":"llm","tokenRateLimits":[{"limit":100,"window":"1m"}]},
      {"name":"gpt-4o","namespace":"llm","tokenRateLimits":[{"limit":1000,"window":"1m"}]}
    ]
  }
}'

sleep 15

# External model inference (expect 200)
curl -sSk -w '\nHTTP %{http_code}\n' "$HOST/gpt-4o/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"say hi in one word"}],"max_tokens":8}'

# BBR logs (expect auth headers injected, provider=openai)
kubectl logs deploy/payload-processing -n openshift-ingress --since=15s | \
  grep -E "plugin|inject|provider" | tail -5
```

## Validation Results

| Test | Result |
|------|--------|
| payload-processing pod | 1/1 Running, no restarts |
| API key minting (`POST /maas-api/v1/api-keys`) | **201** |
| Internal model inference | **200** |
| ExternalModel reconciler resources | All 4 created in `llm` namespace |
| External model inference (OpenAI gpt-4o via BBR) | **200** — auth headers injected |
| BBR cluster health | `rq_error: 0`, `rq_success > 0` |
| BBR plugin chain | body-field-to-header → model-provider-resolver → api-translation → apikey-injection — all executed |

## Remaining Items for PR Author

1. **DestinationRule:** Add `insecureSkipVerify: true` or implement proper cert provisioning. Current `caCertificates`/`subjectAltNames` config fails because BBR's self-signed cert isn't in the system CA bundle.

2. **Image digest in `params.env`:** Update sha256 digest once `odh-stable` CI pipeline is fixed and publishes an image that includes the GIE fix (PR #101).

3. **Operator PR #3371:** Must merge for `deploy.sh` to create payload-processing automatically. Until then, `kubectl apply -k deployment/overlays/odh` is required as a separate step.
ubuntu@ip-172-31-33-128:~/istio-gw/review$
ubuntu@ip-172-31-33-128:~/istio-gw/review$
ubuntu@ip-172-31-33-128:~/istio-gw/review$
ubuntu@ip-172-31-33-128:~/istio-gw/review$
ubuntu@ip-172-31-33-128:~/istio-gw/review$ cat PR-662-validation.md
# PR #662 Validation: payload-processing as MaaS Sub-Component

PR #662 adds BBR (Body-Based Router) as a MaaS sub-component deployed in the gateway namespace (`openshift-ingress`). BBR runs as an Envoy ext-proc filter that intercepts inference requests and executes a plugin chain: `body-field-to-header` (extract model name) → `model-provider-resolver` (lookup ExternalModel CR for provider + credentials) → `api-translation` (convert OpenAI format to provider-native) → `apikey-injection` (swap MaaS API key with provider key from Secret). Validated end-to-end: MaaS API key minting (201), internal model inference (200), and external model inference to OpenAI gpt-4o via BBR key injection (200).

## Quick Validate

```bash
# Discover gateway
HOST="https://maas.$(kubectl get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}')"
TOKEN=$(oc whoami -t)

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

## Related PRs (Dependency Chain)

| PR | Repo | Title | Status | Required For |
|----|------|-------|--------|-------------|
| [#662](https://github.com/opendatahub-io/models-as-a-service/pull/662) | models-as-a-service | Add payload-processing deployment manifests | Open | Deploys BBR alongside MaaS |
| [#3371](https://github.com/opendatahub-io/opendatahub-operator/pull/3371) | opendatahub-operator | Add `RELATED_IMAGE_ODH_PAYLOAD_PROCESSING_IMAGE` + EnvoyFilter watch | Open | Operator auto-deploys payload-processing |
| [#101](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/101) | ai-gateway-payload-processing | Update GIE reference to include body-field-to-header fix | **Merged** | Fixes 500 on non-inference traffic |
| [#98](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/98) | ai-gateway-payload-processing | model-provider-resolver: skip non-inference requests | **Merged** | Fixes model-provider-resolver error on missing model |
| [#646](https://github.com/opendatahub-io/models-as-a-service/pull/646) | models-as-a-service | Add tlsInsecureSkipVerify to ExternalModel spec | Open | Simulator/dev testing with self-signed certs |
| [#632](https://github.com/opendatahub-io/models-as-a-service/pull/632) | models-as-a-service | E2E tests for external models | Open | CI test coverage for ExternalModel |

## Issues Found and Status

### Issue 1: RBAC — secrets needs `list` + `watch`

- **Status:** Fixed in latest PR commits
- **Root cause:** ClusterRole had `get` only for secrets, but the `apikey-injection` plugin uses a controller-runtime informer that requires `list` + `watch`. Without them, the cache sync times out after ~5 minutes and the pod exits with CrashLoopBackOff.
- **Fix in PR:** `deployment/base/payload-processing/rbac/clusterrole.yaml` now has `get`, `list`, `watch`.

### Issue 2: 500 on non-inference traffic (body-field-to-header error)

- **Status:** Fixed by upstream GIE + new image (not yet in PR's pinned image)
- **Root cause:** The upstream `body-field-to-header` plugin returned a hard error when the request body had no `model` field. With the global EnvoyFilter, every non-inference request (API key minting, health checks, `/maas-api/*`) was sent to ext-proc, failed, and returned 500.
- **Upstream fix:** GIE commit `faee4624e0fe` changed `body-field-to-header` to return `nil` (skip gracefully) instead of `errcommon.Error` when the field is missing.
- **ai-gateway-payload-processing PR #101:** Updates `go.mod` to reference the fixed GIE version.
- **ai-gateway-payload-processing PR #98:** Also fixes `model-provider-resolver` to return `nil` on missing model.
- **Blocker:** The `odh-stable` image tag at `quay.io/opendatahub/odh-ai-gateway-payload-processing` hasn't updated for 4+ days (CI pipeline issue flagged by Nir). The sha256 digest in `params.env` points to the OLD image without the fix.
- **Workaround:** Built and pushed `ghcr.io/nerdalert/payload-processing:latest` (commit `ee12d8d`) from latest `main` which includes both fixes.

### Issue 3: TLS — DestinationRule CA cert mismatch

- **Status:** Not fixed in PR
- **Root cause:** The DestinationRule uses `tls.mode: SIMPLE` with `caCertificates: /etc/ssl/certs/ca-bundle.crt` and `subjectAltNames`. BBR runs with `--secure-serving=true` (default) and generates a self-signed cert that is NOT in the system CA bundle. The gateway proxy rejects the TLS handshake, causing `rq_error: 100%` on all gRPC calls. With `failure_mode_allow: false`, this returns 500 to clients.
- **Fix applied during validation:** Patched DestinationRule to use `insecureSkipVerify: true` (removed `caCertificates` and `subjectAltNames`).
- **Recommended fix for PR:** Either add `insecureSkipVerify: true` to `destination-rule.yaml`, or provision a proper cert via cert-manager that is in the system CA bundle.

### Pre-existing Issue: maas-api RBAC

- **Not a PR #662 issue** — this is a pre-existing gap in the operator deployment.
- **Root cause:** `maas-api` service account lacks permission to read `maas-db-config` secret and list `maasmodelrefs`/`maassubscriptions`.
- **Fix:** Supplemental RBAC (see [gist](https://gist.github.com/nerdalert/66a3c739f8b201298d35b199639786b4)).

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

# 4. Fix maas-api RBAC (pre-existing)
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
  -l gateway.networking.k8s.io/gateway-name=


                                            maas-default-gateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n openshift-ingress "$POD" -c istio-proxy -- \
  pilot-agent request GET clusters 2>/dev/null | grep "payload-processing" | grep "rq_"

# 8. External model (OpenAI via BBR — full e2e)
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: openai-api-key
  namespace: llm
  labels:
    inference.networking.k8s.io/bbr-managed: "true"
type: Opaque
stringData:
  api-key: "$OPENAI_API_KEY"
---
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
kind: MaaSModelRef
metadata:
  name: gpt-4o
  namespace: llm
spec:
  modelRef:
    kind: ExternalModel
    name: gpt-4o
YAML

sleep 5

# Verify reconciler created resources
kubectl get svc,httproute,serviceentry,destinationrule -n llm | grep gpt-4o

# Add to auth/subscription
kubectl patch maasauthpolicy simulator-access -n models-as-a-service --type=merge -p '{
  "spec": {
    "modelRefs": [
      {"name":"facebook-opt-125m-simulated","namespace":"llm"},
      {"name":"gpt-4o","namespace":"llm"}
    ]
  }
}'
kubectl patch maassubscription simulator-subscription -n models-as-a-service --type=merge -p '{
  "spec": {
    "modelRefs": [
      {"name":"facebook-opt-125m-simulated","namespace":"llm","tokenRateLimits":[{"limit":100,"window":"1m"}]},
      {"name":"gpt-4o","namespace":"llm","tokenRateLimits":[{"limit":1000,"window":"1m"}]}
    ]
  }
}'

sleep 15

# External model inference (expect 200)
curl -sSk -w '\nHTTP %{http_code}\n' "$HOST/gpt-4o/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"say hi in one word"}],"max_tokens":8}'

# BBR logs (expect auth headers injected, provider=openai)
kubectl logs deploy/payload-processing -n openshift-ingress --since=15s | \
  grep -E "plugin|inject|provider" | tail -5
```

## Validation Results

| Test | Result |
|------|--------|
| payload-processing pod | 1/1 Running, no restarts |
| API key minting (`POST /maas-api/v1/api-keys`) | **201** |
| Internal model inference | **200** |
| ExternalModel reconciler resources | All 4 created in `llm` namespace |
| External model inference (OpenAI gpt-4o via BBR) | **200** — auth headers injected |
| BBR cluster health | `rq_error: 0`, `rq_success > 0` |
| BBR plugin chain | body-field-to-header → model-provider-resolver → api-translation → apikey-injection — all executed |

## Remaining Items for PR Author

1. **DestinationRule:** Add `insecureSkipVerify: true` or implement proper cert provisioning. Current `caCertificates`/`subjectAltNames` config fails because BBR's self-signed cert isn't in the system CA bundle.

2. **Image digest in `params.env`:** Update sha256 digest once `odh-stable` CI pipeline is fixed and publishes an image that includes the GIE fix (PR #101).

3. **Operator PR #3371:** Must merge for `deploy.sh` to create payload-processing automatically. Until then, `kubectl apply -k deployment/overlays/odh` is required as a separate step.
