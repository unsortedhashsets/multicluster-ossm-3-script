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
# Sections 5.3 & 5.4: Install Istio
# =============================
if [[ "$CONTROL_PLANE" == "multi-primary" && "$NETWORK" == "multi-network" ]]; then
  # ----- 5.3 Installing a multi-primary multi-network mesh
  for CTX in "${CLUSTERS[@]}"; do
    NET=$( [[ "$CTX" == "${CTX_CLUSTER1}" ]] && echo "network1" || echo "network2" )
    CL_NAME=$( [[ "$CTX" == "${CTX_CLUSTER1}" ]] && echo "cluster1" || echo "cluster2" )
    export NET CL_NAME

    if [[ "$DATA_PLANE" == "ambient" ]]; then
      echo "Ambient mode selected"
      echo "➡️  Installing Istio CNI on ${CTX}"
      oc --context="${CTX}" get project istio-cni >/dev/null 2>&1 || oc --context="${CTX}" new-project istio-cni
      envsubst < resources/ambient-istio-cni.yaml | oc --context="${CTX}" apply -f -

      echo "➡️  Installing Istio on ${CTX}"
      oc --context="${CTX}" get project istio-system >/dev/null 2>&1 || oc --context="${CTX}" new-project istio-system
      envsubst < resources/ambient-istio.yaml | oc --context="${CTX}" apply -f -

      echo "➡️  Label istio-system namespace for the ${CTX} cluster"
      oc --context="${CTX}" label namespace istio-system topology.istio.io/network=${NET} --overwrite

      echo "➡️  Install ambient ztunnel on ${CTX}"
      oc --context="${CTX}" get project ztunnel >/dev/null 2>&1 || oc --context="${CTX}" new-project ztunnel
      envsubst < resources/ambient-ztunnel.yaml | oc --context="${CTX}" apply -f -

      echo "➡️   ${CTX}"
    else 
      echo "Side-car mode selected"
      echo "➡️  Installing Istio CNI on ${CTX}"
      oc --context="${CTX}" get project istio-cni >/dev/null 2>&1 || oc --context="${CTX}" new-project istio-cni
      envsubst < resources/istio-cni.yaml | oc --context="${CTX}" apply -f -

      echo "➡️  Installing Istio on ${CTX}"
      oc --context="${CTX}" get project istio-system >/dev/null 2>&1 || oc --context="${CTX}" new-project istio-system
      envsubst < resources/istio.yaml | oc --context="${CTX}" apply -f -
    fi

    echo "➡️  Waiting for Istio control plane Ready on ${CTX}"
    oc --context="${CTX}" wait --for condition=Ready istio/default --timeout=3m

    echo "➡️  Deploying east-west gateway on ${CTX}"
    if [[ "${DATA_PLANE}" == "ambient" ]]; then
      echo "→ Ambient mode: applying HBONE east-west gateway"
      envsubst < resources/ambient-east-west-gateway.yaml | oc --context="${CTX}" apply -f -
    else
      echo "➡️ Sidecar mode: applying side-car east-west gateway"
      if [[ "$CTX" == "${CTX_CLUSTER1}" ]]; then
        oc --context="${CTX}" apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/east-west-gateway-net1.yaml
      else
        oc --context="${CTX}" apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/east-west-gateway-net2.yaml
      fi
    fi
    echo "➡️  Exposing services through gateway on ${CTX}"
    oc --context="${CTX}" apply -n istio-system -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/expose-services.yaml
  done

  for CTX in "${CLUSTERS[@]}"; do
    CL_NAME=$( [[ "$CTX" == "${CTX_CLUSTER1}" ]] && echo "cluster1" || echo "cluster2" )
    echo "➡️  Ensuring ServiceAccount istio-reader-service-account exists in ${CTX}/istio-system"
    if ! oc --context="${CTX}" -n istio-system get sa istio-reader-service-account &>/dev/null; then
      oc --context="${CTX}" -n istio-system create sa istio-reader-service-account
    else
      echo "   istio-reader-service-account already exists — skipping"
    fi

    echo "➡️  Ensuring istio-reader-service-account has 'cluster-reader' role in ${CTX}"
    # Check if the binding already exists
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
elif [[ "$CONTROL_PLANE" == "primary-remote" && "$NETWORK" == "multi-network" ]]; then
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
else 
  echo "❌  Error: Unsupported CONTROL_PLANE ($CONTROL_PLANE) and NETWORK ($NETWORK) combination."
  echo "Supported combinations are:"
  echo "  - CONTROL_PLANE=multi-primary and NETWORK=multi-network"
  echo "  - CONTROL_PLANE=primary-remote and NETWORK=multi-network"
  exit 1
fi
