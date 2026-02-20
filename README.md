## k8s-5-to-8 (GPU + AI)

A continuation of `k8s-1-to-4`, focusing on **GPU workloads**, **LLM inference**, **custom operators**, and **admission webhooks**.

- **P5**: Kind + NVIDIA GPU Operator + CUDA Pod (`nvidia-smi`)
- **P6**: vLLM Deployment + Service + autoscaling
- **P7**: `InferenceDeployment` CRD + Operator (Kubebuilder) managing vLLM fleets
- **P8**: Mutating/validating webhooks + simulated cluster upgrade

---

## Lambda Labs

A10
No filesystem attachment
Any region

---

## System requirements

Everything from `k8s-1-to-4` **plus**:

- **Kind** (Kubernetes in Docker, multi-node)
- **Helm 3**
- **NVIDIA GPU on host** with recent drivers (for real GPU tests)
- **kubebuilder** (for Project 7)
- **Go 1.22+** (for operator + webhooks)
- **cert-manager** (installed into the kind cluster for webhooks in P8)

> Note: Projects 5–8 are designed to run on **Kind** instead of Minikube, to better mirror “real” multi-node clusters and GPU scheduling.

---

## Project 5: GPU Workloads (Inference Stub)

Goal: **Run a GPU-enabled Pod** on a local Kind cluster using the **NVIDIA GPU Operator**, and expose a fake ML endpoint.

High level:

- `gpu-kind.yaml`: Multi-node Kind cluster config with one GPU-capable worker.
- `scripts/p5.sh`:
  - `kind create cluster --config k8s/05-gpu/gpu-kind.yaml`
  - Install NVIDIA GPU Operator via Helm.
  - Deploy a Pod using `nvidia/cuda` image requesting `nvidia.com/gpu: 1`.
  - Run `nvidia-smi` to prove GPU is wired up.
- Extend the app with a **fake ML endpoint**:
  - Simple HTTP server (Node or Python) with a `/infer` route.
  - Uses a tiny **torch stub** (CPU tensor ops only) to mimic an inference pipeline.

See:

- `k8s/05-gpu/gpu-kind.yaml`
- `k8s/05-gpu/gpu-pod.yaml`
- `scripts/p5.sh`
- `ml-stub/` — fake ML app (Flask + PyTorch stub, `POST /infer`)
- `blog/p5-gpu-pods-on-kind.md`

---

## Project 6: vLLM Inference Serving

Goal: **Serve an LLM with vLLM** on Kubernetes, with a basic autoscaling story.

High level:

- `k8s/06-vllm/vllm-pvc.yaml`: PVC for the Hugging Face cache/model.
- `k8s/06-vllm/vllm-deployment.yaml`: vLLM server, GPU-enabled, exposes port `8000`.
- `k8s/06-vllm/vllm-service.yaml`: ClusterIP `Service` for vLLM.
- `k8s/06-vllm/vllm-hpa.yaml`: HPA scaling on CPU (or placeholder for queue length via Prometheus).
- `scripts/p6.sh`:
  - Assumes Project 5’s GPU cluster (or another GPU-enabled cluster) is up.
  - Applies vLLM manifests.
  - Waits for model warmup.
  - Sends `/generate` test requests.

See:

- `k8s/06-vllm/*.yaml`
- `scripts/p6.sh`
- `blog/p6-vllm-on-k8s.md`

Sources:

- vLLM docs (`https://docs.vllm.ai`), especially **Kubernetes** and **production stack** sections.

---

## Project 7: Custom Operator for Model Deploys

Goal: Build a **Kubebuilder operator** that manages vLLM Deployments via a custom resource: `InferenceDeployment`.

High level:

- `api/v1alpha1/inferencedeployment_types.go`: CRD Go type.
- `controllers/inferencedeployment_controller.go`: Reconciler that:
  - Watches `InferenceDeployment` resources.
  - Creates/updates a GPU `Deployment` + `Service` for vLLM.
  - Optionally manages an HPA.
- `config/crd/bases/ml.example.com_inferencedeployments.yaml`: Generated CRD YAML.
- `examples/07-operator/inferencedeployment-sample.yaml`: Example CR instance.
- `scripts/p7.sh`:
  - Runs `make docker-build` and `make deploy` (kubebuilder defaults).
  - Applies the sample `InferenceDeployment`.

See:

- `k8s/07-operator/` (CR + example)
- `blog/p7-operator-for-ai-fleets.md`

Sources:

- Kubebuilder Book (`https://book.kubebuilder.io/`)
- Sample controllers (`https://github.com/kubernetes-sigs/kubebuilder-declarative-pattern`)

---

## Project 8: Webhooks & Cluster Lifecycle

Goal: Add **mutating + validating webhooks** for GPU Pods, and simulate a basic **cluster upgrade** flow.

High level:

- Go webhook server:
  - Mutating webhook: injects a logging sidecar into AI Pods.
  - Validating webhook: rejects Pods requesting more than 1 GPU.
- `k8s/08-webhooks/`:
  - Deployment + Service for webhook server.
  - `ValidatingWebhookConfiguration` + `MutatingWebhookConfiguration`.
  - `Issuer` / `Certificate` resources for cert-manager.
- `scripts/p8.sh`:
  - Installs cert-manager (if not present).
  - Deploys webhook stack.
  - Demonstrates:
    - A Pod that gets a sidecar injected.
    - A Pod with `nvidia.com/gpu: 2` being rejected.
  - Sketches a Kind control-plane upgrade using `kind` + `kubeadm` docs (no destructive steps).

See:

- `k8s/08-webhooks/*.yaml`
- `blog/p8-webhooks-and-upgrades.md`

Sources:

- Kubernetes admission webhooks docs.
- cert-manager docs.
- Kind cluster lifecycle / upgrade docs.

---

## Blog outlines

Each project has a blog outline in `blog/`:

- P5: `blog/p5-gpu-pods-on-kind.md` — **“GPU Pods on Local K8s: AI Ready in 10 min.”**
- P6: `blog/p6-vllm-on-k8s.md` — **“vLLM on K8s: Production Inference Fleet.”**
- P7: `blog/p7-operator-for-ai-fleets.md` — **“Operator in 1hr: Reconcile AI Fleets.”**
- P8: `blog/p8-webhooks-and-upgrades.md` — **“Webhooks + Upgrades: Secure AI Clusters.”**

These outlines are structured so you can turn each into a full tutorial post.

