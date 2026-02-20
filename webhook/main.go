// Project 8: Mutating + Validating webhook for GPU pods.
// Mutating: inject a logging sidecar into pods that request nvidia.com/gpu.
// Validating: reject pods that request more than 1 GPU.
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/runtime/serializer"
)

var (
	runtimeScheme = runtime.NewScheme()
	codecs        = serializer.NewCodecFactory(runtimeScheme)
	deserializer  = codecs.UniversalDeserializer()
)

func init() {
	_ = corev1.AddToScheme(runtimeScheme)
	_ = admissionv1.AddToScheme(runtimeScheme)
}

func main() {
	http.HandleFunc("/mutate", mutate)
	http.HandleFunc("/validate", validate)
	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	port := os.Getenv("PORT")
	if port == "" {
		port = "8443"
	}
	fmt.Println("Webhook server listening on :" + port)
	panic(http.ListenAndServeTLS(":"+port, "/tls/tls.crt", "/tls/tls.key", nil))
}

func mutate(w http.ResponseWriter, r *http.Request) {
	ar := readAdmissionReview(r, w)
	if ar == nil {
		return
	}
	pod := &corev1.Pod{}
	if _, _, err := deserializer.Decode(ar.Request.Object.Raw, nil, pod); err != nil {
		replyAdmission(w, ar.Request.UID, false, err.Error())
		return
	}
	// Inject sidecar only if pod requests GPU
	inject := false
	for _, c := range pod.Spec.Containers {
		if c.Resources.Limits["nvidia.com/gpu"] != (resource.Quantity{}) || c.Resources.Requests["nvidia.com/gpu"] != (resource.Quantity{}) {
			inject = true
			break
		}
	}
	if inject {
		pod.Spec.Containers = append(pod.Spec.Containers, corev1.Container{
			Name:  "gpu-log-sidecar",
			Image: "busybox:1.36",
			Command: []string{"sh", "-c", "echo 'GPU pod sidecar' && sleep 86400"},
		})
	}
	patch, _ := json.Marshal([]map[string]interface{}{
		{"op": "replace", "path": "/spec/containers", "value": pod.Spec.Containers},
	})
	replyAdmissionPatch(w, ar.Request.UID, patch)
}

func validate(w http.ResponseWriter, r *http.Request) {
	ar := readAdmissionReview(r, w)
	if ar == nil {
		return
	}
	pod := &corev1.Pod{}
	if _, _, err := deserializer.Decode(ar.Request.Object.Raw, nil, pod); err != nil {
		replyAdmission(w, ar.Request.UID, false, err.Error())
		return
	}
	for _, c := range pod.Spec.Containers {
		lim := c.Resources.Limits["nvidia.com/gpu"]
		req := c.Resources.Requests["nvidia.com/gpu"]
		if lim.Cmp(resource.MustParse("1")) > 0 || req.Cmp(resource.MustParse("1")) > 0 {
			replyAdmission(w, ar.Request.UID, false, "reject: max 1 nvidia.com/gpu per pod")
			return
		}
	}
	replyAdmission(w, ar.Request.UID, true, "")
}

func readAdmissionReview(r *http.Request, w http.ResponseWriter) *admissionv1.AdmissionReview {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return nil
	}
	var ar admissionv1.AdmissionReview
	if _, _, err := deserializer.Decode(r.Body, nil, &ar); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return nil
	}
	if ar.Request == nil {
		http.Error(w, "empty request", http.StatusBadRequest)
		return nil
	}
	return &ar
}

func replyAdmission(w http.ResponseWriter, uid types.UID, allowed bool, msg string) {
	ar := admissionv1.AdmissionReview{
		Response: &admissionv1.AdmissionResponse{
			UID:     uid,
			Allowed: allowed,
			Result:  &metav1.Status{Message: msg},
		},
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(ar)
}

func replyAdmissionPatch(w http.ResponseWriter, uid types.UID, patch []byte) {
	pt := admissionv1.PatchTypeJSONPatch
	ar := admissionv1.AdmissionReview{
		Response: &admissionv1.AdmissionResponse{
			UID:       uid,
			Allowed:   true,
			Patch:     patch,
			PatchType: &pt,
		},
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(ar)
}
