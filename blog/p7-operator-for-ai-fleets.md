# Blog outline: Operator in 1hr — Reconcile AI Fleets

## Audience
Developers who want to build a custom Kubernetes operator that manages vLLM (or similar) inference deployments via a CRD, in about an hour.

## Sections

1. **Why an operator for model deploys**
   - One CR = one vLLM Deployment + Service (+ optional HPA). Reconcile on create/update/delete; node affinity for GPUs.

2. **Prerequisites**
   - Go 1.22+, kubebuilder (or hand-written CRD), cluster with GPU nodes for vLLM.

3. **Scaffold with Kubebuilder**
   - `kubebuilder init --domain example.com`
   - `kubebuilder create api --group ml --version v1alpha1 --kind InferenceDeployment`
   - Define spec (replicas, model, image, port, resources, nodeSelector) and status (readyReplicas, phase).

4. **Implement the reconciler**
   - Watch InferenceDeployment; on event, create or update a Deployment (vLLM container args, probes, resources) and a Service.
   - Set controller reference so garbage collection removes children when CR is deleted.
   - Update status from Deployment’s ReadyReplicas.

5. **Install and test**
   - Install CRD: `kubectl apply -f config/crd/bases/`
   - Run operator: `make run` or deploy as Deployment in cluster.
   - Apply sample CR YAML; verify Deployment and Service are created; scale replicas and check node affinity.

6. **Extend (optional)**
   - HPA from the operator; PVC for model cache; status conditions.

## CTA
Use the repo’s `operator/` and `k8s/07-operator/inferencedeployment-sample.yaml`; run `scripts/p7.sh` and then scale or edit the CR.

## References
- [Kubebuilder Book](https://book.kubebuilder.io/)
- [kubebuilder-declarative-pattern](https://github.com/kubernetes-sigs/kubebuilder-declarative-pattern)
