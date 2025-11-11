#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# verify-multicluster.sh
# Section 5.3.1: Verifying a multi-cluster topology
# Uses Istio standard environment variables: CTX_CLUSTER1 and CTX_CLUSTER2
# --------------------------------------------

# Validate required environment variables
if [[ -z "${CTX_CLUSTER1:-}" || -z "${CTX_CLUSTER2:-}" ]]; then
  echo "❌  Error: Required environment variables not set"
  echo "Please set the following environment variables:"
  echo "  export CTX_CLUSTER1=<your cluster1 context>"
  echo "  export CTX_CLUSTER2=<your cluster2 context>"
  exit 1
fi

# Cluster contexts array for iteration
CLUSTERS=("${CTX_CLUSTER1}" "${CTX_CLUSTER2}")

# --- Istio multicluster remote-clusters check ---
if [[ "${CONTROL_PLANE}" == "primary-remote" ]]; then
  CTXS=("${CLUSTERS[0]}")
else
  CTXS=("${CLUSTERS[@]}")
fi
for CTX in "${CTXS[@]}"; do
  echo -e "\n➡️ [${CTX}] Checking istioctl remote-clusters"
  RC_OUTPUT=$(istioctl remote-clusters --context="${CTX}")
  echo "$RC_OUTPUT"
  # Robustly count clusters (ignore header, count non-empty lines)
  CLUSTER_COUNT=$(echo "$RC_OUTPUT" | awk 'NR>1 && $1!=""' | wc -l)
  # Check that every non-header line contains 'synced'
  NOT_SYNCED=$(echo "$RC_OUTPUT" | awk 'NR>1 && $0!~/synced/')
  if [[ $CLUSTER_COUNT -lt 2 ]]; then
    echo "❌ [${CTX}] ERROR: Less than 2 clusters detected in remote-clusters!"
    exit 1
  fi
  if [[ -n "$NOT_SYNCED" ]]; then
    echo "❌ [${CTX}] ERROR: Not all clusters are synced in remote-clusters!"
    exit 1
  fi
  echo "✅ [${CTX}] remote-clusters check passed"
done

# --- Ensure sample namespace and label, deploy apps, wait, and test ---
for CTX in "${CLUSTERS[@]}"; do
  echo -e "\n➡️ [${CTX}] Ensure project and enable Istio injection"
  oc --context="${CTX}" get project sample \
    || oc --context="${CTX}" new-project sample

  if [[ "${DATA_PLANE}" == "ambient" ]]; then
    oc --context="${CTX}" label namespace sample istio.io/dataplane-mode=ambient --overwrite
  else
    oc --context="${CTX}" label namespace sample istio-injection=enabled --overwrite
  fi

  echo -e "\n➡️ [${CTX}] Deploy helloworld and sleep"
  oc --context="${CTX}" apply \
    -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.27/samples/helloworld/helloworld.yaml \
    -l service=helloworld -n sample
  if [[ "${CTX}" == "${CTX_CLUSTER1}" ]]; then
    oc --context="${CTX}" apply \
      -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.27/samples/helloworld/helloworld.yaml \
      -l version=v1 -n sample
    oc --context="${CTX}" wait --for condition=available -n sample deployment/helloworld-v1
  else
    oc --context="${CTX}" apply \
      -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.27/samples/helloworld/helloworld.yaml \
      -l version=v2 -n sample
    oc --context="${CTX}" wait --for condition=available -n sample deployment/helloworld-v2
    if [[ "${DATA_PLANE}" == "ambient" ]]; then
      oc --context="${CTX}" label svc -n sample -l app=helloworld istio.io/global=true --overwrite
    fi
  fi
  oc --context="${CTX}" apply -n sample -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/sleep/sleep.yaml

  echo -e "\n➡️ [${CTX}] Waiting for deployments to become ready"
  oc --context="${CTX}" wait --for=condition=available deployment/sleep -n sample --timeout=2m
done

# --- Test cross-cluster traffic from each sleep pod ---
for CTX in "${CLUSTERS[@]}"; do
  v1_count=0
  v2_count=0
  echo -e "\n➡️ [${CTX}] Testing cluster-local and cross-cluster helloworld responses"
  for i in {1..100}; do
    RESPONSE=$(oc --context="${CTX}" exec -n sample deploy/sleep -c sleep -- curl -sS helloworld.sample:5000/hello)
    echo "[${CTX}] $i: $RESPONSE"
    if echo "$RESPONSE" | grep -q ' v1'; then
      ((v1_count=v1_count+1))
    fi
    if echo "$RESPONSE" | grep -q ' v2'; then
      ((v2_count=v2_count+1))
    fi
    if [[ $v1_count -gt 0 && $v2_count -gt 0 ]]; then
      echo "✅ [${CTX}] Success: Received responses from both v1 and v2 (v1: $v1_count, v2: $v2_count)"
      break
    fi
  done
  if [[ $v1_count == 0 || $v2_count == 0 ]]; then
    echo "❌ [${CTX}] Failure: Did not receive responses from both versions (v1: $v1_count, v2: $v2_count)"
    exit 1
  fi
done

echo "✅ Verification complete: you should see responses from both v1 and v2 in each loop."
