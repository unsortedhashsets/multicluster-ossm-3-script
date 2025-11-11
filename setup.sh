#!/bin/bash

# setup.sh: Run install.sh, test.sh, and verify CTX_CLUSTER1/CTX_CLUSTER2 are set

set -e

# Validate required environment variables
if [[ -z "${CTX_CLUSTER1:-}" || -z "${CTX_CLUSTER2:-}" ]]; then
  echo "❌  Error: Required environment variables not set"
  echo "Please set the following environment variables:"
  echo "  export CTX_CLUSTER1=<your cluster1 context>"
  echo "  export CTX_CLUSTER2=<your cluster2 context>"
  exit 1
fi

# Cluster contexts array for iteration
echo "CTX_CLUSTER1: $CTX_CLUSTER1"
echo "CTX_CLUSTER2: $CTX_CLUSTER2"

# Configuration (Section 5.1)
# Control plane topology: "multi-primary" or "primary-remote"
: "${CONTROL_PLANE:="multi-primary"}"
# Network topology (must be "multi-network" for Sections 5.3/5.4)
: "${NETWORK:="multi-network"}"
# Istio version
: "${ISTIO_VERSION:="v1.27.3"}"
# Data plane (side-cars or ambient)
: "${DATA_PLANE:="ambient"}"

export CONTROL_PLANE NETWORK ISTIO_VERSION DATA_PLANE
echo "CONTROL_PLANE: $CONTROL_PLANE"
echo "NETWORK: $NETWORK"
echo "ISTIO_VERSION: $ISTIO_VERSION"
echo "DATA_PLANE: $DATA_PLANE"

# Generate certificates before installation
./certificates.sh

if [[ "$CONTROL_PLANE" == "multi-primary" && "$NETWORK" == "multi-network" && "$DATA_PLANE" == "side-cars" ]]; then
  echo "Install multi-primary multi-network Istio mesh with side-cars..."
  ./multi-primary-multi-network.sh
elif [[ "$CONTROL_PLANE" == "multi-primary" && "$NETWORK" == "multi-network" && "$DATA_PLANE" == "ambient" ]]; then
  echo "Install multi-primary multi-network Istio mesh with Ambient mode..."
  ./multi-primary-multi-network-ambient.sh
elif [[ "$CONTROL_PLANE" == "primary-remote" && "$NETWORK" == "multi-network" && "$DATA_PLANE" == "side-cars" ]]; then
  echo "Install primary-remote multi-network Istio mesh with side-cars..."
  ./primary-remote-multi-network.sh
else
  echo "❌  Error: Unsupported CONTROL_PLANE / DATA_PLANE / NETWORK combination."
  exit 1
fi

# Run test.sh
./test.sh

echo "Setup complete"
