package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// InferenceDeploymentSpec defines the desired state of InferenceDeployment
type InferenceDeploymentSpec struct {
	Replicas  int32              `json:"replicas"`
	Model     string             `json:"model"`
	Image     string             `json:"image"`
	Port      int32              `json:"port"`
	Resources corev1.ResourceRequirements `json:"resources,omitempty"`
	NodeSelector map[string]string `json:"nodeSelector,omitempty"`
}

// InferenceDeploymentStatus defines the observed state of InferenceDeployment
type InferenceDeploymentStatus struct {
	ReadyReplicas int32  `json:"readyReplicas,omitempty"`
	Phase         string `json:"phase,omitempty"` // Pending, Running, Failed
}

//+kubebuilder:object:root=true
//+kubebuilder:subresource:status
//+kubebuilder:resource:scope=Namespaced

type InferenceDeployment struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec   InferenceDeploymentSpec   `json:"spec,omitempty"`
	Status InferenceDeploymentStatus `json:"status,omitempty"`
}

//+kubebuilder:object:root=true

type InferenceDeploymentList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []InferenceDeployment `json:"items"`
}

func init() {
	SchemeBuilder.Register(&InferenceDeployment{}, &InferenceDeploymentList{})
}
