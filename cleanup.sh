#!/usr/bin/env bash
set -euo pipefail

# Validate required environment variables
if [[ -z "${CTX_CLUSTER1:-}" || -z "${CTX_CLUSTER2:-}" ]]; then
  echo "❌ Error: Required environment variables not set"
  echo "Please set the following environment variables:"
  echo "  export CTX_CLUSTER1=<your cluster1 context>"
  echo "  export CTX_CLUSTER2=<your cluster2 context>"
  exit 1
fi

# Cluster contexts array for iteration
CLUSTERS=("${CTX_CLUSTER1}" "${CTX_CLUSTER2}")

for CTX in "${CLUSTERS[@]}"; do
  echo -e "\n➡️ [${CTX}] Deleting namespaces in cluster '${CTX}'"
  oc --context="${CTX}" delete namespace istio-system istio-cni ztunnel sample --ignore-not-found
done

echo "✅ Namespaces 'istio-system' and 'sample' removed from both clusters."
