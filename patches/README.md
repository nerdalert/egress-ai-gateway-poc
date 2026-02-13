# MaaS API Patch: External Model Discovery

Adds ConfigMap-based external model discovery to the MaaS API so that
`GET /v1/models` returns both local KServe models and external models
in a single unified response.

## What It Changes

Two files in `models-as-a-service/maas-api/`:

### `cmd/main.go`

Passes the existing `ConfigMapLister` and namespace to the model manager
via the new `WithConfigMapLister` option.

### `internal/models/kserve_llmisvc.go`

- Adds `configMapLister` and `configNamespace` fields to `Manager`
- Adds `ManagerOption` functional options pattern (`WithConfigMapLister`)
- Adds `listExternalModels()` which reads the `external-model-registry`
  ConfigMap and returns `Model` objects for each entry
- Adds `ExternalModelEntry` struct for YAML parsing
- Merges external models into `ListAvailableLLMs` after KServe discovery

## How It Works

1. Admin creates a ConfigMap named `external-model-registry` in the MaaS
   API namespace (e.g., `opendatahub`):

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: external-model-registry
     namespace: opendatahub
   data:
     models: |
       - id: gpt-4-external
         provider: openai
         backend: external-model-backend
       - id: claude-3-sonnet-external
         provider: anthropic
         backend: anthropic-backend
   ```

2. On each `GET /v1/models` request, the MaaS API reads this ConfigMap
   from the informer cache and appends the entries to the KServe model list.

3. If the ConfigMap doesn't exist, external models are silently skipped
   (backwards compatible).

## Applying the Patch

```bash
cd <path-to>/models-as-a-service
git apply <path-to>/egress-ai-gateway-poc/patches/maas-api-external-models.patch
```

## Pre-built Image

A pre-built image with this patch applied is available at:

```
ghcr.io/nerdalert/maas-api:external-models
```

To use it on OpenShift, annotate the deployment to prevent the ODH operator
from reverting it, then set the image:

```bash
kubectl annotate deployment maas-api -n opendatahub opendatahub.io/managed="false" --overwrite
kubectl set image deployment/maas-api -n opendatahub maas-api=ghcr.io/nerdalert/maas-api:external-models
```
