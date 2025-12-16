#!/usr/bin/env bash
set -euo pipefail

# certificates.sh: Generate root and intermediate CAs for Istio multi-cluster
# Expects CLUSTERS array to be set in the environment

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

# Check for required CLUSTERS variable
if [[ -z "${CLUSTERS+x}" || "${#CLUSTERS[@]}" -eq 0 ]]; then
  echo "Error: CLUSTERS array must be set before running this script."
  exit 1
fi

# Allow TMP_DIR override for reproducibility/debugging
TMP_DIR="${TMP_DIR:-$(mktemp -d -t ossm-cc-XXXXX)}"
CA_DIR="${CA_DIR:-${TMP_DIR}/ca}"
mkdir -p "${CA_DIR}"
echo "➡️  Certificates will be generated under: ${CA_DIR}"

cleanup() {
  # Uncomment to clean up temp files on exit
  # rm -rf "$TMP_DIR"
  :
}
trap cleanup EXIT

create_root_ca() {
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
}

create_intermediate_ca() {
  local CTX="$1"
  local LC=$(echo "$CTX" | tr '[:upper:]' '[:lower:]')
  local CL_DIR="${CA_DIR}/${LC}"
  mkdir -p "${CL_DIR}"
  echo "➡️  Generating intermediate CA for ${CTX}"

  openssl genrsa -out "${CL_DIR}/ca-key.pem" 4096

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

  openssl req -new -config "${CL_DIR}/intermediate.conf" \
    -key "${CL_DIR}/ca-key.pem" \
    -out "${CL_DIR}/cluster-ca.csr"

  openssl x509 -req -sha256 -days 3650 \
    -CA "${CA_DIR}/root-cert.pem" -CAkey "${CA_DIR}/root-key.pem" -CAcreateserial \
    -extensions req_ext -extfile "${CL_DIR}/intermediate.conf" \
    -in "${CL_DIR}/cluster-ca.csr" \
    -out "${CL_DIR}/ca-cert.pem"

  cat "${CL_DIR}/ca-cert.pem" "${CA_DIR}/root-cert.pem" > "${CL_DIR}/cert-chain.pem"
  cp "${CA_DIR}/root-cert.pem" "${CL_DIR}/"
}

create_apply_ca_secret() {
  local CTX="$1"
  local LC="$2"
  local CL_DIR="$3"
  local NET="$4"
  echo "➡️  Applying CA secrets to $CTX ($LC, $NET)"
  # Ensure istio-system namespace exists and is labeled
  if ! oc --context="$CTX" get project istio-system >/dev/null 2>&1; then
    oc --context="$CTX" new-project istio-system
    echo "   Created namespace istio-system in $CTX."
    oc --context="${CTX}" label namespace istio-system topology.istio.io/network=${NET} --overwrite
    echo "➡️  Label istio-system namespace for the ${CTX} cluster: topology.istio.io/network=${NET}"
  fi

  # Create or update the cacerts secret
  if oc --context="$CTX" get secret -n istio-system cacerts >/dev/null 2>&1; then
    oc --context="$CTX" delete secret -n istio-system cacerts
    echo "   Existing 'cacerts' secret deleted in $CTX."
  fi
  oc --context="$CTX" create secret generic cacerts -n istio-system \
    --from-file="${CL_DIR}/ca-cert.pem" \
    --from-file="${CL_DIR}/ca-key.pem" \
    --from-file="${CL_DIR}/root-cert.pem" \
    --from-file="${CL_DIR}/cert-chain.pem"
  echo "   Secret 'cacerts' created in $CTX."
}

create_root_ca
for IDX in "${!CLUSTERS[@]}"; do
  CTX="${CLUSTERS[$IDX]}"
  LC=$(echo "$CTX" | tr '[:upper:]' '[:lower:]')
  CL_DIR="${CA_DIR}/${LC}"
  NET=$( [[ "$CTX" == "${CTX_CLUSTER1}" ]] && echo "network1" || echo "network2" )
  create_intermediate_ca "$CTX"
  create_apply_ca_secret "$CTX" "$LC" "$CL_DIR" "$NET"
done
