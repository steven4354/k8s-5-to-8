#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_DIR="$REPO_ROOT/k8s/05-gpu"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"

echo "### Project 5: Kind multi-node cluster + NVIDIA GPU Operator + CUDA pod"
echo "### Cluster name: $CLUSTER_NAME"
echo

# Create cluster if it doesn't exist
if ! kind get kubeconfig --name "$CLUSTER_NAME" &>/dev/null; then
  echo "### Creating Kind cluster from $K8S_DIR/gpu-kind.yaml"
  kind create cluster --config "$K8S_DIR/gpu-kind.yaml" --name "$CLUSTER_NAME"
else
  echo "### Kind cluster '$CLUSTER_NAME' already exists; skipping create"
fi

echo
echo "### Add NVIDIA Helm repo and install GPU Operator"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update

helm upgrade --install gpu-operator nvidia/gpu-operator \
  -n gpu-operator --create-namespace \
  --wait --timeout 10m \
  --set driver.enabled=false \
  --set toolkit.enabled=true \
  || echo "### Note: GPU Operator may require real GPU nodes; continuing..."

echo
echo "### Deploy CUDA pod (requests nvidia.com/gpu: 1, runs nvidia-smi)"
kubectl apply -f "$K8S_DIR/gpu-pod.yaml"

echo
echo "### Wait for pod to run (or fail if no GPU available)"
kubectl wait --for=condition=Ready pod/cuda-smi --timeout=120s 2>/dev/null || true

echo
echo "### Pod status"
kubectl get pod cuda-smi -o wide

echo
echo "### nvidia-smi output (if pod ran)"
kubectl logs cuda-smi 2>/dev/null || echo "(Pod may still be Pending if no GPU in cluster)"

echo
echo "### Optional: run fake ML app locally or in cluster"
echo "  cd $REPO_ROOT/ml-stub && pip install -r requirements.txt && python app.py"
echo "  Then: curl http://localhost:8000/healthz && curl -X POST http://localhost:8000/infer -H 'Content-Type: application/json' -d '{\"input\": [1,2,3]}'"
