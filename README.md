# AKS + Azure CNI Overlay + FIPS Node Pool + Istio + Istio CNI

This repo creates an AKS cluster in **West US 2** with:

- Azure CNI Overlay
- 3 x system nodes (`Standard_DS4_v2`)
- A FIPS-enabled user node pool
- Istio service mesh add-on
- Istio CNI enabled

## Prerequisites

- Azure CLI logged in: `az login`
- Access to create resources in the target subscription
- `kubectl` installed

## Step-by-step

1. Clone or open this repo locally.

2. Review and update environment values in `.envrc`:

   ```bash
   export CLUSTER_NAME="aks-fips-istio"
   export RESOURCE_GROUP="rg-aks-fips-istio"
   export LOCATION="westus2"
   export KUBERNETES_VERSION="1.36.1"
   export SYSTEM_NODE_SIZE="Standard_DS4_v2"
   export FIPS_NODE_SIZE="Standard_D4ds_v5"
   export FIPS_NODE_COUNT="3"
   export KUBECONFIG="${PWD}/cluster.config"
   ```

3. Load the environment variables:

   ```bash
   source .envrc
   ```

4. Make the setup script executable:

   ```bash
   chmod +x setup.sh
   ```

5. Run the setup script:

   ```bash
   ./setup.sh
   ```

## What `setup.sh` does

1. Installs/updates `aks-preview` extension.
2. Registers required providers and waits until all are `Registered`.
3. Creates the resource group.
4. Creates the AKS cluster with Azure CNI Overlay and Istio add-on.
5. Adds a FIPS-enabled node pool (`fipspool`).
6. Pulls kubeconfig to `cluster.config`.
7. Enables Istio CNI.
8. Verifies nodes and Istio control plane pods.

## Providers registered

- `Microsoft.ContainerService`
- `Microsoft.Compute`
- `Microsoft.Network`
- `Microsoft.ManagedIdentity`
- `Microsoft.OperationalInsights`
- `Microsoft.Insights`
- `Microsoft.AlertsManagement`
- `Microsoft.Monitor`
- `Microsoft.Authorization`
- `Microsoft.Resources`
- `Microsoft.Dashboard`
- `Microsoft.KeyVault`
- `Microsoft.ContainerRegistry`
- `Microsoft.Kubernetes`
- `Microsoft.KubernetesConfiguration`

## Verify after deployment

```bash
kubectl get nodes -o wide
kubectl get pods -n aks-istio-system
az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query 'serviceMeshProfile' -o yaml
```

## Enable sidecar injection on a namespace

```bash
REVISION=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query 'serviceMeshProfile.istio.revisions[0]' -o tsv)
kubectl label namespace <your-namespace> istio.io/rev="${REVISION}" --overwrite
```

## Notes

- This repo is local-only unless you choose to push it.
- The script is idempotent for provider registration; AKS resource creation is a normal create flow.
