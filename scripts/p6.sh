#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_DIR="$REPO_ROOT/k8s/06-vllm"

echo "### Project 6: vLLM inference serving (Deployment + Service + HPA)"
echo

echo "### Create namespace, PVC, Deployment, Service, HPA"
kubectl apply -f "$K8S_DIR/namespace.yaml"
kubectl apply -f "$K8S_DIR/vllm-pvc.yaml"
kubectl apply -f "$K8S_DIR/vllm-deployment.yaml"
kubectl apply -f "$K8S_DIR/vllm-service.yaml"
kubectl apply -f "$K8S_DIR/vllm-hpa.yaml"

echo
echo "### Wait for vLLM rollout (model load can take several minutes)"
kubectl rollout status deployment/vllm -n vllm --timeout=600s

echo
echo "### Model warmup probe: /health"
kubectl run curl --rm -i --restart=Never --image=curlimages/curl -- curl -s http://vllm.vllm.svc.cluster.local:8000/health || true

echo
echo "### Port-forward for local /generate test (run in background or separate terminal)"
echo "  kubectl port-forward -n vllm svc/vllm 8000:8000"
echo "  curl -X POST http://localhost:8000/v1/completions -H 'Content-Type: application/json' -d '{\"model\": \"meta-llama/Llama-2-7b-chat-hf\", \"prompt\": \"Hello\", \"max_tokens\": 20}'"
echo
echo "### Or from inside cluster:"
kubectl run curl-generate --rm -i --restart=Never -n vllm --image=curlimages/curl -- curl -s -X POST http://vllm:8000/v1/completions -H 'Content-Type: application/json' -d '{"model":"meta-llama/Llama-2-7b-chat-hf","prompt":"Hi","max_tokens":5}' 2>/dev/null || echo "(vLLM /generate may need more time to load model)"
