#!/usr/bin/env bash
set -euo pipefail

# Two cluster contexts as defined in your kubeconfig
# Check required environment variables
if [[ -z "${CTX_CLUSTER1:-}" || -z "${CTX_CLUSTER2:-}" ]]; then
    echo "❌  Error: Required environment variables not set"
    echo "Please set the following environment variables:"
    echo "  export CTX_CLUSTER1=<your cluster1 context>"
    echo "  export CTX_CLUSTER2=<your cluster2 context>"
    exit 1
fi
# Check required configuration variables
if [[ -z "${CONTROL_PLANE:-}" || -z "${NETWORK:-}" ]]; then
    echo "❌  Error: CONTROL_PLANE and NETWORK must be set."
    echo "Please set these variables in your environment or in setup.sh."
    exit 1
fi

# Cluster contexts array for iteration
CLUSTERS=("${CTX_CLUSTER1}" "${CTX_CLUSTER2}")

# =============================
# Sections 5.4: Install Istio
# =============================
# ----- 5.4 Installing a primary-remote multi-network mesh
echo "➡️  Installing Istio CNI on ${CTX_CLUSTER1}"
oc --context="${CTX_CLUSTER1}" get project istio-cni >/dev/null 2>&1 || oc --context="${CTX_CLUSTER1}" new-project istio-cni
envsubst < resources/istio-cni.yaml | oc --context="${CTX_CLUSTER1}" apply -f -

echo "➡️  Installing primary Istio on ${CTX_CLUSTER1}"
oc --context="${CTX_CLUSTER1}" get project istio-system >/dev/null 2>&1 || oc --context="${CTX_CLUSTER1}" new-project istio-system

echo "➡️  Set the default network for the ${CTX_CLUSTER1} cluster"
oc --context="${CTX_CLUSTER1}" label namespace istio-system topology.istio.io/network=network1
envsubst < resources/primary-istio.yaml | oc --context="${CTX_CLUSTER1}" apply -f -
oc --context="${CTX_CLUSTER1}" wait --for condition=Ready istio/default --timeout=3m
oc --context="${CTX_CLUSTER1}" apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/east-west-gateway-net1.yaml
oc --context="${CTX_CLUSTER1}" apply -n istio-system -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/expose-istiod.yaml
oc --context="${CTX_CLUSTER1}" apply -n istio-system -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/expose-services.yaml

echo "➡️  Installing Istio CNI on ${CTX_CLUSTER2}"
oc --context="${CTX_CLUSTER2}" get project istio-cni >/dev/null 2>&1 || oc --context="${CTX_CLUSTER2}" new-project istio-cni
envsubst < resources/istio-cni.yaml | oc --context="${CTX_CLUSTER2}" apply -f -

echo "➡️  Installing remote Istio on ${CTX_CLUSTER2}"
echo "➡️  Waiting for east-west gateway external address in ${CTX_CLUSTER1}..."
DISCOVERY_ADDRESS=""
while [[ -z "$DISCOVERY_ADDRESS" ]]; do
sleep 5
DISCOVERY_ADDRESS=$(oc --context="${CTX_CLUSTER1}" -n istio-system get svc istio-eastwestgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
done
echo "➡️  Found gateway address: $DISCOVERY_ADDRESS"
export DISCOVERY_ADDRESS
envsubst < resources/istio-remote.yaml | oc --context="${CTX_CLUSTER2}" apply -f -
oc --context="${CTX_CLUSTER2}" annotate namespace istio-system topology.istio.io/controlPlaneClusters=cluster1 --overwrite
oc --context="${CTX_CLUSTER2}" label namespace istio-system topology.istio.io/network=network2 --overwrite

echo "➡️  Creating remote secret from ${CTX_CLUSTER2} into {$CTX_CLUSTER1}"
istioctl create-remote-secret \
--context="${CTX_CLUSTER2}" \
--name=cluster2 | oc --context="${CTX_CLUSTER1}" apply -f -

oc --context="${CTX_CLUSTER2}" wait --for condition=Ready istio/default --timeout=3m
oc --context="${CTX_CLUSTER2}" apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/east-west-gateway-net2.yaml
