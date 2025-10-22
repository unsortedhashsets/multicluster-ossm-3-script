# Multicluster Istio (OpenShift) automation

This folder contains a small set of Bash scripts and YAML templates to automate installing, configuring, and verifying an Istio multicluster, multi-network topology on OpenShift clusters.

Files
-----
- `setup.sh` - Pre-flight checks and central configuration. Exports configuration variables used by the other scripts (for example: `CONTROL_PLANE`, `NETWORK`, `ISTIO_VERSION`).
- `install.sh` - Installs Istio components and configures the topology. Supports two control-plane topologies:
  - `multi-primary` (multi-primary, multi-network)
  - `primary-remote` (primary control plane + remote clusters)
  It reads YAML templates from `resources/` and applies them with `envsubst` so templates can contain placeholders (e.g. `${CL_NAME}`, `${NET}`, `${ISTIO_VERSION}`, `${DISCOVERY_ADDRESS}`).
- `certificates.sh` - Generates CA/intermediate certificates and applies the resulting secrets to clusters. Designed to be idempotent and to use variables for cluster contexts and networks.
- `test.sh` - Runs automated checks and traffic tests to validate multicluster connectivity and service reachability. It performs `istioctl remote-clusters` checks, deploys sample workloads (v1/v2), issues multiple curl calls from pods, and counts responses.
- `cleanup.sh` - Removes namespaces/resources created by the scripts for a clean state.
- `resources/` - YAML templates used by `install.sh`. Templates contain variable placeholders and are consumed with `envsubst`.

Important environment variables
-------------------------------
These must be set before running the install/test workflow (the `setup.sh` script will set defaults where appropriate):

- `CTX_CLUSTER1` - kubeconfig context name for cluster 1 (primary).
- `CTX_CLUSTER2` - kubeconfig context name for cluster 2 (remote or second primary).
- `CONTROL_PLANE` - `multi-primary` or `primary-remote` (controls install paths in `install.sh`).
- `NETWORK` - `multi-network` (network topology; required for the sample scenarios).
- `ISTIO_VERSION` - Istio operator / resource version used in resource templates (e.g. `v1.26.4`).
- `DATA_PLANE` - `side-car` or `ambient` (controls whether sidecar or ambient data plane is used).

Examples (quick start)
----------------------
Export your cluster contexts and preferred topology, then run the setup and install:

```bash
export CTX_CLUSTER1=cluster1-context
export CTX_CLUSTER2=cluster2-context
export CONTROL_PLANE=primary-remote   # or multi-primary
export NETWORK=multi-network
export DATA_PLANE=side-car            # or ambient
export ISTIO_VERSION=v1.26.4

# Optional: source defaults from setup.sh (it sets defaults and exports vars)
./setup.sh

# Run tests
./test.sh

# Cleanup when finished
./cleanup.sh
```

---
Script based on OSSM related multicluster docs

https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.0/html/installing/ossm-multi-cluster-topologies#ossm-installing-primary-remote-multi-network-mesh_ossm-multi-cluster-topologies

