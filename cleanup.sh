
#!/usr/bin/env bash
set -euo pipefail

# remove.sh – delete only the istio-system and sample namespaces
# Contexts: west and east

CLUSTERS=("west" "east")

for CTX in "${CLUSTERS[@]}"; do
  echo "→ Deleting namespaces in cluster '${CTX}'"
  oc --context="${CTX}" delete namespace istio-system sample --ignore-not-found
done

echo "✅ Namespaces 'istio-system' and 'sample' removed from both clusters."
