#!/bin/bash
set -e

# Tutorial: GPU Workloads Quick-Start Script for Lambda Labs
# This script deploys a GPU-enabled pod and verifies GPU access

echo "=========================================="
echo "Tutorial: GPU Workloads on Lambda Labs"
echo "=========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if kubectl is configured
echo -e "${YELLOW}[1/6] Checking kubectl configuration...${NC}"
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}ERROR: kubectl is not configured or cannot connect to cluster${NC}"
    echo "Please ensure your KUBECONFIG is set to your Lambda Labs kubeconfig file:"
    echo "  export KUBECONFIG=/path/to/lambda-kubeconfig.yaml"
    exit 1
fi
echo -e "${GREEN}✓ kubectl is configured${NC}"
echo ""

# Verify GPU nodes are available
echo -e "${YELLOW}[2/6] Verifying GPU nodes are available...${NC}"
GPU_NODES=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l)
if [ "$GPU_NODES" -eq 0 ]; then
    echo -e "${RED}ERROR: No GPU nodes found in the cluster${NC}"
    echo "Please ensure your Lambda 1-Click Cluster has GPU worker nodes."
    exit 1
fi
echo -e "${GREEN}✓ Found $GPU_NODES GPU node(s)${NC}"
echo ""

# Create namespace for the project
echo -e "${YELLOW}[3/6] Creating namespace 'gpu-workloads'...${NC}"
kubectl create namespace gpu-workloads --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespace created${NC}"
echo ""

# Create GPU Pod manifest
echo -e "${YELLOW}[4/6] Creating GPU pod manifest...${NC}"
cat > /tmp/gpu-pod-lambda.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cuda-test-pod
  namespace: gpu-workloads
  labels:
    app: gpu-test
spec:
  restartPolicy: Never
  containers:
  - name: cuda-container
    image: nvidia/cuda:12.1.1-base-ubuntu22.04
    command: 
      - /bin/bash
      - -c
      - |
        echo "=========================================="
        echo "GPU Test Pod - NVIDIA SMI Output"
        echo "=========================================="
        nvidia-smi
        echo ""
        echo "=========================================="
        echo "CUDA Version Check"
        echo "=========================================="
        nvcc --version || echo "nvcc not available in this image"
        echo ""
        echo "Sleeping for 1 hour to allow inspection..."
        sleep 3600
    resources:
      limits:
        nvidia.com/gpu: "1"
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
EOF
echo -e "${GREEN}✓ Manifest created at /tmp/gpu-pod-lambda.yaml${NC}"
echo ""

# Deploy the GPU pod
echo -e "${YELLOW}[5/6] Deploying GPU pod...${NC}"
kubectl apply -f /tmp/gpu-pod-lambda.yaml
echo -e "${GREEN}✓ Pod deployed${NC}"
echo ""

# Wait for pod to be ready
echo -e "${YELLOW}[6/6] Waiting for pod to be ready (this may take 1-2 minutes)...${NC}"
kubectl wait --for=condition=Ready pod/cuda-test-pod -n gpu-workloads --timeout=300s

echo ""
echo -e "${GREEN}=========================================="
echo "✓ GPU Pod Successfully Deployed!"
echo "==========================================${NC}"
echo ""

# Show pod status
echo "Pod Status:"
kubectl get pod cuda-test-pod -n gpu-workloads
echo ""

# Display GPU information
echo -e "${YELLOW}Fetching GPU information from pod...${NC}"
echo ""
kubectl logs cuda-test-pod -n gpu-workloads
echo ""

# Provide next steps
echo -e "${GREEN}=========================================="
echo "Next Steps:"
echo "==========================================${NC}"
echo ""
echo "1. View real-time logs:"
echo "   kubectl logs -f cuda-test-pod -n gpu-workloads"
echo ""
echo "2. Execute commands in the pod:"
echo "   kubectl exec -it cuda-test-pod -n gpu-workloads -- bash"
echo ""
echo "3. Run nvidia-smi interactively:"
echo "   kubectl exec -it cuda-test-pod -n gpu-workloads -- nvidia-smi"
echo ""
echo "4. Check GPU utilization:"
echo "   kubectl exec cuda-test-pod -n gpu-workloads -- nvidia-smi dmon -s u"
echo ""
echo "5. Clean up resources:"
echo "   kubectl delete namespace gpu-workloads"
echo ""
echo -e "${GREEN}=========================================="
echo "Tutorial Quick-Start Complete!"
echo "==========================================${NC}"