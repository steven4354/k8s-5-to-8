#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPERATOR_DIR="$REPO_ROOT/operator"
K8S_OP_DIR="$REPO_ROOT/k8s/07-operator"

echo "### Project 7: InferenceDeployment operator (Kubebuilder-style)"
echo

echo "### Build operator binary"
cd "$OPERATOR_DIR"
go mod tidy 2>/dev/null || true
go build -o bin/manager main.go 2>/dev/null || true
if [[ ! -f bin/manager ]]; then
  echo "Build failed; run: cd $OPERATOR_DIR && go mod tidy && go build -o bin/manager ."
  exit 1
fi

echo "### Install CRD"
kubectl apply -f "$OPERATOR_DIR/config/crd/bases/ml.example.com_inferencedeployments.yaml"

echo "### Install RBAC (optional if running in-cluster)"
kubectl apply -f "$OPERATOR_DIR/config/rbac/role.yaml" 2>/dev/null || true

echo "### Run operator in background (or use 'make run' in operator dir)"
"$OPERATOR_DIR/bin/manager" &
OP_PID=$!
sleep 3

echo "### Apply sample InferenceDeployment"
kubectl apply -f "$K8S_OP_DIR/inferencedeployment-sample.yaml"

echo "### Check CR and created Deployment/Service"
kubectl get inferencedeployment
kubectl get deploy,svc -l app=llama-sample 2>/dev/null || kubectl get deploy,svc

echo
echo "### To stop operator: kill $OP_PID"
echo "### To scale: kubectl scale inferencedeployment llama-sample --replicas=2  (if CRD supports scale subresource)"
