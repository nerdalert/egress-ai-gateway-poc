#!/usr/bin/env bash
# install-istio.sh — Install Istio with Gateway API support
#
# Using 1.29.0 — the Sail Operator does not yet have 1.29.1 available.
# Update ISTIO_VERSION below when 1.29.1 becomes available.
#
# Supports both plain Kubernetes and OpenShift clusters.
#
# Usage:
#   ./scripts/install-istio.sh              # Auto-detect platform
#   ./scripts/install-istio.sh kubernetes   # Force Kubernetes mode
#   ./scripts/install-istio.sh openshift    # Force OpenShift mode

set -euo pipefail

ISTIO_VERSION="1.29.0"
GATEWAY_API_VERSION="v1.2.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
ISTIO_DIR="${SCRIPT_DIR}/../istio-${ISTIO_VERSION}"
ISTIOCTL="${ISTIO_DIR}/bin/istioctl"

# --- Platform detection ---
detect_platform() {
    if [[ -n "${1:-}" ]]; then
        echo "$1"
        return
    fi
    if kubectl api-resources 2>/dev/null | grep -q "routes.*route.openshift.io"; then
        echo "openshift"
    else
        echo "kubernetes"
    fi
}

PLATFORM=$(detect_platform "${1:-}")

echo "============================================"
echo "  Istio ${ISTIO_VERSION} Installation"
echo "  Gateway API CRDs ${GATEWAY_API_VERSION}"
echo "  Platform: ${PLATFORM}"
echo "============================================"
echo ""

# --- Define platform-specific install functions ---

install_istio_kubernetes() {
    if kubectl get namespace istio-system &>/dev/null && \
       kubectl get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q Running; then
        echo "  Istio already running in cluster."
        echo "  To reinstall: istioctl uninstall --purge -y && kubectl delete ns istio-system"
        echo "  Skipping installation."
        return
    fi

    ${ISTIOCTL} install \
        --set profile=minimal \
        --set values.pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true \
        --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY \
        --set meshConfig.accessLogFile=/dev/stdout \
        -y

    echo "  Waiting for istiod to be ready..."
    kubectl wait --for=condition=available deployment/istiod \
        -n istio-system --timeout=120s
}

install_istio_openshift() {
    echo ""
    echo "  OpenShift detected. Using Sail Operator for Istio installation."
    echo ""

    # Step 4a: Install the Sail Operator
    echo "  [4a] Checking for Sail Operator..."
    if kubectl get csv -n openshift-operators 2>/dev/null | grep -q sail; then
        echo "  Sail Operator already installed."
    else
        echo "  Installing Sail Operator from manifests/openshift/sail-operator-subscription.yaml..."
        kubectl apply -f "${MANIFESTS_DIR}/openshift/sail-operator-subscription.yaml"
        echo "  Waiting for Sail Operator to be ready (up to 2.5 minutes)..."
        for i in $(seq 1 30); do
            if kubectl get csv -n openshift-operators 2>/dev/null | grep -q "sail.*Succeeded"; then
                echo "  Sail Operator is ready."
                break
            fi
            if [[ $i -eq 30 ]]; then
                echo "  WARNING: Sail Operator not yet ready. Check: kubectl get csv -n openshift-operators"
                echo "  Continuing anyway — the Istio CR may take time to reconcile."
            fi
            sleep 5
        done
    fi
    echo ""

    # Step 4b: Create istio-system namespace
    echo "  [4b] Creating istio-system namespace..."
    kubectl create namespace istio-system 2>/dev/null || echo "  Namespace already exists."
    echo ""

    # Step 4c: Create Istio CR
    echo "  [4c] Creating Istio control plane from manifests/openshift/istio-cr.yaml..."
    if kubectl get istio default -n istio-system &>/dev/null 2>&1; then
        echo "  Istio CR already exists."
    else
        kubectl apply -f "${MANIFESTS_DIR}/openshift/istio-cr.yaml"
        echo "  Waiting for Istio control plane (up to 5 minutes)..."
        kubectl wait --for=condition=Ready istio/default \
            -n istio-system --timeout=300s 2>/dev/null || \
            echo "  WARNING: Istio CR not yet ready. Check: kubectl get istio -n istio-system"
    fi
    echo ""

    # Step 4d: Configure SCCs
    echo "  [4d] Configuring Security Context Constraints..."
    if command -v oc &>/dev/null; then
        oc adm policy add-scc-to-group anyuid system:serviceaccounts:istio-system 2>/dev/null || true
        echo "  SCCs configured for istio-system."
    else
        echo "  WARNING: 'oc' not available. Verify SCCs manually:"
        echo "    oc adm policy add-scc-to-group anyuid system:serviceaccounts:istio-system"
    fi
}

# --- Step 1: Check prerequisites ---
echo "[1/6] Checking prerequisites..."

if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found. Please install kubectl first."
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to cluster. Is your kubeconfig set?"
    exit 1
fi

KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || kubectl version --client --short 2>/dev/null || echo "unknown")
echo "  kubectl: ${KUBECTL_VERSION}"
echo "  Platform: ${PLATFORM}"

if [[ "${PLATFORM}" == "openshift" ]]; then
    if command -v oc &>/dev/null; then
        OC_VERSION=$(oc version --client 2>/dev/null | head -1 || echo "unknown")
        echo "  oc: ${OC_VERSION}"
    else
        echo "  WARNING: 'oc' CLI not found. Using kubectl only."
    fi
    OCP_VERSION=$(kubectl get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
    echo "  OpenShift version: ${OCP_VERSION}"
fi
echo ""

# --- Step 2: Download istioctl (both platforms, used for diagnostics) ---
echo "[2/6] Setting up istioctl ${ISTIO_VERSION}..."

if [[ -x "${ISTIOCTL}" ]]; then
    echo "  istioctl already downloaded at ${ISTIOCTL}"
else
    echo "  Downloading Istio ${ISTIO_VERSION}..."
    pushd "${SCRIPT_DIR}/.." > /dev/null
    curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
    popd > /dev/null
fi

echo "  istioctl version: $(${ISTIOCTL} version --remote=false 2>/dev/null)"
echo ""

# --- Step 3: Install Gateway API CRDs ---
echo "[3/6] Installing Gateway API CRDs ${GATEWAY_API_VERSION}..."

if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
    EXISTING_VERSION=$(kubectl get crd gateways.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || echo "unknown")
    echo "  Gateway API CRDs already installed (version: ${EXISTING_VERSION})"
fi

# On OpenShift 4.20+ Gateway API CRDs are pre-installed; skip if already present
if kubectl get crd httproutes.gateway.networking.k8s.io &>/dev/null; then
    echo "  Gateway API CRDs already present, skipping install."
else
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
    echo "  Gateway API CRDs installed."
fi
echo ""

# --- Step 4: Install Istio (platform-specific) ---
echo "[4/6] Installing Istio ${ISTIO_VERSION} (${PLATFORM} mode)..."

if [[ "${PLATFORM}" == "openshift" ]]; then
    install_istio_openshift
else
    install_istio_kubernetes
fi
echo ""

# --- Step 5: Verify installation ---
echo "[5/6] Verifying installation..."
echo ""

echo "  Istio pods:"
kubectl get pods -n istio-system
echo ""

echo "  Istio version:"
${ISTIOCTL} version 2>/dev/null || echo "  (istioctl could not reach control plane)"
echo ""

echo "  Gateway API CRDs:"
kubectl get crd | grep gateway.networking.k8s.io || echo "  (none found - ERROR)"
echo ""

echo "  Outbound traffic policy:"
kubectl get cm istio -n istio-system -o jsonpath='{.data.mesh}' 2>/dev/null | \
    grep outboundTrafficPolicy || echo "  (check manually)"
echo ""

# --- Step 6: Platform-specific notes ---
echo "[6/6] Platform-specific notes..."
echo ""

if [[ "${PLATFORM}" == "openshift" ]]; then
    echo "  OpenShift-specific:"
    echo "  - Istio is managed by the Sail Operator. Do NOT use 'istioctl install/uninstall'."
    echo "  - To modify Istio config: kubectl edit istio default -n istio-system"
    echo "  - Verify SCCs: oc get scc anyuid -o jsonpath='{.groups}'"
    echo ""
    echo "  To uninstall:"
    echo "    kubectl delete istio default -n istio-system"
    echo "    kubectl delete subscription sailoperator -n openshift-operators"
    echo "    kubectl delete namespace istio-system"
else
    echo "  Kubernetes:"
    echo "  - For kind/minikube: kubectl port-forward -n external-model-demo svc/external-model-gateway-istio 8080:80"
    echo "  - For minikube: run 'minikube tunnel' in a separate terminal."
    echo ""
    echo "  To uninstall:"
    echo "    ${ISTIOCTL} uninstall --purge -y"
    echo "    kubectl delete namespace istio-system"
fi

echo ""
echo "============================================"
echo "  Installation complete!"
echo ""
echo "  Next steps:"
echo "    1. Deploy namespace + gateway:       ./scripts/deploy.sh base"
echo "    2. Deploy httpbin.org routing:        ./scripts/deploy.sh iteration-1"
echo "    3. Deploy api.openai.com routing:     ./scripts/deploy.sh iteration-2"
echo "    4. See README.md for full instructions"
echo ""
echo "  istioctl path: ${ISTIOCTL}"
echo "  Add to PATH:   export PATH=${ISTIO_DIR}/bin:\$PATH"
echo "============================================"
