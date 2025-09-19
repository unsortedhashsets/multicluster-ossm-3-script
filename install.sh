#!/usr/bin/env bash
set -euo pipefail

# =============================
# Configuration (Section 5.1)
# =============================
# Control plane topology: "multi-primary" or "primary-remote"
CONTROL_PLANE="multi-primary"
# Network topology (must be "multi-network" for Sections 5.3/5.4)
NETWORK="multi-network"
# Two cluster contexts as defined in your kubeconfig
CLUSTERS=("west" "east")
# Istio version
ISTIO_VERSION=1.26.2

# =============================
# Prepare temp dirs for CAs     (Section 5.2.1)
# =============================
TMP_DIR=$(mktemp -d -t ossm-cc-XXXXX)
CA_DIR="${TMP_DIR}/ca"
mkdir -p "${CA_DIR}"
echo "→ Certificates will be generated under: ${CA_DIR}"

# -----------------------------------
# 5.2.1. Create root CA
# -----------------------------------
openssl genrsa -out "${CA_DIR}/root-key.pem" 4096
cat > "${CA_DIR}/root-ca.conf" <<'EOF'
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
[ req_dn ]
O = Istio
CN = Root CA
EOF

openssl req -sha256 -new -key "${CA_DIR}/root-key.pem" \
  -config "${CA_DIR}/root-ca.conf" \
  -out "${CA_DIR}/root-cert.csr"

openssl x509 -req -sha256 -days 3650 \
  -signkey "${CA_DIR}/root-key.pem" \
  -extensions req_ext -extfile "${CA_DIR}/root-ca.conf" \
  -in "${CA_DIR}/root-cert.csr" \
  -out "${CA_DIR}/root-cert.pem"

# -----------------------------------
# 5.2.1. Create intermediate CAs for each cluster
# -----------------------------------
for C in "${CLUSTERS[@]}"; do
  LC=$(echo "$C" | tr '[:upper:]' '[:lower:]')
  CL_DIR="${CA_DIR}/${LC}"
  mkdir -p "${CL_DIR}"
  echo "→ Generating intermediate CA for ${C}"

  # key
  openssl genrsa -out "${CL_DIR}/ca-key.pem" 4096

  # config
  cat > "${CL_DIR}/intermediate.conf" <<EOF
[ req ]
encrypt_key = no
prompt      = no
utf8        = yes
default_md  = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints     = critical, CA:true, pathlen:0
keyUsage             = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
subjectAltName       = @san
[ san ]
DNS.1 = istiod.istio-system.svc
[ req_dn ]
O  = Istio
CN = Intermediate CA
L  = ${LC}
EOF

  # CSR
  openssl req -new -config "${CL_DIR}/intermediate.conf" \
    -key "${CL_DIR}/ca-key.pem" \
    -out "${CL_DIR}/cluster-ca.csr"

  # Sign with root
  openssl x509 -req -sha256 -days 3650 \
    -CA "${CA_DIR}/root-cert.pem" -CAkey "${CA_DIR}/root-key.pem" -CAcreateserial \
    -extensions req_ext -extfile "${CL_DIR}/intermediate.conf" \
    -in "${CL_DIR}/cluster-ca.csr" \
    -out "${CL_DIR}/ca-cert.pem"

  # Chain cert
  cat "${CL_DIR}/ca-cert.pem" "${CA_DIR}/root-cert.pem" > "${CL_DIR}/cert-chain.pem"
  cp "${CA_DIR}/root-cert.pem" "${CL_DIR}/"
done

# =============================
# 5.2.2. Apply CA secrets
# =============================
CTX1="${CLUSTERS[0]}"
CTX2="${CLUSTERS[1]}"

# East cluster
oc --context="${CTX1}" get project istio-system >/dev/null 2>&1 \
  || oc --context="${CTX1}" new-project istio-system
oc --context="${CTX1}" label namespace istio-system topology.istio.io/network=network1 --overwrite
oc --context="${CTX1}" get secret -n istio-system cacerts >/dev/null 2>&1 \
  || oc --context="${CTX1}" create secret generic cacerts -n istio-system \
       --from-file="${TMP_DIR}/ca/east/ca-cert.pem" \
       --from-file="${TMP_DIR}/ca/east/ca-key.pem" \
       --from-file="${TMP_DIR}/ca/east/root-cert.pem" \
       --from-file="${TMP_DIR}/ca/east/cert-chain.pem"

# West cluster
oc --context="${CTX2}" get project istio-system >/dev/null 2>&1 \
  || oc --context="${CTX2}" new-project istio-system
oc --context="${CTX2}" label namespace istio-system topology.istio.io/network=network2 --overwrite
oc --context="${CTX2}" get secret -n istio-system cacerts >/dev/null 2>&1 \
  || oc --context="${CTX2}" create secret generic cacerts -n istio-system \
       --from-file="${TMP_DIR}/ca/west/ca-cert.pem" \
       --from-file="${TMP_DIR}/ca/west/ca-key.pem" \
       --from-file="${TMP_DIR}/ca/west/root-cert.pem" \
       --from-file="${TMP_DIR}/ca/west/cert-chain.pem"

# =============================
# Sections 5.3 & 5.4: Install Istio
# =============================
if [[ "$CONTROL_PLANE" == "multi-primary" && "$NETWORK" == "multi-network" ]]; then
  # ----- 5.3 Installing a multi-primary multi-network mesh
  for CTX in "${CTX1}" "${CTX2}"; do
    NET=$( [[ "$CTX" == "$CTX1" ]] && echo "network1" || echo "network2" )
    CL_NAME=$( [[ "$CTX" == "$CTX1" ]] && echo "cluster1" || echo "cluster2" )

    echo "→ Installing Istio on ${CTX}"
    cat <<EOF | oc --context="${CTX}" apply -f -
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  version: v${ISTIO_VERSION}
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: ${CL_NAME}
      network: ${NET}
EOF

    echo "→ Waiting for Istio control plane Ready on ${CTX}"
    oc --context="${CTX}" wait --for condition=Ready istio/default --timeout=3m

    echo "→ Deploying east-west gateway on ${CTX}"
    if [[ "$CTX" == "$CTX1" ]]; then
      oc --context="${CTX}" apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/east-west-gateway-net1.yaml
    else
      oc --context="${CTX}" apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/east-west-gateway-net2.yaml
    fi

    echo "→ Exposing services through gateway on ${CTX}"
    oc --context="${CTX}" apply -n istio-system -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/expose-services.yaml
  done

  for CTX in "${CTX1}" "${CTX2}"; do
    CL_NAME=$( [[ "$CTX" == "$CTX1" ]] && echo "cluster1" || echo "cluster2" )
    echo "→ Ensuring ServiceAccount istio-reader-service-account exists in ${CTX}/istio-system"
    if ! oc --context="${CTX}" -n istio-system get sa istio-reader-service-account &>/dev/null; then
      oc --context="${CTX}" -n istio-system create sa istio-reader-service-account
    else
      echo "   istio-reader-service-account already exists — skipping"
    fi

    echo "→ Ensuring istio-reader-service-account has 'cluster-reader' role in ${CTX}"
    # Check if the binding already exists
    if ! oc --context="${CTX}" adm policy who-can get pods --all-namespaces \
          | grep -q "istio-reader-service-account@istio-system"; then
      oc --context="${CTX}" adm policy add-cluster-role-to-user cluster-reader \
        -z "istio-reader-service-account" -n "istio-system"
    else
      echo "   istio-reader-service-account already bound to cluster-reader — skipping"
    fi

    echo "→ Install a remote secret on ${CTX}"
    if [[ "$CTX" == "$CTX1" ]]; then
      istioctl create-remote-secret \
      --context="${CTX}" \
      --name="${CL_NAME}" \
      --create-service-account=false | \
      oc --context="${CTX2}" apply -f -
    else
      istioctl create-remote-secret \
      --context="${CTX}" \
      --name="${CL_NAME}" \
      --create-service-account=false | \
      oc --context="${CTX1}" apply -f -
    fi
  done
else
  # ----- 5.4 Installing a primary-remote multi-network mesh
  # Primary = WEST, Remote = EAST
  echo "→ Installing primary Istio on ${CTX1}"
  cat <<EOF | oc --context="${CTX1}" apply -f -
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  version: v${ISTIO_VERSION}
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster1
      network: network1
      externalIstiod: true
EOF
  oc --context="${CTX1}" wait --for condition=Ready istio/default --timeout=3m
  oc --context="${CTX1}" apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/east-west-gateway-net1.yaml
  oc --context="${CTX1}" apply -n istio-system -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/expose-istiod.yaml
  oc --context="${CTX1}" apply -n istio-system -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/expose-services.yaml

  echo "→ Installing remote Istio on ${CTX2}"
  echo "→ Waiting for east-west gateway external address in ${CTX1}..."
  DISCOVERY_ADDRESS=""
  while [[ -z "$DISCOVERY_ADDRESS" ]]; do
    sleep 5
    DISCOVERY_ADDRESS=$(oc --context="${CTX1}" -n istio-system get svc istio-eastwestgateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  done
  echo "→ Found gateway address: $DISCOVERY_ADDRESS"
  cat <<EOF | oc --context="${CTX2}" apply -f -
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  version: v${ISTIO_VERSION}
  profile: remote
  values:
    istiodRemote:
      injectionPath: /inject/cluster/cluster2/net/network2
    global:
      remotePilotAddress: ${DISCOVERY_ADDRESS}
EOF
  oc --context="${CTX2}" annotate namespace istio-system topology.istio.io/controlPlaneClusters=cluster1 --overwrite
  oc --context="${CTX2}" label namespace istio-system topology.istio.io/network=network2 --overwrite

  echo "→ Creating remote secret from WEST into EAST"
  istioctl create-remote-secret \
    --context="${CTX2}" \
    --name=cluster2 | oc --context="${CTX1}" apply -f -

  oc --context="${CTX2}" wait --for condition=Ready istio/default --timeout=3m
  oc --context="${CTX2}" apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/deployment-models/resources/east-west-gateway-net2.yaml
fi

echo "✅ Multi-cluster setup complete — artifacts in ${TMP_DIR}"
remove.sh
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
test.sh
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