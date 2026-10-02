# Setup Guide

From a clean machine to the whole platform running — locally ($0), on `kind` ($0), then on AWS. Every
step below is the sequence that was actually run (Phases 0–9, 2026-09); each part ends with a **check**
that must pass before you continue.

> Deeper, step-by-step walkthrough in Vietnamese (with the "why" behind each step): `learning/19-khoi-dong-tu-dau.md`
> (local-only notes, not in git). Design decisions: [`docs/adr/`](adr/).

## Part 0 — Tools

Work in **Linux or WSL2** (Ubuntu). Scripts are bash, the Makefile needs `make`, and line endings must be LF
(`.gitattributes` enforces it). Clone into the Linux filesystem (`~/code/...`), not `/mnt/c/...` —
Maven writes under `target/` and is slow/flaky on the Windows mount.

| Tool | Version used | Needed for |
|---|---|---|
| Docker (Desktop with WSL integration, or Engine) | 29.x | everything |
| JDK (Temurin) + Maven | 21 / 3.9 | backend build + tests (Testcontainers) |
| Node.js | 20 | frontend |
| kubectl, kind, helm | 1.34+, 0.3x, 3.x | Kubernetes (local + EKS) |
| Terraform | ≥ 1.10 (S3 native locking) | AWS |
| AWS CLI | v2 | AWS |
| jq, gh (GitHub CLI) | latest | scripts, CD setup |

```bash
java -version && mvn -v && node -v && docker run --rm hello-world && kind version && terraform version && make help
```

`customer-service` depends on `com.bss:bss-common-java` from GitHub Packages. Building it needs
`GITHUB_TOKEN` = a token with `read:packages` (`gh auth refresh -s read:packages && export GITHUB_TOKEN=$(gh auth token)`).

## Part 1 — Local, no Kubernetes ($0)

```bash
./scripts/e2e-local.sh            # docker compose (Postgres, Redis, LocalStack, Keycloak) + 5 backends via mvn + full business flow
./scripts/e2e-local.sh --stay-up  # same, then keep everything running for the UI:
cd apps/frontend/web-portal && npm ci && npm run dev      # http://localhost:3000 (admin-console: 3001)
```

**Check:** the script ends with `ALL CHECKS PASSED` (new Keycloak user → own profile → blocked until approved →
admin approves → order → invoice with 10% VAT → another customer gets 404). Local profile: ports 8081–8084 +
gateway 8080 ([ADR-000](adr/ADR-000-local-dev.md)); auth is **always on** — tokens come from the compose
Keycloak at `localhost:8180` ([runbooks/auth.md](runbooks/auth.md)).

## Part 2 — Kubernetes locally with kind ($0)

```bash
./scripts/kind-up.sh                                      # cluster "bss" + ingress-nginx + metrics-server
./scripts/auth-install.sh kind                            # Secret keycloak-admin (before the overlay)
make build-images                                         # 7 images tagged :local (needs GITHUB_TOKEN)
for s in customer-service product-catalog order-management billing-service api-gateway web-portal admin-console; do
  kind load docker-image bss/$s:local --name bss
done
kubectl --context kind-bss apply -k infrastructure/kubernetes/overlays/local
kubectl --context kind-bss -n bss wait --for=condition=Ready pod --all --timeout=300s
./scripts/e2e-kind.sh                                     # API flow with real Keycloak tokens + ownership (404s)
./scripts/e2e-browser.sh                                  # Playwright: sign-up → approval → purchase → invoice
```

Websites: <http://bss.localhost> (customer) and <http://bss.localhost/admin/> (staff — test users are in
`infrastructure/kubernetes/overlays/local/keycloak/bss-users-0.json`, local only).
Optional, same scripts as on AWS: `./scripts/monitoring-install.sh kind`, `logging-install.sh kind`,
`tracing-install.sh kind`; `./scripts/netpol-matrix.sh kind-bss`.

**Check:** `e2e-kind.sh` prints `ALL CHECKS PASSED`; Playwright `3 passed`. Tear down: `./scripts/kind-down.sh`.

## Part 3 — AWS account (once)

1. Create the account, enable **MFA on root**, create an IAM user (or SSO) for daily work — never use root.
2. `aws configure` (region `ap-southeast-1`) → `aws sts get-caller-identity` shows **your** account/user.
3. `./scripts/bootstrap-aws.sh` — creates the state bucket `bss-tfstate-<account_id>` (versioned,
   encrypted, S3 native lock — no DynamoDB), budget alerts, and the EC2 Spot service-linked role (Karpenter).
4. Check the **vCPU quota** (`L-1216C47A`, On-Demand Standard) — a new account has 8, which fits only one
   cluster at a time ([runbooks/cd-staging-prod-demo.md §1b](runbooks/cd-staging-prod-demo.md)).

## Part 4 — Shared state: ECR, GitHub OIDC, deployer roles, domain (once)

```bash
make ENV=shared tf-init && make ENV=shared tf-plan    # READ the plan
make ENV=shared tf-apply                              # 8 ECR repos, OIDC provider, 3 deployer roles, Route 53 zone + ACM cert
./scripts/setup-github-environments.sh                # dry run — read it
./scripts/setup-github-environments.sh --apply        # Environments dev/staging/production + variables
```

`shared` is **never** destroyed nightly ([ADR-003](adr/ADR-003-terraform-shared-state.md),
[ADR-006](adr/ADR-006-staging-prod-ephemeral.md)). There are no AWS keys or secrets in GitHub — each
role trusts exactly one GitHub Environment:

| GitHub Environment | Who may deploy | Manual approval | AWS role (variable `AWS_ROLE_ARN`) | Workflow |
|---|---|---|---|---|
| `dev` | branch `main` | no | `bss-github-deployer-dev` | `cd-dev.yml` |
| `staging` | tags `rc-v*` | no | `bss-github-deployer-staging` | `cd-staging.yml` |
| `production` | tags `v*` | **yes** | `bss-github-deployer-prod` | `cd-prod.yml` |

**Check:** `gh api repos/{owner}/{repo}/environments --jq '.environments[].name'` → `dev staging production`.

**Domain + HTTPS (once, two steps — [ADR-012](adr/ADR-012-https-ten-mien.md)).** The AWS overlays serve
`https://dev.bssplatform.dpdns.org`, `https://staging.…` and the apex for prod; the ALB Controller finds the
ACM certificate by host, so **no environment gets an ALB until the certificate is `ISSUED`**:

```bash
terraform -chdir=infrastructure/terraform/environments/shared output dns_name_servers   # 4 awsdns-* name servers
# → enter them at the registrar ("Use other nameservers" at DigitalPlat) — a manual step
dig NS bssplatform.dpdns.org +short @1.1.1.1   # wait until it shows awsdns-*
# set dns_delegated = true in environments/shared/terraform.tfvars, then plan + apply again → certificate ISSUED
```

Cost: the hosted zone is $0.50/month; the public ACM certificate is free. Using another domain: change
`domain_name` (shared), the host in the three AWS overlays, and the redirect URIs in
`components/keycloak-realm/bss-realm.json`. Details: [runbooks/https-domain.md](runbooks/https-domain.md).

## Part 5 — Dev environment (each working session)

```bash
cp infrastructure/terraform/environments/dev/terraform.tfvars.example infrastructure/terraform/environments/dev/terraform.tfvars
# edit owner_email, public_access_cidrs
make ENV=dev tf-init        # always via make: it passes -backend-config=bucket=... (B-38); a bare `terraform init` silently uses empty local state
make ENV=dev tf-plan        # READ it — ~90 resources on a fresh account
make ENV=dev tf-apply       # ~15–20 min (EKS, RDS, NAT)
make ENV=dev kube-config && kubectl get nodes

./scripts/platform-install.sh dev          # namespace bss, ALB Controller, gp3, Secrets CSI, Karpenter (dev), ExternalDNS
kubectl apply -k infrastructure/kubernetes/overlays/dev/db-bootstrap
kubectl -n bss wait --for=condition=complete job/db-bootstrap --timeout=180s
kubectl -n bss logs job/db-bootstrap | tail -2          # "all 5 databases ready" (4 services + Keycloak)
kubectl delete -k infrastructure/kubernetes/overlays/dev/db-bootstrap
```

Deploy = **GitHub Actions → "CD — dev" → Run workflow** on `main`: it computes the desired image of each of
the 8 images from git, builds whatever ECR lacks, applies, waits for rollout, checks drift, runs
`scripts/smoke.sh` (with a real Keycloak token), and records `dev.json` on the `deploy-state` branch
([ADR-005](adr/ADR-005-nguon-su-that-phien-ban-cd.md), [runbooks/cd-dev.md](runbooks/cd-dev.md) — §5 has
the manual equivalent). Observability and WAF are separate, optional steps:
`./scripts/monitoring-install.sh dev` (set `ALERT_WEBHOOK_URL`), `logging-install.sh dev`,
`tracing-install.sh dev`, `make ENV=dev wire-waf` ([runbooks/waf.md](runbooks/waf.md)).

**Check:** CD run green; `kubectl -n bss get pods` all `Running`; `./scripts/smoke.sh dev` PASS (7 checks
over `https://dev.bssplatform.dpdns.org` with the real certificate); `dig +short dev.bssplatform.dpdns.org`
returns the ALB (ExternalDNS creates it ~1 min after the ALB). Then check both websites end to end:

```bash
./scripts/e2e-flow.sh dev                 # API: customer signs up → blocked → staff approves → buys → invoice → staff sees it
./scripts/e2e-browser.sh dev              # Playwright on https://dev…: the same journey through both websites
./scripts/admin-user.sh dev <you> <email> # your own staff account for /admin/ — temporary password, change it at first login
```

The realm on AWS has no users and `/auth/admin` is deliberately not exposed, so staff accounts are created by an
operator through `kubectl port-forward` (`admin-user.sh`; the two e2e scripts create **temporary** users and
delete them at the end). Staging/prod are rebuilt each session — run `admin-user.sh` again after each build.

## Part 6 — Staging / prod (ephemeral, one session at a time)

Same shape as Part 5 with `ENV=staging|prod` (`ephemeral = true` in their tfvars), then promote with tags —
the exact checklist, quota rules and the API-endpoint ↔ GitHub-runner trade-off are in
[runbooks/cd-staging-prod-demo.md](runbooks/cd-staging-prod-demo.md):

```bash
git tag rc-v2.1.0 <commit> && git push origin rc-v2.1.0   # cd-staging: ecr put-image → deploy → smoke → releases/rc-v2.1.0.json
git tag v2.1.0   <same>   && git push origin v2.1.0       # cd-prod: gate (rc verified on staging, same commit) → Approve → deploy
```

After each deploy: `./scripts/e2e-flow.sh <env>`, `./scripts/e2e-browser.sh <env>` and `./scripts/admin-user.sh <env> …` — exactly as in Part 5 (`https://staging.bssplatform.dpdns.org` / `https://bssplatform.dpdns.org`).

## Part 7 — Tear down (every evening)

```bash
make ENV=dev tf-destroy                    # teardown.sh: Ingress → waits for ExternalDNS to delete the DNS records → Karpenter NodePool → destroy
pip install -r tools/ops/requirements.txt  # once (boto3)
python tools/ops/orphan_finder.py          # anything still billing? must be empty
python tools/ops/cost_report.py            # last 7 days of spend
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `terraform plan` wants to create everything on an env that exists | `terraform init` without the backend bucket → empty local state | `make ENV=<env> tf-init` (passes `-backend-config`) |
| Node group `CREATE_FAILED` after RDS/NAT were already created | vCPU quota (not checked by `plan`) | Destroy other clusters or request quota; [runbooks/cd-staging-prod-demo.md §1b](runbooks/cd-staging-prod-demo.md) |
| `terraform destroy` stuck on the VPC (`DependencyViolation`) | ALB / Karpenter nodes / target groups outside Terraform | `./scripts/teardown.sh` does the order; then `tools/ops/orphan_finder.py` |
| Pod `CreateContainerConfigError` | Secret not synced: Secrets CSI not installed or pod doesn't mount the CSI volume | `platform-install.sh`, [ADR-004](adr/ADR-004-db-credential-wiring-dev.md) |
| cd-dev: "Runner không kết nối được API server" | `public_access_cidrs` excludes GitHub runners | [runbooks/cd-staging-prod-demo.md §4](runbooks/cd-staging-prod-demo.md) |
| Every API call 401 even with a fresh token | `iss` ≠ `issuer-uri` of the services | [runbooks/auth.md](runbooks/auth.md) §6 |
| Ingress has no `ADDRESS`; `describe ingress` says no certificate found | ACM certificate not `ISSUED` yet (Part 4, step 2) | [runbooks/https-domain.md](runbooks/https-domain.md) |
| `dig` returns NXDOMAIN although the Ingress has an `ADDRESS` | ExternalDNS missing or `AccessDenied` (host not in its IAM list) | `platform-install.sh`; `kubectl -n kube-system logs deploy/external-dns` |
| Keycloak login page says "HTTPS required" | Keycloak does not see `X-Forwarded-Proto` | `KC_PROXY_HEADERS=xforwarded` in `components/keycloak-aws` |
| Second Keycloak pod restarts once on a brand-new environment | Two pods creating Liquibase tables on an empty DB | Expected, self-heals — [ADR-011](adr/ADR-011-keycloak-production-grade.md) §3 |
