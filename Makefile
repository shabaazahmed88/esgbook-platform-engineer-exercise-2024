REQUIRED_BIN := kubectl minikube docker
$(foreach bin,$(REQUIRED_BIN),\
    $(if $(shell command -v $(bin) 2> /dev/null),,$(error Please install `$(bin)`)))

CLUSTER_NAME := esgbook-test-cluster-1

cluster-up: cluster-down
	@echo "Creating new Kubernetes cluster=${CLUSTER_NAME}"
	minikube start -p ${CLUSTER_NAME}

cluster-down:
	@echo "Deleting existing Kubernetes cluster=${CLUSTER_NAME}"
	minikube delete -p ${CLUSTER_NAME}

build-services:
	@echo "Building services"
	docker build -t pinger:latest services/pingpong

cluster-up-with-services: cluster-up build-services
	@echo "Deploying services to Kubernetes cluster=${CLUSTER_NAME}"
	minikube image load pingpong:latest -p ${CLUSTER_NAME}
	kubectl --context ${CLUSTER_NAME} apply -f infra/manifest.yaml
