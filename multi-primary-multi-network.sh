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
# Sections 5.3: Install Istio
# =============================
# ----- 5.3 Installing a multi-primary multi-network mesh
for CTX in "${CLUSTERS[@]}"; do
    NET=$( [[ "$CTX" == "${CTX_CLUSTER1}" ]] && echo "network1" || echo "network2" )
    CL_NAME=$( [[ "$CTX" == "${CTX_CLUSTER1}" ]] && echo "cluster1" || echo "cluster2" )
    export NET CL_NAME

    echo "Side-car mode selected"
    echo "➡️  Installing Istio CNI on ${CTX}"
    oc --context="${CTX}" get project istio-cni >/dev/null 2>&1 || oc --context="${CTX}" new-project istio-cni
    envsubst < resources/istio-cni.yaml | oc --context="${CTX}" apply -f -

    echo "➡️  Installing Istio on ${CTX}"
    oc --context="${CTX}" get project istio-system >/dev/null 2>&1 || oc --context="${CTX}" new-project istio-system
    envsubst < resources/istio.yaml | oc --context="${CTX}" apply -f -

    echo "➡️  Waiting for Istio control plane Ready on ${CTX}"
    oc --context="${CTX}" wait --for condition=Ready istio/default --timeout=3m

    echo "➡️ Sidecar mode: applying side-car east-west gateway"
    if [[ "$CTX" == "${CTX_CLUSTER1}" ]]; then
        oc --context="${CTX}" apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/east-west-gateway-net1.yaml
    else
        oc --context="${CTX}" apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/east-west-gateway-net2.yaml
    fi

    echo "➡️  Exposing services through gateway on ${CTX}"
    oc --context="${CTX}" apply -n istio-system -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/expose-services.yaml

    echo "➡️  Ensuring ServiceAccount istio-reader-service-account exists in ${CTX}/istio-system"
    if ! oc --context="${CTX}" -n istio-system get sa istio-reader-service-account &>/dev/null; then
        oc --context="${CTX}" -n istio-system create sa istio-reader-service-account
    else
        echo "   istio-reader-service-account already exists — skipping"
    fi

    echo "➡️  Ensuring istio-reader-service-account has 'cluster-reader' role in ${CTX}"
    if ! oc --context="${CTX}" adm policy who-can get pods --all-namespaces \
            | grep -q "istio-reader-service-account@istio-system"; then
        oc --context="${CTX}" adm policy add-cluster-role-to-user cluster-reader \
        -z "istio-reader-service-account" -n "istio-system"
    else
        echo "   istio-reader-service-account already bound to cluster-reader — skipping"
    fi

    echo "➡️  Install a remote secret on ${CTX}"
    if [[ "$CTX" == "${CTX_CLUSTER1}" ]]; then
        istioctl create-remote-secret \
        --context="${CTX}" \
        --name="${CL_NAME}" \
        --create-service-account=false | \
        oc --context="${CTX_CLUSTER2}" apply -f -
    else
        istioctl create-remote-secret \
        --context="${CTX}" \
        --name="${CL_NAME}" \
        --create-service-account=false | \
        oc --context="${CTX_CLUSTER1}" apply -f -
    fi
done