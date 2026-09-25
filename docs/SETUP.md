# Setup Guide

End-to-end instructions for getting BSS Platform running, from a fresh AWS account to a deployed service.

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| AWS CLI | v2 | `brew install awscli` |
| Terraform | 1.7+ | `brew install terraform` |
| kubectl | 1.30+ | `brew install kubectl` |
| Helm | 3.14+ | `brew install helm` |
| Kustomize | 5.x | `brew install kustomize` |
| Docker | latest | https://docker.com |
| JDK | 21 (Temurin) | `brew install --cask temurin@21` |
| Node.js | 20 | `brew install node@20` |
| Maven | 3.9 | `brew install maven` |
| jq | latest | `brew install jq` |

## Part 1 — AWS account setup

> Skip if you already have an account with billing + MFA enabled.

1. Create an AWS account at https://aws.amazon.com.
2. Enable **MFA on root user** immediately (IAM → Security credentials).
3. Create an IAM user for daily use (don't use root):
   - IAM → Users → Add user → `bss-dev`
   - Attach `AdministratorAccess` policy (tighten later in Phase 9).
   - Enable MFA on this user too.
   - Create an access key, save to `~/.aws/credentials`.
4. Configure CLI:
   ```bash
   aws configure        # paste key + secret, region: ap-southeast-1
   aws sts get-caller-identity   # verify
   ```
5. Set a **monthly budget alert** in Billing → Budgets → $50.

## Part 2 — One-time bootstrap

```bash
git clone <your-repo-url> bss-platform
cd bss-platform

# Creates S3 bucket for tfstate, DynamoDB table for state locks, budget alert.
OWNER_EMAIL=you@example.com ./scripts/bootstrap-aws.sh
```

After this, edit `infrastructure/terraform/environments/dev/main.tf` and uncomment the `backend "s3"` block.

## Part 3 — Provision dev environment

```bash
cd infrastructure/terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
# Edit: set owner_email, public_access_cidrs (your IP), github_repos
$EDITOR terraform.tfvars

terraform init
terraform plan          # review carefully
terraform apply         # ~15-20 minutes for EKS to come up
```

Outputs you'll need:
- `kubeconfig_command` — copy/paste to set up kubectl
- `ecr_registry` — the ECR registry URL for image push
- `github_deployer_role_arn` — the role for the GitHub Environment `dev` (Part 6 sets it as the variable `AWS_ROLE_ARN` for you)

```bash
make ENV=dev kube-config
kubectl get nodes       # should show 2 nodes
```

## Part 4 — Install cluster addons

```bash
# Run from repo root.
# See platform/README.md for full helm commands with the exact role-arn substitutions.

# Minimal viable set:
helm repo add eks https://aws.github.io/eks-charts
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# 1. AWS Load Balancer Controller
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system -f platform/networking/aws-load-balancer-controller-values.yaml \
  --set clusterName=bss-dev-eks

# 2. ExternalDNS (skip if you don't own a Route 53 domain)

# 3. Prometheus + Grafana
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f platform/monitoring/prometheus/values.yaml
```

## Part 5 — Build + deploy first service

> customer-service depends on `com.bss:bss-common-java`, published to GitHub Packages — building
> it (locally or via `make ... push`) needs `GITHUB_TOKEN` exported to a PAT with `read:packages`
> scope (`gh auth token` alone does NOT have this scope by default; `gh auth refresh -s
> read:packages` first, or use a separate classic PAT). Every other service ignores this.

```bash
# Build customer-service container and push to ECR
export GITHUB_TOKEN=$(gh auth token)   # needs read:packages scope — see note above
make ENV=dev SERVICE=customer-service push

# Update kustomize overlay to point at the new image
make ENV=dev SERVICE=customer-service set-image

# Apply
make ENV=dev deploy
make ENV=dev smoke
```

## Part 6 — GitHub Actions CI/CD

How CD is designed: [ADR-005](adr/ADR-005-nguon-su-that-phien-ban-cd.md). Day-to-day use:
[runbooks/cd-dev.md](runbooks/cd-dev.md), [runbooks/cd-promotion.md](runbooks/cd-promotion.md).

There are **no AWS keys and no GitHub secrets** in this pipeline. Each workflow job authenticates with a
short-lived OIDC token, and each AWS role trusts exactly **one GitHub Environment** (B-39):

| GitHub Environment | Who may deploy into it | Manual approval | AWS role (variable `AWS_ROLE_ARN`) | Used by |
|---|---|---|---|---|
| `dev` | branch `main` | no | `bss-github-deployer-dev` | `cd-dev.yml` |
| `staging` | tags `rc-v*` | no | `bss-github-deployer-staging` | `cd-staging.yml` |
| `production` | tags `v*` | **yes** | `bss-github-deployer-prod` | `cd-prod.yml` |

1. **Terraform, in this order** (roles must exist before an environment can use them):
   ```bash
   make ENV=shared tf-init && make ENV=shared tf-plan     # read the plan, then:
   make ENV=shared tf-apply                               # creates the 3 deployer roles, ECR, OIDC provider
   make ENV=dev    tf-apply                               # EKS access entry for the dev role
   ```
2. **Create the GitHub Environments + variables** (dry-run by default — read what it prints first):
   ```bash
   ./scripts/setup-github-environments.sh            # prints the plan
   ./scripts/setup-github-environments.sh --apply
   ```
   This creates the 3 Environments (with the allowed branch/tag rules and, for `production`, you as the
   required reviewer), the repository variable `ECR_REGISTRY`, and one `AWS_ROLE_ARN` per Environment.
   Working alone? Leave `PREVENT_SELF_REVIEW` at `false` (the default) — otherwise nobody can approve.
3. **Cluster addons + namespace** (run by an admin, not by CD): `./scripts/platform-install.sh dev`, then the
   `db-bootstrap` Job (`infrastructure/kubernetes/overlays/dev/db-bootstrap/README.md`).
4. Open a small PR → `ci-backend`, `ci-scripts`, … run.
5. Merge → `cd-dev` runs. The **first** run has no `dev.json` yet, so it can deploy but not roll back.
6. Tag `rc-v0.1.0` → `cd-staging` (needs the staging cluster: [runbooks/cd-staging-prod-demo.md](runbooks/cd-staging-prod-demo.md)).
7. Tag `v0.1.0` (same commit) → `cd-prod` runs its checks, then **waits for your approval**.

Verify the wiring without deploying anything:
```bash
gh api repos/{owner}/{repo}/environments --jq '.environments[].name'      # dev staging production
gh variable list --env production                                          # AWS_ROLE_ARN
aws iam get-role --role-name bss-github-deployer-prod --query 'Role.AssumeRolePolicyDocument'
```

## Cost optimization

Run this when not actively working:
```bash
make ENV=dev tf-destroy        # cuts dev cost to ~$0/day
```

Other levers:
- Use **VPC Endpoints** instead of NAT Gateway (saves $1.10/day) — already on by default.
- Use **t3.medium spot** for Karpenter NodePool (saves ~70% on workload nodes).
- Tighten **ECR lifecycle policy** to keep fewer image versions.
- Drop **CloudWatch log retention** to 1 day in dev (`log_retention_days = 1` in `observability` module).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `terraform apply` hangs on EKS | First-time provisioning, normal | Wait 15-20 minutes |
| Pods stuck `Pending` | Karpenter not installed yet | `kubectl describe pod` → check events |
| ALB returns 503 | Backend pods not Ready | `kubectl get pods -n bss` then `kubectl logs` |
| Pod can't connect to RDS | IRSA role missing secret access | Check terraform `iam` module `inline_policy_statements` |
| `ImagePullBackOff` | ECR auth or wrong tag | `kubectl describe pod` — check the actual image ref |
