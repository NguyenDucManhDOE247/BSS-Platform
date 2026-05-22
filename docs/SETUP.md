# Setup Guide

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| `gcloud` | latest | https://cloud.google.com/sdk/docs/install |
| `terraform` | ≥ 1.7 | `brew install terraform` / `choco install terraform` |
| `kubectl` | ≥ 1.29 | `gcloud components install kubectl` |
| `kustomize` | ≥ 5.0 | bundled with `kubectl` |
| `helm` | ≥ 3.14 | https://helm.sh/docs/intro/install/ |
| `docker` | ≥ 24 | https://docs.docker.com/engine/install/ |
| JDK | 21 | https://adoptium.net |
| Maven | ≥ 3.9 | https://maven.apache.org/install.html |

You also need a **GCP project with billing enabled**. The free tier won't cover GKE — expect to spend ~$5–10/day for a learning cluster (instructions for tearing down are below).

## One-time GCP bootstrap

```bash
# 1. Authenticate
gcloud auth login
gcloud auth application-default login

# 2. Set the active project
export PROJECT_ID="bss-learning-$(date +%s)"
gcloud projects create "$PROJECT_ID"
gcloud config set project "$PROJECT_ID"

# 3. Link billing (replace with your billing account ID)
gcloud beta billing accounts list
gcloud beta billing projects link "$PROJECT_ID" --billing-account=XXXXXX-XXXXXX-XXXXXX

# 4. (Optional but recommended) create the Terraform state bucket
gsutil mb -l asia-southeast1 "gs://${PROJECT_ID}-tfstate"
gsutil versioning set on "gs://${PROJECT_ID}-tfstate"
# Then uncomment the backend "gcs" block in terraform/main.tf and update the bucket name.
```

## Deploy infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set project_id and authorized_networks (your public IP)

terraform init
terraform plan        # always read the plan before applying
terraform apply
```

This takes 10–15 minutes the first time. Most of it is GKE provisioning.

## Connect kubectl

```bash
# The exact command is printed by `terraform output gcloud_get_credentials_command`
gcloud container clusters get-credentials bss-cluster \
  --region asia-southeast1 \
  --project "$PROJECT_ID"

kubectl get nodes  # confirm you can reach the cluster
```

## Deploy the monitoring stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

# Create the dashboard ConfigMap before installing the chart
kubectl create configmap bss-dashboards \
  --from-file=monitoring/grafana/dashboards/ \
  -n monitoring

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f monitoring/prometheus/values.yaml

kubectl apply -f monitoring/alerts/bss-alerts.yaml
```

## Deploy the customer service

```bash
# 1. Build and push the image (or let CI do it)
REGISTRY="asia-southeast1-docker.pkg.dev/${PROJECT_ID}/bss-docker"
docker build -t "${REGISTRY}/customer-service:dev" services/customer-service
gcloud auth configure-docker asia-southeast1-docker.pkg.dev
docker push "${REGISTRY}/customer-service:dev"

# 2. Update the dev overlay with your project_id and Cloud SQL private IP
#    (sed -i works on Linux; macOS users need sed -i '')
SQL_IP=$(cd terraform && terraform output -raw sql_private_ip)
sed -i "s/CHANGE_ME_PROJECT_ID/${PROJECT_ID}/g; s/CHANGE_ME_PRIVATE_IP/${SQL_IP}/g" \
  kubernetes/overlays/dev/kustomization.yaml

# 3. Apply
kubectl apply -k kubernetes/overlays/dev
kubectl rollout status deployment/customer-service -n bss
```

## Smoke test

```bash
kubectl port-forward -n bss svc/customer-service 8080:80 &
curl -s http://localhost:8080/actuator/health | jq
curl -sX POST http://localhost:8080/tmf-api/customerManagement/v4/customer \
  -H 'Content-Type: application/json' \
  -d '{"name":"Ngoc","email":"ngoc@example.com","status":"Active"}'
```

## View dashboards

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# open http://localhost:3000  — login admin / changeme
```

## Tear down (do this when done for the day!)

```bash
# Apps & monitoring first
kubectl delete -k kubernetes/overlays/dev
helm uninstall monitoring -n monitoring

# Then infrastructure
cd terraform
terraform destroy
```

## Cost optimization

If you want to keep the cluster running cheaply (~$2/day):

- Use a Standard cluster with a `e2-small` preemptible node pool instead of Autopilot
- Use `db-f1-micro` for Cloud SQL with no HA
- Skip the Cloud NAT (use a public cluster) — **only for learning**, never production
- Turn off Cloud SQL when not actively using it: `gcloud sql instances patch bss-postgres-dev --activation-policy=NEVER`

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `terraform apply` hangs on Cloud SQL | First-time API enablement takes 2–5 min, just wait |
| Pods stuck `ImagePullBackOff` | Workload Identity not configured for the SA, or image tag wrong in kustomize |
| `connection refused` to Cloud SQL | Cloud SQL Auth Proxy sidecar not running, or VPC peering not ready |
| `kubectl` times out | Your IP is not in `authorized_networks` — update `terraform.tfvars` |
