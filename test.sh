#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# verify-multicluster.sh
# Section 5.3.1: Verifying a multi-cluster topology
# Uses contexts "west" and "east"
# --------------------------------------------

# --- Your cluster contexts (must match oc config) ---
CLUSTERS=("west" "east")

# --- Ensure sample namespace and label, deploy apps, wait, and test ---
for CTX in "${CLUSTERS[@]}"; do
  echo "==> [${CTX}] Ensure project and enable Istio injection"
  oc --context="${CTX}" get project sample \
    || oc --context="${CTX}" new-project sample
  oc --context="${CTX}" label namespace sample istio-injection=enabled --overwrite

  echo "==> [${CTX}] Deploy helloworld and sleep"
  # helloworld (v1 on west, v2 on east)
  oc --context="${CTX}" apply \
    -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.26/samples/helloworld/helloworld.yaml \
    -l service=helloworld -n sample
  if [[ "${CTX}" == "west" ]]; then
    oc --context="${CTX}" apply \
      -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.26/samples/helloworld/helloworld.yaml \
      -l version=v1 -n sample
    oc --context="${CTX}" wait --for condition=available -n sample deployment/helloworld-v1
  else
    oc --context="${CTX}" apply \
      -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.26/samples/helloworld/helloworld.yaml \
      -l version=v2 -n sample
    oc --context="${CTX}" wait --for condition=available -n sample deployment/helloworld-v2
  fi
  # sleep (same on both)
  oc --context="${CTX}" apply -n sample -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/sleep/sleep.yaml

  echo "==> [${CTX}] Waiting for deployments to become ready"
  oc --context="${CTX}" wait --for=condition=available deployment/sleep -n sample --timeout=2m
done

# --- Test cross-cluster traffic from each sleep pod ---
for CTX in "${CLUSTERS[@]}"; do
  echo "==> [${CTX}] Testing cluster-local and cross-cluster helloworld responses"
  for i in {1..10}; do
    oc --context="${CTX}" exec -n sample deploy/sleep -c sleep -- \
      curl -sS helloworld.sample:5000/hello || { echo "[${CTX}] request failed"; exit 1; }
  done
done

echo "✅ Verification complete: you should see responses from both v1 and v2 in each loop."