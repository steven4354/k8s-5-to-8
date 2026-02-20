# Minimal Makefile for Project 7 operator (kubebuilder-style targets)
# Prereqs: kubebuilder, controller-gen optional; go build works without them.
GO ?= go
DOCKER ?= docker
IMAGE ?= inferencedeployment-operator:latest

.PHONY: build run install install-crd
build:
	$(GO) build -o bin/manager main.go

run: build
	./bin/manager

# Install CRD and run operator locally (assumes cluster and kubeconfig)
install-crd:
	kubectl apply -f config/crd/bases/ml.example.com_inferencedeployments.yaml

install: install-crd
	$(GO) build -o bin/manager main.go
	kubectl apply -f config/rbac/ 2>/dev/null || true
	./bin/manager

docker-build:
	$(DOCKER) build -t $(IMAGE) .

docker-push:
	$(DOCKER) push $(IMAGE)
