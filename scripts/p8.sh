#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_DIR="$REPO_ROOT/k8s/08-webhooks"

echo "### Project 8: Webhooks + cluster lifecycle (mutating/validating, cert-manager)"
echo

echo "### Install cert-manager (if not present)"
if ! kubectl get ns cert-manager &>/dev/null; then
  helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
  helm repo update
  helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
    --set installCRDs=true \
    --wait --timeout 3m || echo "Helm install cert-manager failed; ensure cluster is up"
fi

echo
echo "### Create namespace and TLS certificate for webhook"
kubectl apply -f "$K8S_DIR/namespace.yaml"
kubectl apply -f "$K8S_DIR/cert-manager-issuer.yaml"

echo "### Wait for certificate"
kubectl wait --for=condition=Ready certificate/gpu-webhook-tls -n gpu-webhook --timeout=120s 2>/dev/null || true

echo
echo "### Build and load webhook image (into Kind if applicable)"
if command -v kind &>/dev/null && kind get kubeconfig --name kind &>/dev/null 2>&1; then
  (cd "$REPO_ROOT/webhook" && docker build -t gpu-webhook:latest . 2>/dev/null) || true
  kind load docker-image gpu-webhook:latest 2>/dev/null || true
fi

echo
echo "### Deploy webhook server and register webhooks"
kubectl apply -f "$K8S_DIR/webhook-deployment.yaml"
kubectl apply -f "$K8S_DIR/validating-webhook.yaml"
kubectl apply -f "$K8S_DIR/mutating-webhook.yaml"

echo "### Patch webhook configs with CA bundle (so API server trusts the webhook)"
CABUNDLE=$(kubectl get secret gpu-webhook-tls -n gpu-webhook -o jsonpath='{.data.ca\.crt}' 2>/dev/null || kubectl get secret gpu-webhook-tls -n gpu-webhook -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
if [[ -n "$CABUNDLE" ]]; then
  kubectl patch validatingwebhookconfiguration gpu-validating --type='json' -p="[{\"op\":\"add\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"$CABUNDLE\"}]" 2>/dev/null || true
  kubectl patch mutatingwebhookconfiguration gpu-mutating --type='json' -p="[{\"op\":\"add\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"$CABUNDLE\"}]" 2>/dev/null || true
fi

echo
echo "### Wait for webhook pod"
kubectl rollout status deployment/gpu-webhook -n gpu-webhook --timeout=120s 2>/dev/null || true

echo
echo "### Test: Pod with 1 GPU (allowed + sidecar injected)"
kubectl apply -f "$K8S_DIR/pod-1gpu.yaml" 2>/dev/null && echo "Created pod-1gpu" || true
kubectl get pod allowed-1gpu -o jsonpath='{.spec.containers[*].name}' 2>/dev/null && echo

echo
echo "### Test: Pod with 2 GPUs (should be rejected)"
kubectl apply -f "$K8S_DIR/pod-2gpu-reject.yaml" 2>&1 || true

echo
echo "### Cluster upgrade (simulated): drain and rolling update control-plane"
echo "  See blog outline: Kind kubeadm upgrade = drain nodes, then upgrade control-plane nodes."
echo "  Example (no destructive run here): kubectl drain <node> --ignore-daemonsets; upgrade kubeadm/kubelet; uncordon."
