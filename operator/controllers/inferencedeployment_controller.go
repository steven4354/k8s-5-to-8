package controllers

import (
	"context"
	"strconv"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	mlv1alpha1 "github.com/example/k8s-5-to-8-operator/api/v1alpha1"
)

// InferenceDeploymentReconciler reconciles InferenceDeployment CRs by creating/updating a Deployment and Service for vLLM.
type InferenceDeploymentReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

//+kubebuilder:rbac:groups=ml.example.com,resources=inferencedeployments,verbs=get;list;watch;create;update;patch;delete
//+kubebuilder:rbac:groups=ml.example.com,resources=inferencedeployments/status,verbs=get;update;patch
//+kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
//+kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete

func (r *InferenceDeploymentReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)
	var id mlv1alpha1.InferenceDeployment
	if err := r.Get(ctx, req.NamespacedName, &id); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	dep := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: id.Name, Namespace: id.Namespace},
	}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, dep, func() error {
		dep.Spec = appsv1.DeploymentSpec{
			Replicas: &id.Spec.Replicas,
			Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": id.Name}},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": id.Name}},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{{
						Name:  "vllm",
						Image: id.Spec.Image,
						Args:  []string{"--model=" + id.Spec.Model, "--host=0.0.0.0", "--port=" + strconv.Itoa(int(id.Spec.Port))},
						Ports: []corev1.ContainerPort{{ContainerPort: id.Spec.Port, Name: "http"}},
						Resources: id.Spec.Resources,
						ReadinessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromInt32(id.Spec.Port)}},
							InitialDelaySeconds: 60, PeriodSeconds: 10,
						},
					}},
					NodeSelector: id.Spec.NodeSelector,
				},
			},
		}
		if id.Spec.Resources.Requests == nil {
			dep.Spec.Template.Spec.Containers[0].Resources = corev1.ResourceRequirements{}
		}
		return ctrl.SetControllerReference(&id, dep, r.Scheme)
	})
	if err != nil {
		return ctrl.Result{}, err
	}
	logger.Info("deployment reconciled", "name", dep.Name)

	// Build Service
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: id.Name, Namespace: id.Namespace},
	}
	_, err = controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec = corev1.ServiceSpec{
			Selector: map[string]string{"app": id.Name},
			Ports:    []corev1.ServicePort{{Name: "http", Port: id.Spec.Port, TargetPort: intstr.FromInt32(id.Spec.Port)}},
		}
		return ctrl.SetControllerReference(&id, svc, r.Scheme)
	})
	if err != nil {
		return ctrl.Result{}, err
	}

	// Update status
	var list appsv1.DeploymentList
	if err := r.List(ctx, &list, client.InNamespace(id.Namespace), client.MatchingLabels{"app": id.Name}); err == nil && len(list.Items) > 0 {
		ready := list.Items[0].Status.ReadyReplicas
		id.Status.ReadyReplicas = ready
		if ready > 0 {
			id.Status.Phase = "Running"
		} else {
			id.Status.Phase = "Pending"
		}
	}
	if err := r.Status().Update(ctx, &id); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

func (r *InferenceDeploymentReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&mlv1alpha1.InferenceDeployment{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Complete(r)
}
