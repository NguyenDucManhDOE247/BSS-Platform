.PHONY: help bootstrap local-up local-down local-reset \
        tf-init tf-plan tf-apply tf-destroy \
        kube-config platform-install \
        ecr-login build push deploy set-image smoke grafana

ENV ?= dev
AWS_REGION ?= ap-southeast-1
ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECR_REGISTRY := $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
CLUSTER := bss-$(ENV)-eks
TAG ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
SERVICE ?= customer-service
SERVICE_DIR := $(shell test -d apps/backend/$(SERVICE) && echo apps/backend/$(SERVICE) || echo apps/frontend/$(SERVICE))

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ── One-time AWS bootstrap ────────────────────────────────────────────
bootstrap: ## One-time per-account: S3 tfstate + DynamoDB locks + budget alert
	./scripts/bootstrap-aws.sh

# ── Local dev stack ───────────────────────────────────────────────────
local-up: ## Start postgres + redis + LocalStack
	cd deploy && docker compose up -d

local-down: ## Stop local stack (keeps data)
	cd deploy && docker compose down

local-reset: ## Stop and WIPE local data
	cd deploy && docker compose down -v

# ── Terraform (ENV=dev|staging|prod) ──────────────────────────────────
tf-init: ## Initialize Terraform for $$ENV
	cd infrastructure/terraform/environments/$(ENV) && terraform init

tf-plan: ## Plan changes for $$ENV
	cd infrastructure/terraform/environments/$(ENV) && terraform plan

tf-apply: ## Provision/update $$ENV infrastructure
	cd infrastructure/terraform/environments/$(ENV) && terraform apply

tf-destroy: ## Tear down $$ENV (confirms on prod)
	./scripts/teardown.sh $(ENV)

# ── Kubernetes ────────────────────────────────────────────────────────
kube-config: ## Update local kubeconfig for $$ENV cluster
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(CLUSTER)

platform-install: ## Install ALB controller, ExternalDNS, Karpenter, CSI, Fluent Bit, OTel, Prometheus
	@echo "See platform/README.md for the full helm install sequence."

# ── Build + push (SERVICE=name) ───────────────────────────────────────
ecr-login: ## Log docker into ECR
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(ECR_REGISTRY)

build: ## Build container image for $$SERVICE (tag=git SHA)
	docker build -t $(ECR_REGISTRY)/bss/$(SERVICE):$(TAG) $(SERVICE_DIR)

push: ecr-login build ## Build + push $$SERVICE
	docker push $(ECR_REGISTRY)/bss/$(SERVICE):$(TAG)

# ── Deploy ────────────────────────────────────────────────────────────
set-image: ## Bump $$SERVICE image to $$TAG in $$ENV overlay
	cd infrastructure/kubernetes/overlays/$(ENV) && \
		kustomize edit set image $(SERVICE)=$(ECR_REGISTRY)/bss/$(SERVICE):$(TAG)

deploy: ## Apply $$ENV overlay (uses current image tags)
	kubectl apply -k infrastructure/kubernetes/overlays/$(ENV)
	kubectl -n bss rollout status deployment/$(SERVICE) --timeout=5m

smoke: ## Hit the $$ENV ALB and check basic responses
	./scripts/smoke.sh $(ENV)

grafana: ## Port-forward Grafana to localhost:3000
	kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
