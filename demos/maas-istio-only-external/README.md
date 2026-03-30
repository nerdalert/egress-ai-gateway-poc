# MaaS External Models with BBR

External model inference through MaaS using the ExternalModel reconciler and
BBR (Body-Based Router) for provider key injection and API translation.

## Architecture

```
Client                   MaaS Gateway              BBR ext-proc              External Provider
  |                      (openshift-ingress)       (bbr-system)              (api.openai.com)
  |                           |                        |                          |
  | POST /gpt-4o/v1/         |                        |                          |
  |   chat/completions       |                        |                          |
  | Auth: Bearer <maas-key>  |                        |                          |
  |------------------------->|                        |                          |
  |                           |                        |                          |
  |                    1. Kuadrant Wasm validates       |                          |
  |                       MaaS API key + subscription  |                          |
  |                                                    |                          |
  |                    2. ext-proc sends body to BBR ->|                          |
  |                                                    |                          |
  |                           |  3. body-field-to-header: model -> header         |
  |                           |  4. model-provider-resolver: ExternalModel CR     |
  |                           |     -> provider=openai, creds=llm/openai-api-key  |
  |                           |  5. api-translation: format conversion            |
  |                           |  6. apikey-injection: replaces Auth header         |
  |                           |     with provider key from Secret                 |
  |                           |                        |                          |
  |                           |<-- mutated headers ----|                          |
  |                           |                                                   |
  |                    7. ClearRouteCache re-matches                              |
  |                       to header-based route                                   |
  |                                                                               |
  |                    8. ServiceEntry + DestinationRule                           |
  |                       route to external provider                              |
  |                           |                                                   |
  |                           |--------- POST /v1/chat/completions -------------->|
  |                           |           Auth: Bearer <provider-key>              |
  |                           |           Host: api.openai.com                    |
  |                           |                                                   |
  |                           |<----------------------- 200 OK -------------------|
  |<---------- 200 OK -------|                                                   |
```

## Prerequisites

- OCP cluster with RHOAI/ODH
- `oc login` with cluster-admin
- OpenAI API key (or other provider key)

## 0) Deploy MaaS + BBR + Baseline Models

### Clone repos

```bash
git clone https://github.com/opendatahub-io/models-as-a-service.git
git clone https://github.com/opendatahub-io/ai-gateway-payload-processing.git
```

### Deploy MaaS

```bash
cd models-as-a-service/
./scripts/deploy.sh --operator-type odh
cd ..
```

### Deploy baseline models and subscriptions

```bash
kubectl create ns llm --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns models-as-a-service --dry-run=client -o yaml | kubectl apply -f -

kustomize build docs/samples/maas-system | kubectl apply -f -

kubectl wait --for=condition=Ready llminferenceservice/facebook-opt-125m-simulated -n llm --timeout=300s
```

### Deploy BBR

```bash
kubectl create ns bbr-system --dry-run=client -o yaml | kubectl apply -f -

# Build BBR image
oc -n bbr-system get bc bbr-plugins >/dev/null 2>&1 || \
  oc -n bbr-system new-build --name=bbr-plugins --binary --strategy=docker --to=bbr-plugins:latest

oc -n bbr-system start-build bbr-plugins \
  --from-dir=../ai-gateway-payload-processing --follow
```

```bash
# Deploy BBR pod + service
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bbr-plugins
  namespace: bbr-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payload-processing
  namespace: bbr-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bbr-plugins
  template:
    metadata:
      labels:
        app: bbr-plugins
    spec:
      serviceAccountName: bbr-plugins
      containers:
      - name: bbr-plugins
        image: image-registry.openshift-image-registry.svc:5000/bbr-system/bbr-plugins:latest
        imagePullPolicy: Always
        args:
        - --plugin=body-field-to-header:model-extractor:{"field_name":"model","header_name":"X-Gateway-Model-Name"}
        - --plugin=model-provider-resolver:model-provider-resolver
        - --plugin=api-translation:api-translation
        - --plugin=apikey-injection:apikey-injection
        ports:
        - name: grpc
          containerPort: 9004
        - name: health
          containerPort: 9005
        - name: metrics
          containerPort: 9090
---
apiVersion: v1
kind: Service
metadata:
  name: payload-processing
  namespace: bbr-system
spec:
  selector:
    app: bbr-plugins
  ports:
  - name: grpc
    port: 9004
    targetPort: 9004
  - name: health
    port: 9005
    targetPort: 9005
  - name: metrics
    port: 9090
    targetPort: 9090
YAML

kubectl rollout status deployment/payload-processing -n bbr-system --timeout=180s
```

### BBR RBAC

```bash
kubectl apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: bbr-maasmodelref-reader
rules:
- apiGroups: ["maas.opendatahub.io"]
  resources: ["maasmodelrefs"]
  verbs: ["get","list","watch"]
- apiGroups: ["maas.opendatahub.io"]
  resources: ["externalmodels"]
  verbs: ["get","list","watch"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: bbr-maasmodelref-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: bbr-maasmodelref-reader
subjects:
- kind: ServiceAccount
  name: bbr-plugins
  namespace: bbr-system
YAML

kubectl rollout restart deployment/payload-processing -n bbr-system
kubectl rollout status deployment/payload-processing -n bbr-system --timeout=180s
```

### Gateway-to-BBR networking

```bash
kubectl apply -f manifests/bbr-serviceentry.yaml
kubectl apply -f manifests/bbr-destinationrule.yaml
kubectl apply -f manifests/bbr-envoyfilter.yaml
```

### Verify BBR

```bash
kubectl logs deploy/payload-processing -n bbr-system --tail=10
```

Expected: plugin registration for `model-provider-resolver`, `api-translation`, `apikey-injection`.

## 1) Create External Model

```bash
# Secret with provider API key (label required for BBR secret watcher)
kubectl create secret generic openai-api-key -n llm \
  --from-literal=api-key="$OPENAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret openai-api-key -n llm \
  inference.networking.k8s.io/bbr-managed=true --overwrite

# ExternalModel CR
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
YAML

# MaaSModelRef
kubectl apply -f - <<'YAML'
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
```

The reconciler auto-creates in the model namespace (`llm`):

| Resource | Name | Purpose |
|----------|------|---------|
| ExternalName Service | `maas-model-gpt-4o-backend` | DNS bridge to external FQDN |
| ServiceEntry | `maas-model-gpt-4o-se` | Registers host in Istio mesh |
| DestinationRule | `maas-model-gpt-4o-dr` | TLS origination |
| HTTPRoute | `maas-model-gpt-4o` | Path + header match rules |

Verify:
```bash
kubectl get svc,httproute,serviceentry,destinationrule -n llm | grep gpt-4o
```

## 2) Gateway-to-BBR Networking

Three resources in the gateway namespace connect the gateway proxy to BBR:

```bash
kubectl apply -f manifests/bbr-serviceentry.yaml
kubectl apply -f manifests/bbr-destinationrule.yaml
kubectl apply -f manifests/bbr-envoyfilter.yaml
```

| Manifest | Why it's needed |
|----------|----------------|
| `bbr-serviceentry.yaml` | The gateway proxy has no Envoy cluster for BBR without this. The ext-proc gRPC calls silently fail and `failure_mode_allow` passes the original MaaS key through to the provider unchanged. |
| `bbr-destinationrule.yaml` | Controls TLS mode for the gateway-to-BBR gRPC connection. Without it, Istio defaults to mTLS which causes 100% `rq_error` on the BBR cluster. Must match BBR's `--secure-serving` flag. |
| `bbr-envoyfilter.yaml` | The upstream `body-field-to-header` plugin returns a hard error when the request body has no `model` field. Without per-route scoping, every non-inference request (API key minting, health checks, `/maas-api/*`) fails. This filter disables ext-proc by default and enables it only on external model routes. |

The EnvoyFilter must be updated for each new external model. Route names
follow the pattern `<namespace>.<httproute-name>.<rule-index>`. To discover them:

```bash
POD=$(kubectl get pod -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n openshift-ingress "$POD" -c istio-proxy -- \
  pilot-agent request GET config_dump 2>/dev/null | python3 -c "
import sys,json; data=json.load(sys.stdin)
for c in data['configs']:
  for rc in c.get('dynamic_route_configs',[]):
    for vh in rc.get('route_config',{}).get('virtual_hosts',[]):
      for r in vh.get('routes',[]):
        if 'model' in r.get('name',''):
          print(r['name'], json.dumps(r['match'])[:80])"
```

## 3) Add to Auth and Subscription

```bash
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
```

## 4) Validate

```bash
HOST=$(kubectl get maasmodelref facebook-opt-125m-simulated -n llm \
  -o jsonpath='{.status.endpoint}' | sed -E 's#(https://[^/]+).*#\1#')
TOKEN=$(oc whoami -t)

API_KEY=$(curl -sSk -X POST "$HOST/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"e2e-key","expiresIn":"2h"}' | jq -r '.key')

# Internal model (expected 200)
curl -sSk -w '\n%{http_code}\n' "$HOST/llm/facebook-opt-125m-simulated/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"hello"}],"max_tokens":8}' | tail -1

# External model (expected 200 with real key)
curl -sSk -w '\n%{http_code}\n' "$HOST/gpt-4o/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"say hi"}],"max_tokens":8}' | tail -1
```

## Simulator / Self-Signed Cert Testing

For simulators using self-signed certificates, set `tlsInsecureSkipVerify: true`
on the ExternalModel CR:

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: simulator-model
  namespace: llm
spec:
  provider: openai
  endpoint: 3.150.113.9
  tlsInsecureSkipVerify: true
  credentialRef:
    name: simulator-api-key
```

This generates the DestinationRule with `insecureSkipVerify: true`. Per-model,
so simulator models opt in without weakening production models.

Requires [issue #627](https://github.com/opendatahub-io/models-as-a-service/issues/627).

## Cleanup

```bash
kubectl delete maasmodelref gpt-4o -n llm
kubectl delete externalmodel gpt-4o -n llm
kubectl delete secret openai-api-key -n llm
kubectl delete -f manifests/ --ignore-not-found
```

## Files

```
manifests/
  bbr-serviceentry.yaml       # Makes BBR visible to gateway Envoy
  bbr-destinationrule.yaml    # TLS config for gateway-to-BBR
  bbr-envoyfilter.yaml        # Per-route ext-proc activation
```
