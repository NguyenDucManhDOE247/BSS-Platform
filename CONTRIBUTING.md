# Contributing to BSS Platform

Thanks for your interest! This is a personal learning / portfolio project, but PRs and issues are welcome.

## Ground rules

- Read [`CLAUDE.md`](CLAUDE.md) first — it is the source of truth for architecture, coding conventions, and the Phase-based roadmap.
- One concern per PR. Split large changes into a stack of small reviewable commits.
- Don't introduce abstractions for hypothetical future requirements.
- No secrets in commits. `.env`, `*.tfvars`, AWS credentials are gitignored — keep them that way.

## Dev environment

Required tooling:

- `jdk 21` (Temurin or any distribution)
- `node 20` + `npm 10`
- `docker` (with Compose v2)
- `make`
- For infra work also: `aws-cli`, `terraform 1.7+`, `kubectl`, `helm`, `kustomize`

Spin up local dependencies:

```bash
make local-up      # Postgres + Redis + LocalStack via docker-compose
```

Run a backend service:

```bash
cd apps/backend/customer-service
mvn spring-boot:run
```

Run a frontend:

```bash
cd apps/frontend/web-portal
npm install && npm run dev
```

## Commit convention

We follow **Conventional Commits** with a scope:

```
<type>(<scope>): <imperative summary>

<optional body explaining why, not what>
```

Allowed types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `ci`, `build`, `perf`, `revert`.

Common scopes: `customer-service`, `product-catalog`, `order-management`, `billing-service`, `api-gateway`, `web-portal`, `admin-console`, `k8s`, `terraform`, `ci`, `docs`.

Examples:

```
feat(billing-service): add idempotent SQS consumer
fix(order-management): handle null customerId in outbox payload
docs: add SLO definitions
```

## Code conventions

### Java / Spring Boot

- Package layout **per feature** (`controller`, `service`, `repository`, `model`, `dto`).
- **Constructor injection** only (no `@Autowired` on fields).
- **Records** for DTOs.
- `@Transactional` only at the service layer.
- Flyway migrations under `src/main/resources/db/migration/V<n>__<desc>.sql`.
- PK = UUID v7.
- Bean Validation (`@Valid`, `@NotNull`, `@Size`) on incoming DTOs.
- Errors as RFC 7807 `ProblemDetail`.

### React / TypeScript

- TypeScript **strict mode** — never `any`.
- Server state via **react-query**, local UI state via **zustand**.
- Tests with **vitest** + `@testing-library/react`.

### Kubernetes

- Every container: `resources` (requests + limits), 3 probes (startup + liveness + readiness), `securityContext` non-root, `readOnlyRootFilesystem: true`.
- Image tag = git SHA (never `latest`).
- Add new manifests to `infrastructure/kubernetes/base/<svc>/`, not directly to overlays.

### Terraform

- `terraform fmt && terraform validate` before commit.
- High-cost resources (HA RDS, GPU, MSK) → call out in PR description.
- Never put secrets in `.tfvars` — generate random → push to Secrets Manager.

## Testing

- Bug fixes ship with a regression test (fails before the fix, passes after).
- New features: unit test for happy path + at least two edge cases + integration test for the API contract.
- Integration tests use **Testcontainers** (real Postgres) + **LocalStack** (EventBridge/SQS). Do not mock the framework.

## Pull request checklist

Before opening a PR:

- [ ] Code builds locally (`mvn verify` or `npm run build` as applicable).
- [ ] Tests pass.
- [ ] No secrets committed.
- [ ] If you touched infra: `terraform fmt`, `terraform validate`, and update `docs/SETUP.md` if new env vars are required.
- [ ] Commit messages follow Conventional Commits.
- [ ] Linked any related issue.

CI will run on every PR — keep it green.

## Reporting bugs / proposing features

Use the GitHub Issues templates. For security issues, see [SECURITY.md](SECURITY.md).
