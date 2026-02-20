# Blog outline: Webhooks + Upgrades — Secure AI Clusters

## Audience
Platform engineers who want to enforce policies on GPU pods (e.g. cap GPUs per pod, inject sidecars) and run a safe control-plane upgrade on a Kind or kubeadm cluster.

## Sections

1. **Why webhooks for AI workloads**
   - Mutating: inject sidecars (logging, monitoring) into every GPU pod.
   - Validating: reject invalid specs (e.g. >1 GPU per pod to avoid oversubscription).

2. **Prerequisites**
   - Cluster (Kind or kubeadm), cert-manager, Go (to build webhook server).

3. **Implement the webhook server (Go)**
   - HTTP server with TLS; serve `/mutate` and `/validate`.
   - Decode `AdmissionReview`, extract Pod; for mutate: add a sidecar if `nvidia.com/gpu` is requested; for validate: reject if any container requests >1 GPU.
   - Return `AdmissionResponse` (allowed/rejected, optional patch for mutate).

4. **Deploy the webhook**
   - Build image and deploy as Deployment + Service in a dedicated namespace.
   - Use cert-manager to issue a TLS cert (e.g. self-signed or internal CA) and mount it in the pod.
   - Register `ValidatingWebhookConfiguration` and `MutatingWebhookConfiguration` with `clientConfig.service` and `caBundle` (from the cert secret).

5. **Test**
   - Create a pod with `nvidia.com/gpu: 1` → allowed and sidecar present.
   - Create a pod with `nvidia.com/gpu: 2` → rejected.

6. **Cluster lifecycle: simulate upgrade**
   - Kind: document that “upgrade” usually means create a new cluster with a newer image; for real in-place upgrade, use kubeadm.
   - Kubeadm: drain nodes, upgrade control-plane (kubeadm upgrade apply), then workers (kubeadm upgrade node; kubelet restart); uncordon. Emphasize drain/uncordon and backup.

7. **What’s next**
   - Policy engines (OPA/Gatekeeper), more webhook rules, upgrade automation.

## CTA
Run `scripts/p8.sh`, then apply the 1-GPU and 2-GPU test pods; confirm allow vs reject and sidecar injection.

## References
- Kubernetes [Admission Webhooks](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#validatingadmissionwebhook)
- [cert-manager](https://cert-manager.io/)
- Kind / kubeadm upgrade docs
