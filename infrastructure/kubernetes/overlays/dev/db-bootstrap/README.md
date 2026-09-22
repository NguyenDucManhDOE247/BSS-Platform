# db-bootstrap (B-21)

Creates the 4 per-service databases + least-privilege users on the shared RDS instance
(`customer`/`product`/`orders`/`billing`, matching `deploy/postgres-init/01-create-databases.sh`
— the local Docker Compose equivalent of this). Terraform (`modules/rds`) only *generates and
reserves* the credentials in Secrets Manager; it doesn't have a way to run SQL against RDS
itself (see the long comment above `local.service_databases` in
`infrastructure/terraform/modules/rds/main.tf`). This Job does the actual `CREATE
DATABASE`/`CREATE ROLE`/`GRANT` — see `docs/adr/ADR-003-terraform-shared-state.md`'s sibling
decision on *why* this is a Job and not a `cyrilgdn/postgresql` Terraform provider: RDS sits in a
private subnet, and `terraform apply` doesn't run from inside the VPC (GitHub Actions runners
aren't either) — a Kubernetes Job running on an actual EKS node is.

## Why this isn't part of `overlays/dev`'s regular `kustomization.yaml`

A `Job`'s pod template is immutable once created — a routine `kubectl apply -k overlays/dev` on
every CD run would fail the moment this file's content ever changed (`field is immutable`).
Applied as its own, separate, one-off kustomization instead.

## Prerequisites

1. `environments/dev` has been `terraform apply`'d (needs RDS + the `db-bootstrap` IRSA role —
   see the `db-bootstrap` entry in `environments/dev/main.tf`'s `module "iam"` block).
2. Secrets Store CSI Driver + the AWS provider are installed (`platform/secrets/` — see
   `platform/README.md` step 4).
3. `serviceaccount.yaml`'s `eks.amazonaws.com/role-arn` annotation is filled in (see the comment
   in that file for the exact command).

## Run it

```bash
kubectl apply -k infrastructure/kubernetes/overlays/dev/db-bootstrap
kubectl -n bss wait --for=condition=complete job/db-bootstrap --timeout=120s
kubectl -n bss logs job/db-bootstrap
```

Expect 4 lines like `=== bootstrapping database 'customer' / role 'customer_svc' ===`, ending
with `db-bootstrap: all 4 databases ready`.

## Clean up after a successful run

```bash
kubectl delete -k infrastructure/kubernetes/overlays/dev/db-bootstrap
```

Safe — the Job is a one-shot; the databases/roles it created live on in RDS. Re-running it later
(e.g. after adding a 5th service) is also safe: every statement in `configmap.yaml`'s script is
written to be a no-op if the database/role already exists.

## Not done yet (Giai đoạn 5 scope, see `learning/20`)

Each service's own `Deployment` still connects with the shared **master** user (that's B-20, not
B-21) — this Job only gets the per-service users/databases to *exist*. Wiring each service's own
`SecretProviderClass` + `Deployment` volume mount to actually USE its new least-privilege user is
Giai đoạn 5 item 2.
