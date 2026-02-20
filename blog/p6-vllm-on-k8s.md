# Blog outline: vLLM on K8s — Production Inference Fleet

## Audience
Engineers who want to serve LLMs (e.g. Llama) on Kubernetes with vLLM, with a path to scaling and observability.

## Sections

1. **Why vLLM on Kubernetes**
   - High throughput, PagedAttention, OpenAI-compatible API; K8s gives scaling, resource limits, and placement.

2. **Prerequisites**
   - GPU cluster (Kind with GPU or cloud); enough VRAM for target model (e.g. 7B ~24GB).

3. **Model storage: Hugging Face cache PVC**
   - Create a PVC and mount at `HUGGING_FACE_HUB_CACHE` so models are persisted across restarts.
   - Optional: use ReadWriteMany for multi-replica shared cache.

4. **Deploy vLLM**
   - Deployment: `vllm/vllm-openai` (or official vLLM image), `--model`, `--host`, `--port`.
   - Service on port 8000; readiness/liveness on `/health`.
   - Resource requests/limits: GPU + memory.

5. **Autoscaling**
   - HPA on CPU for demo; in production use custom metrics (e.g. Prometheus queue length or request latency) and KEDA or Prometheus Adapter.

6. **Test: /generate and model warmup**
   - Call `GET /health` for warmup probe.
   - Call `POST /v1/completions` (or `/generate`) with model name and prompt; show curl example.

7. **Production stack (optional)**
   - Point to vLLM docs: production stack (Helm, model-aware routing, observability).

## CTA
Apply the repo’s `k8s/06-vllm/*.yaml`, run `scripts/p6.sh`, then hit the /generate API.

## References
- [vLLM Kubernetes deployment](https://docs.vllm.ai/en/stable/deployment/k8s.html)
- [vLLM production stack](https://docs.vllm.ai/en/stable/deployment/integrations/production-stack/)
