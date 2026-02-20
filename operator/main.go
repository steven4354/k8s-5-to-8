package main

import (
	"os"

	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	mlv1alpha1 "github.com/example/k8s-5-to-8-operator/api/v1alpha1"
	"github.com/example/k8s-5-to-8-operator/controllers"
)

func main() {
	utilruntime.Must(mlv1alpha1.SchemeBuilder.AddToScheme(clientgoscheme.Scheme))
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&zap.Options{Development: true})))
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{Scheme: clientgoscheme.Scheme})
	if err != nil {
		os.Exit(1)
	}
	if err = (&controllers.InferenceDeploymentReconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme()}).SetupWithManager(mgr); err != nil {
		os.Exit(1)
	}
	if err = mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		os.Exit(1)
	}
}
