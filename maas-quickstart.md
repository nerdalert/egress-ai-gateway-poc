# MaaS Quickstart

This quickstart deploys a sample model and runs smoke tests, then validates API key minting and chat completions.

## Prerequisites

- Logged into OpenShift: `oc whoami`
- Tools installed: `oc`, `kubectl`, `kustomize`, `jq`, `git`
- Clone the MaaS repo: `git clone https://github.com/opendatahub-io/models-as-a-service.git`

## 1. Create model namespace

```bash
kubectl create namespace llm
```

## 2. Deploy sample model

```bash
cd models-as-a-service
PROJECT_DIR=$(git rev-parse --show-toplevel)
kustomize build ${PROJECT_DIR}/docs/samples/models/facebook-opt-125m-cpu/ | kubectl apply -f -
```

## 3. Deploy MaaS + run smoke tests

```bash
OPERATOR_CATALOG=quay.io/opendatahub/opendatahub-operator-catalog:latest ./test/e2e/scripts/prow_run_smoke_test.sh
```

## 4. Validate API key minting and chat completion

Set endpoint variables:

```bash
HOST=$(kubectl get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
MAAS_API_BASE_URL="https://${HOST}/maas-api"
```

Use your OpenShift token and mint an API key:

```bash
OC_TOKEN="$(oc whoami -t)"

API_KEY="$(curl -sSk -X POST "${MAAS_API_BASE_URL}/v1/api-keys" \
  -H "Authorization: Bearer ${OC_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"manual-chat-test-key"}' | jq -r '.key')"

echo "API key prefix: ${API_KEY:0:20}..."
```

Get the model endpoint from a smoke-test deployed `MaaSModelRef`:

```bash
MODEL_BASE_URL="$(kubectl get maasmodelref -n llm facebook-opt-125m-simulated \
  -o jsonpath='{.status.endpoint}')"
MODEL_NAME="facebook/opt-125m"
MODEL_V1_URL="${MODEL_BASE_URL}/v1"

echo "MODEL_BASE_URL=${MODEL_BASE_URL}"
echo "MODEL_NAME=${MODEL_NAME}"
```

Run a chat completion using the API key:

```bash
curl -sSk -X POST "${MODEL_V1_URL}/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_NAME}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}]
  }" | jq
```

## Notes

- API management endpoints use OpenShift bearer tokens; inference uses MaaS API keys.
- `e2e-unconfigured-facebook-opt-125m-simulated` is expected to return `403` for inference (unconfigured access path).
