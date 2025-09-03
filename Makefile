# -----------------------------------------------------------------------------
# ESGBook Platform Engineer Exercise - Working Makefile (secure platform)
# Everything is reproducible from code (no manual kubectl/helm steps).
# -----------------------------------------------------------------------------

# ===== Variables =====
CLUSTER_NAME ?= esgbook-test-cluster-1
IMAGE := pingpong:latest

# ===== Phonies =====
.PHONY: cluster-up cluster-down build-services deploy cluster-up-with-services \        monitoring-up monitoring-down monitoring-apply \        https-up https-down render-ingress ingress-lb-up \        security-apply mkcert-install mkcert-ca-export issuer-mkcert-up \        render-ingress-127 ingress-tls-clean trusted-https-apply https-up-trusted \        grafana-url prometheus-url cluster-up-with-monitoring \        ingress-nodeport curl-b tls-status ingress-clean platform-up platform-up-trusted all

# ===== Cluster lifecycle =====
cluster-up:
	@echo "Starting Kubernetes cluster: $(CLUSTER_NAME)"
	minikube start -p $(CLUSTER_NAME)

cluster-down:
	@echo "Deleting Kubernetes cluster: $(CLUSTER_NAME)"
	minikube delete -p $(CLUSTER_NAME)

# ===== Build & Deploy app =====
build-services:
	@echo "Building services"
	docker build -t $(IMAGE) services/pingpong

deploy:
	@echo "Loading image into minikube and applying manifests"
	minikube image load $(IMAGE) -p $(CLUSTER_NAME)
	@echo "Cleaning up legacy Services in default namespace (namespace is immutable)"
	kubectl -n default delete svc pingpong-a --ignore-not-found
	kubectl -n default delete svc pingpong-b --ignore-not-found
	kubectl --context $(CLUSTER_NAME) apply -f infra/manifest.yaml
	@echo "Waiting for deployments to become Ready"
	-kubectl --context $(CLUSTER_NAME) -n pingpong-a rollout status deploy/pingpong-a --timeout=120s
	-kubectl --context $(CLUSTER_NAME) -n pingpong-b rollout status deploy/pingpong-b --timeout=120s
	@echo "Current pod status:"
	kubectl --context $(CLUSTER_NAME) -n pingpong-a get pods -o wide || true
	kubectl --context $(CLUSTER_NAME) -n pingpong-b get pods -o wide || true

cluster-up-with-services: cluster-up build-services deploy
	@echo "Cluster and services are up"

# ===== Monitoring stack (Prometheus Operator + Grafana) =====
monitoring-up:
	@echo "Installing kube-prometheus-stack in 'monitoring' namespace via Helm"
	kubectl create ns monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
	helm repo update
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring \
	  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
	  --set grafana.adminPassword=admin \
	  --set grafana.service.type=NodePort \
	  --set grafana.service.nodePort=30000

monitoring-down:
	@echo "Uninstalling monitoring stack"
	helm uninstall monitoring -n monitoring || true
	kubectl delete ns monitoring --ignore-not-found

monitoring-apply:
	@echo "Applying ServiceMonitors and metrics Services"
	kubectl apply -f infra/monitoring.yaml

cluster-up-with-monitoring: cluster-up-with-services monitoring-up monitoring-apply
	@echo "Cluster, services and monitoring are up"

# ===== HTTPS via ingress-nginx + cert-manager (NodePort + self-signed) =====
render-ingress:
	@echo "Rendering Ingress with MINIKUBE_IP using sslip.io"
	@mkdir -p infra/generated
	@MINIKUBE_IP="$$(minikube ip -p $(CLUSTER_NAME) 2>/dev/null || echo 127.0.0.1)"; \
	echo "Using MINIKUBE_IP=$${MINIKUBE_IP}"; \
	sed "s|\$${MINIKUBE_IP}|$${MINIKUBE_IP}|g" infra/ingress-tls.yaml.tmpl > infra/generated/ingress-tls.yaml; \
	test -s infra/generated/ingress-tls.yaml && echo "Rendered to infra/generated/ingress-tls.yaml"

https-up: render-ingress
	@echo "Installing ingress-nginx (NodePort) and cert-manager"
	kubectl create ns ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
	helm repo update
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
	  --set controller.service.type=NodePort
	helm repo add jetstack https://charts.jetstack.io || true
	helm repo update
	helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
	  --set crds.enabled=true
	kubectl apply -f infra/cert-manager-issuer.yaml
	kubectl apply -f infra/generated/ingress-tls.yaml

https-down:
	-helm uninstall ingress-nginx -n ingress-nginx || true
	-kubectl delete ns ingress-nginx --ignore-not-found
	-helm uninstall cert-manager -n cert-manager || true
	-kubectl delete ns cert-manager --ignore-not-found

tunnel-up:
	@echo "[tunnel] starting minikube tunnel for $(CLUSTER_NAME) in background"
	@if pgrep -f "minikube tunnel -p $(CLUSTER_NAME)" >/dev/null; then \
	  echo "[tunnel] already running"; \
	else \
	  if sudo -n true 2>/dev/null; then \
	    sudo -n minikube tunnel -p $(CLUSTER_NAME) >/tmp/minikube-tunnel-$(CLUSTER_NAME).log 2>&1 & \
	    echo $$! > .minikube_tunnel.pid; \
	    echo "[tunnel] started (pid $$(cat .minikube_tunnel.pid))"; \
	  else \
	    echo "[tunnel] sudo needs a password. Please run this once in another terminal:"; \
	    echo "    sudo minikube tunnel -p $(CLUSTER_NAME)"; \
	    exit 1; \
	  fi; \
	fi

tunnel-down:
	@echo "[tunnel] stopping minikube tunnel if running"
	@if [ -f .minikube_tunnel.pid ]; then \
	  kill "$$(cat .minikube_tunnel.pid)" 2>/dev/null || true; \
	  rm -f .minikube_tunnel.pid; \
	fi
	- pkill -f "minikube tunnel -p $(CLUSTER_NAME)" || true

# ================= Trusted HTTPS end-to-end (Chrome & Firefox, macOS) =================
# 0) Ensure ingress-nginx is a LoadBalancer (EXTERNAL-IP 127.0.0.1 on minikube with tunnel or directly on mac)
ingress-lb-up:
	@echo "[ingress] installing ingress-nginx as LoadBalancer"
	kubectl create ns ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
	helm repo update
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
	  --set controller.service.type=LoadBalancer
	@echo "[ingress] status:"
	kubectl -n ingress-nginx get svc ingress-nginx-controller

# 1) Install mkcert + NSS and trust CA in macOS Keychain & Firefox (Chrome uses Keychain)
mkcert-install:
	@echo "[mkcert] installing & trusting local CA (Chrome + Firefox)"
	@if ! command -v brew >/dev/null 2>&1; then echo "Homebrew not found. Install it from https://brew.sh"; exit 1; fi
	@brew list mkcert >/dev/null 2>&1 || brew install mkcert
	@brew list nss >/dev/null 2>&1 || brew install nss
	mkcert -install
	@echo "[mkcert] CAROOT=$$(mkcert -CAROOT)"

# 2) Export mkcert CA (root keypair) to Kubernetes as a secret for cert-manager
mkcert-ca-export:
	@echo "[mkcert] exporting CA to Kubernetes (cert-manager/mkcert-ca-secret)"
	@CAROOT="$$(mkcert -CAROOT)"; \
	kubectl create ns cert-manager --dry-run=client -o yaml | kubectl apply -f -; \
	kubectl -n cert-manager delete secret mkcert-ca-secret --ignore-not-found; \
	kubectl -n cert-manager create secret tls mkcert-ca-secret \
	  --cert="$$CAROOT/rootCA.pem" --key="$$CAROOT/rootCA-key.pem"

# 3) Create ClusterIssuer that uses mkcert CA
issuer-mkcert-up:
	@echo "[issuer] applying mkcert ClusterIssuer"
	kubectl apply -f infra/mkcert-cluster-issuer.yaml

# 4) Render an ingress file that uses 127.0.0.1.sslip.io (matches LB EXTERNAL-IP=127.0.0.1)
render-ingress-127:
	@echo "[ingress] rendering for 127.0.0.1.sslip.io"
	@mkdir -p infra/generated
	@sed 's/$${MINIKUBE_IP}/127.0.0.1/g' infra/ingress-tls.yaml.tmpl > infra/generated/ingress-127.tmpl.yaml
	@sed 's/selfsigned-cluster-issuer/mkcert-cluster-issuer/g' infra/generated/ingress-127.tmpl.yaml > infra/generated/ingress-127.trusted.yaml
	@echo "[ingress] output: infra/generated/ingress-127.trusted.yaml"

# 5) Clean any conflicting certs/secrets (avoids “conflicting Certificates” condition)
ingress-tls-clean:
	- kubectl -n pingpong-a delete certificate pingpong-a-cert secret pingpong-a-tls --ignore-not-found
	- kubectl -n pingpong-b delete certificate pingpong-b-cert secret pingpong-b-tls --ignore-not-found

# 6) Apply trusted ingress (TLS from mkcert ClusterIssuer)
trusted-https-apply:
	kubectl apply -f infra/generated/ingress-127.trusted.yaml
	@echo "[ingress] waiting for certs to be Ready"
	- kubectl -n pingpong-a wait --for=condition=Ready certificate/pingpong-a-cert --timeout=120s
	- kubectl -n pingpong-b wait --for=condition=Ready certificate/pingpong-b-cert --timeout=120s
	kubectl -n pingpong-a get certificate,secret | egrep 'pingpong-a-(cert|tls)' || true
	kubectl -n pingpong-b get certificate,secret | egrep 'pingpong-b-(cert|tls)' || true
	kubectl get ingress -A

# One-click: bring up trusted HTTPS end-to-end
https-up-trusted: ingress-lb-up mkcert-install mkcert-ca-export issuer-mkcert-up render-ingress-127 ingress-tls-clean trusted-https-apply
	@echo ""
	@echo "✅ Trusted HTTPS applied. Open these:"
	@echo "   https://pingpong-a.127.0.0.1.sslip.io/ping"
	@echo "   https://pingpong-b.127.0.0.1.sslip.io/ping"

# ===== Security posture (NetworkPolicies) =====
security-apply:
	@echo "Applying NetworkPolicies for pingpong namespaces"
	kubectl apply -f infra/security.yaml

# ===== cert-manager + trust-manager prerequisites =====
mesh-prereqs:
	@echo "Installing cert-manager and trust-manager via Helm"
	helm repo add jetstack https://charts.jetstack.io || true
	helm repo update
	kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager \
	  --set installCRDs=true --wait
	helm upgrade --install trust-manager jetstack/trust-manager -n cert-manager --wait

# Create trust anchor + identity issuer using cert-manager and fetch files for Helm
mesh-bootstrap-ca:
	@echo "Applying cert-manager issuers/certificates for Linkerd"
	kubectl apply -f infra/mesh/cert-manager/issuers-and-certs.yaml
	@echo "Forcing re-issuance by deleting old Secrets (if exist)"
	kubectl -n linkerd delete secret linkerd-identity-issuer linkerd-trust-anchor --ignore-not-found
	@echo "Applying trust-manager Bundle (optional)"
	kubectl apply -f infra/mesh/cert-manager/trust-bundle.yaml || true
	@echo "Waiting for trust anchor secret..."
	kubectl -n linkerd wait --for=condition=Ready certificate/linkerd-trust-anchor --timeout=120s
	kubectl -n linkerd wait --for=condition=Ready certificate/linkerd-identity-issuer --timeout=180s
	@echo "Exporting certs to files for Helm (--set-file)"
	mkdir -p infra/mesh/certs
	kubectl -n linkerd get secret linkerd-trust-anchor -o jsonpath='{.data.ca\.crt}' | base64 -d > infra/mesh/certs/ca.crt
	kubectl -n linkerd get secret linkerd-identity-issuer -o jsonpath='{.data.tls\.crt}' | base64 -d > infra/mesh/certs/issuer.crt
	kubectl -n linkerd get secret linkerd-identity-issuer -o jsonpath='{.data.tls\.key}' | base64 -d > infra/mesh/certs/issuer.key

# (Re)install Linkerd with certs coming from cert-manager
mesh-up: ## installs CRDs + control plane with mTLS policy default
	@echo "Installing Linkerd (CRDs + control-plane) via Helm"
	helm repo add linkerd https://helm.linkerd.io/stable || true
	helm repo update
	kubectl create namespace linkerd --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install linkerd-crds linkerd/linkerd-crds -n linkerd --wait
	@echo "Adopting cert-manager Secret so Helm can use it (labels/annotations)"; \
	kubectl -n linkerd label secret linkerd-identity-issuer app.kubernetes.io/managed-by=Helm --overwrite || true; \
	kubectl -n linkerd annotate secret linkerd-identity-issuer meta.helm.sh/release-name=linkerd-control-plane --overwrite || true; \
	kubectl -n linkerd annotate secret linkerd-identity-issuer meta.helm.sh/release-namespace=linkerd --overwrite || true
	helm upgrade --install linkerd-control-plane linkerd/linkerd-control-plane -n linkerd \
	  --values infra/mesh/linkerd-values.yaml \
	  --set-file identityTrustAnchorsPEM=infra/mesh/certs/ca.crt \
	  --set-file identity.issuer.tls.crtPEM=infra/mesh/certs/issuer.crt \
	  --set-file identity.issuer.tls.keyPEM=infra/mesh/certs/issuer.key \
	  --wait
	@echo "Linkerd installed. Default inbound policy: all-authenticated (require mTLS)."

# ===== Convenience targets to keep it simple =====
mesh-health:
	@echo "Waiting for Linkerd control-plane to be Ready..."
	kubectl -n linkerd wait deploy --all --for=condition=Available --timeout=180s || true
	@echo "Checking Ready pods:"
	kubectl -n linkerd get pods -o wide
	@echo "Checking pingpong namespaces:"
	kubectl -n pingpong-a get pods || true
	kubectl -n pingpong-b get pods || true

mesh-all:
	@echo ">>> Installing prerequisites, bootstrapping certs, installing Linkerd, and applying namespaces (one go)"
	$(MAKE) mesh-prereqs
	$(MAKE) mesh-bootstrap-ca
	$(MAKE) mesh-up
	$(MAKE) mesh-health
	@echo ">>> Done. Try: make mesh-test"

mesh-reset:
	@echo ">>> Nuking Linkerd and cert-manager to start fresh (safe in dev)"
	-helm uninstall linkerd-control-plane -n linkerd || true
	-helm uninstall linkerd-crds -n linkerd || true
	-kubectl delete ns linkerd --ignore-not-found
	-helm uninstall cert-manager -n cert-manager || true
	-helm uninstall trust-manager -n cert-manager || true
	-kubectl delete ns cert-manager --ignore-not-found
	@echo "Cleaning exported cert files"
	-rm -f infra/mesh/certs/ca.crt infra/mesh/certs/issuer.crt infra/mesh/certs/issuer.key infra/mesh/certs/*.cnf || true
	@echo ">>> Reset complete. Recreate everything with: make mesh-all"


# --- HPAs ---
hpa-apply:
	kubectl apply -f infra/hpa/hpa.yaml

# --- Probes & Resources ---
deploy-overrides-apply:
	kubectl apply -f infra/overrides/deployments-with-probes.yaml

# --- Pod Security Admission ---
psa-apply:
	kubectl apply -f infra/security/pod-security-labels.yaml
# ===== Helpers =====
grafana-url:
	@echo "Opening Grafana URL (NodePort 30000). Login user: admin"
	minikube -p $(CLUSTER_NAME) service -n monitoring monitoring-grafana --url

prometheus-url:
	@echo "Port-forwarding Prometheus to http://localhost:9090"
	kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090

grafana-ingress-up:
	@echo "[grafana] applying trusted HTTPS ingress (grafana.127.0.0.1.sslip.io)"
	kubectl apply -f infra/grafana-ingress-127.yaml
	@kubectl -n monitoring wait --for=condition=Ready certificate/grafana-cert --timeout=120s || true
	kubectl -n monitoring get ingress grafana
	@echo "Open: https://grafana.127.0.0.1.sslip.io/"

ingress-nodeport:
	@kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
	@echo -n "443 nodePort: "; kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}'; echo

curl-b:
	@MINIKUBE_IP="$$(minikube ip -p $${CLUSTER_NAME:-esgbook-test-cluster-1})"; \
	NODEPORT="$$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')"; \
	echo "curling https://pingpong-b.$$MINIKUBE_IP.sslip.io:$$NODEPORT/ping"; \
	curl -vk --resolve "pingpong-b.$$MINIKUBE_IP.sslip.io:$$NODEPORT:$$MINIKUBE_IP" \
	  "https://pingpong-b.$$MINIKUBE_IP.sslip.io:$$NODEPORT/ping"

tls-status:
	kubectl -n pingpong-a get certificate,secret | egrep 'pingpong-a-(cert|tls)' || true
	kubectl -n pingpong-b get certificate,secret | egrep 'pingpong-b-(cert|tls)' || true

ingress-clean:
	- kubectl -n pingpong-a delete ingress pingpong-a --ignore-not-found
	- kubectl -n pingpong-b delete ingress pingpong-b --ignore-not-found

# ===== One-shot secure platform =====
platform-up: cluster-up build-services deploy monitoring-up monitoring-apply https-up 
	@echo "Platform is up with HTTPS (self-signed), metrics and network policies"

# Variant: platform with trusted HTTPS (Chrome/Firefox without warnings)
platform-up-trusted: https-up https-up-trusted security-apply grafana-ingress-up mesh-all
	@echo "Platform is up with trusted HTTPS, metrics and network policies"

# Default target
all: platform-up

