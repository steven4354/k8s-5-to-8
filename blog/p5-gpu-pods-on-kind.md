# Blog outline: GPU Pods on Local K8s — AI Ready in 10 min

## Audience
Developers who want to run GPU workloads (CUDA, ML inference) on a local Kubernetes cluster (Kind) and get from zero to a running `nvidia-smi` pod in about 10 minutes.

## Sections

1. **Why Kind + GPU Operator**
   - Kind gives you a multi-node cluster in Docker; the NVIDIA GPU Operator installs device plugin, toolkit, and (optionally) driver so Pods can request `nvidia.com/gpu`.
   - Caveat: real GPU passthrough on Kind requires host GPU + nvidia-container-toolkit and a custom Kind containerd config; otherwise use for YAML/Helm flow and CI.

2. **Prerequisites**
   - Docker, kubectl, Kind, Helm.
   - (Optional) NVIDIA GPU + drivers + nvidia-container-toolkit on the host.

3. **Create the cluster**
   - `kind create cluster --config gpu-kind.yaml` (multi-node example).
   - Show `gpu-kind.yaml` (control-plane + 2 workers).

4. **Install NVIDIA GPU Operator**
   - Add Helm repo: `nvidia/gpu-operator`.
   - Install in `gpu-operator` namespace; mention `driver.enabled=false` for “toolkit only” when driver is pre-installed.

5. **Deploy a GPU Pod**
   - Pod spec: `nvidia/cuda` image, `command: ["nvidia-smi"]`, `resources.limits: nvidia.com/gpu: 1`.
   - `kubectl apply -f gpu-pod.yaml` and `kubectl logs cuda-smi`.

6. **Extend with a fake ML endpoint**
   - Small app (e.g. Flask + PyTorch stub): `POST /infer` with tensor ops on CPU to mimic an inference pipeline.
   - Run locally or in-cluster; curl examples.

7. **What’s next**
   - vLLM / real inference (Project 6), custom operator (Project 7), webhooks (Project 8).

## CTA
Clone the repo, run `scripts/p5.sh`, then try the ML stub and the blog’s exact commands.
