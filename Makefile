.PHONY: help tf-init tf-plan tf-apply tf-destroy svc-build svc-run image-build image-push deploy-dev port-forward smoke

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---- Terraform ---- #
tf-init: ## Initialise Terraform
	cd terraform && terraform init

tf-plan: ## Show what Terraform will do
	cd terraform && terraform plan

tf-apply: ## Provision GCP infrastructure
	cd terraform && terraform apply

tf-destroy: ## Tear it all down (do this nightly!)
	cd terraform && terraform destroy

# ---- Customer service ---- #
svc-build: ## Build the customer-service JAR
	cd services/customer-service && mvn -B -ntp package

svc-run: ## Run the service locally against a local Postgres
	cd services/customer-service && mvn spring-boot:run

# ---- Docker / Artifact Registry ---- #
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
REGISTRY := asia-southeast1-docker.pkg.dev/$(PROJECT_ID)/bss-docker
TAG ?= dev

image-build: ## Build the customer-service container image
	docker build -t $(REGISTRY)/customer-service:$(TAG) services/customer-service

image-push: image-build ## Push image to Artifact Registry
	gcloud auth configure-docker asia-southeast1-docker.pkg.dev --quiet
	docker push $(REGISTRY)/customer-service:$(TAG)

# ---- Kubernetes ---- #
deploy-dev: ## Apply the dev overlay
	kubectl apply -k kubernetes/overlays/dev
	kubectl rollout status deployment/customer-service -n bss --timeout=5m

port-forward: ## Forward customer-service to localhost:8080
	kubectl port-forward -n bss svc/customer-service 8080:80

smoke: ## Smoke-test the deployed service
	@curl -sf http://localhost:8080/actuator/health | jq .status

# ---- Monitoring ---- #
monitoring-install: ## Install Prometheus + Grafana stack
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap bss-dashboards \
		--from-file=monitoring/grafana/dashboards/ \
		-n monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		-n monitoring -f monitoring/prometheus/values.yaml
	kubectl apply -f monitoring/alerts/bss-alerts.yaml

grafana: ## Open Grafana (port-forward)
	kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
