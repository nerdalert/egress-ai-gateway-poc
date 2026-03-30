# External Model E2E: MaaS + BBR + Istio

End-to-end setup for external model inference through MaaS with BBR api-key injection.

## Prerequisites

- OCP cluster with RHOAI/ODH
- `oc login` with cluster-admin

### Clone repos

```bash
git clone https://github.com/opendatahub-io/models-as-a-service.git
git clone https://github.com/opendatahub-io/ai-gateway-payload-processing.git
```

## 1) Deploy MaaS

```bash
cd models-as-a-service/
./scripts/deploy.sh --operator-type odh
```

## 2) Deploy baseline models and subscriptions

```bash
kubectl create ns llm --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns models-as-a-service --dry-run=client -o yaml | kubectl apply -f -

cd models-as-a-service/
kustomize build docs/samples/maas-system | kubectl apply -f -

kubectl wait --for=condition=Ready llminferenceservice/facebook-opt-125m-simulated -n llm --timeout=300s
kubectl wait --for=condition=Ready llminferenceservice/premium-simulated-simulated-premium -n llm --timeout=300s
kubectl get maasmodelref -n llm -o wide
```

## 3) Build and deploy custom maas-controller

```bash
cd models-as-a-service/

oc -n opendatahub get bc maas-controller-custom >/dev/null 2>&1 || \
  oc -n opendatahub new-build --name=maas-controller-custom --binary --strategy=docker --to=maas-controller-custom:latest

oc -n opendatahub start-build maas-controller-custom --from-dir=maas-controller --follow

oc -n opendatahub set image deployment/maas-controller \
  manager=image-registry.openshift-image-registry.svc:5000/opendatahub/maas-controller-custom:latest

oc -n opendatahub rollout restart deployment/maas-controller
oc -n opendatahub rollout status deployment/maas-controller --timeout=300s
```

## 4) Deploy BBR ext-proc chain

### 4a) Build and deploy BBR

```bash
kubectl create ns redhat-ods-applications --dry-run=client -o yaml | kubectl apply -f -

oc -n redhat-ods-applications get bc bbr-plugins >/dev/null 2>&1 || \
  oc -n redhat-ods-applications new-build --name=bbr-plugins --binary --strategy=docker --to=bbr-plugins:latest

oc -n redhat-ods-applications start-build bbr-plugins \
  --from-dir=ai-gateway-payload-processing/ --follow
```

```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bbr-plugins
  namespace: redhat-ods-applications
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bbr-plugins
  namespace: redhat-ods-applications
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
        image: image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/bbr-plugins:latest
        imagePullPolicy: Always
        args:
        - --plugin=body-field-to-header:model-header:{"field_name":"model","header_name":"X-Gateway-Model-Name"}
        - --plugin=model-provider-resolver:default
        - --plugin=api-translation:default
        - --plugin=apikey-injection:default
        - --secure-serving=false
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
  name: bbr-plugins
  namespace: redhat-ods-applications
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

kubectl rollout status deployment/bbr-plugins -n redhat-ods-applications --timeout=180s
```

### 4b) BBR RBAC

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
YAML

kubectl apply -f - <<'YAML'
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
  namespace: redhat-ods-applications
YAML

kubectl rollout restart deployment/bbr-plugins -n redhat-ods-applications
kubectl rollout status deployment/bbr-plugins -n redhat-ods-applications --timeout=180s
```

### 4c) Gateway-to-BBR networking

```bash
kubectl apply -f manifests/bbr-serviceentry.yaml
kubectl apply -f manifests/bbr-destinationrule.yaml

kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: bbr-plugins-allow-grpc
  namespace: redhat-ods-applications
spec:
  podSelector:
    matchLabels:
      app: bbr-plugins
  ingress:
  - ports:
    - port: 9004
      protocol: TCP
    - port: 9005
      protocol: TCP
    - port: 9090
      protocol: TCP
YAML
```

### 4d) EnvoyFilter (per-route ext-proc)

The ext-proc filter is disabled by default and enabled per-route on external
model routes only. This prevents the `body-field-to-header` plugin from
breaking non-inference traffic.

```bash
kubectl apply -f manifests/bbr-envoyfilter.yaml
```

To find route names for new external models:

```bash
POD=$(kubectl get pod -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n openshift-ingress "$POD" -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  python3 -c "
import sys,json; data=json.load(sys.stdin)
for c in data['configs']:
  for rc in c.get('dynamic_route_configs',[]):
    for vh in rc.get('route_config',{}).get('virtual_hosts',[]):
      for r in vh.get('routes',[]):
        if 'model' in r.get('name',''):
          print(r['name'], json.dumps(r['match'])[:80])"
```

Route names follow the pattern `<namespace>.<httproute-name>.<rule-index>`.
Add `HTTP_ROUTE` patches to `manifests/bbr-envoyfilter.yaml` for each new model.

### 4e) Verify BBR

```bash
kubectl get deploy,svc -n redhat-ods-applications | grep bbr-plugins
kubectl get envoyfilter -n openshift-ingress bbr-ext-proc
kubectl get serviceentry -n openshift-ingress bbr-plugins
kubectl get destinationrule -n openshift-ingress bbr-plugins-no-tls
kubectl logs deploy/bbr-plugins -n redhat-ods-applications --tail=30
```

## 5) Create ExternalModel + MaaSModelRef

```bash
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
  api-key: "${OPENAI_API_KEY:-sk-demo-invalid}"
YAML

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

## 6) Verify reconciler output

```bash
kubectl get svc,httproute,serviceentry,destinationrule -n llm | grep -E 'gpt-4o|maas-model'
```

Expected:
- `service/maas-model-gpt-4o-backend` (ExternalName -> `api.openai.com`)
- `httproute/maas-model-gpt-4o`
- `serviceentry/maas-model-gpt-4o-se`
- `destinationrule/maas-model-gpt-4o-dr`

## 7) Add external model to auth and subscription

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

## 8) Validate

```bash
HOST=$(kubectl get maasmodelref facebook-opt-125m-simulated -n llm -o jsonpath='{.status.endpoint}' | sed -E 's#(https://[^/]+).*#\1#')
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

# External model (expected 200 with real key, 401 with sk-demo-invalid)
curl -sSk -w '\n%{http_code}\n' "$HOST/gpt-4o/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"say hi"}],"max_tokens":8}' | tail -1
```

To use a real OpenAI key:

```bash
kubectl create secret generic openai-api-key -n llm \
  --from-literal=api-key="$OPENAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret openai-api-key -n llm \
  inference.networking.k8s.io/bbr-managed=true --overwrite
```

## 9) Cleanup

```bash
kubectl delete maasmodelref gpt-4o -n llm
kubectl delete externalmodel gpt-4o -n llm
kubectl delete secret openai-api-key -n llm
```
