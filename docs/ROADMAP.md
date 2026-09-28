# Roadmap

Public, high-level phase tracker for this repo. It mirrors the phase table in
[CLAUDE.md §13](../CLAUDE.md) (the source of truth for architecture decisions and current status)
without the day-to-day working notes — those live in a private, gitignored `learning/` journal
kept by the maintainer while working through this project as a learning exercise.

> This file replaces an older GCP/GKE-era roadmap that predated the project's move to AWS
> (see [CHANGELOG.md](../CHANGELOG.md) and `docs/adr/ADR-000-local-dev.md` onward for the
> AWS-based architecture actually implemented).

| Phase | Goal | Status |
|---|---|---|
| 0 — Scaffold | Monorepo, Terraform modules, CI/CD workflows, docker-compose local dev | ✅ Done |
| 1 — Local dev end-to-end | 5 backend + 2 frontend apps build, run, and talk to each other on a laptop | ✅ Done — verified with real browser + curl runs |
| 2 — Kubernetes local (`kind`) + observability local | Full stack on `kind` via Kustomize, real Prometheus/Grafana/Alertmanager | ✅ Done |
| 3 — CI green on GitHub | All 4 CI workflows pass on real PRs, tests actually execute | ✅ Done |
| 4 — Terraform + AWS bootstrap | `terraform apply`/`destroy` on a real AWS account, repeatable | ✅ Done |
| 5 — Deploy dev to EKS | All 7 services running on real EKS, real RDS, real EventBridge/SQS | ✅ Done |
| 6 — CD: dev → staging → prod | Merge-to-dev automation, tag-based promotion, automatic rollback | ✅ Done |
| 7 — Observability + security on AWS | Dashboards/alerts/SLO, NetworkPolicy, OAuth2, WAF, Trivy gate | ✅ Done |
| 8 — Reliability, load test, docs, demo | k6 capacity threshold, chaos engineering, ops tooling, this README/CLAUDE.md refresh, `v1.0.0` | ✅ Done |

Each phase above was executed and **verified against real infrastructure** (not just "code written")
before being marked done — see the architecture decisions in [`docs/adr/`](adr/) and the
verification runbooks in [`docs/runbooks/`](runbooks/) for the evidence behind each checkmark.

## Definition of Done for `v1.0.0`

- [ ] Clean-repo bootstrap works: `make local-up` + local e2e PASS; `kind` + e2e PASS.
- [ ] All CI workflows green with tests actually executing; Trivy gate blocking real findings.
- [ ] `terraform apply` on dev from zero in ≤ 30 min, `destroy` leaves no orphaned resources.
- [ ] Merge → dev auto-deploys; tag → staging; tag + approval → prod; automatic rollback demonstrated.
- [ ] Dashboards show real data; ≥ 3 alerts wired to a runbook and a chat channel; 1 SLO with a burn-rate alert.
- [ ] No secrets in git; one IAM role + one DB user per service; Pod Security `restricted`.
- [ ] ≥ 7 ADRs, ≥ 8 runbooks, 1 postmortem, `CHANGELOG.md` up to `v1.0.0`.
- [ ] A measured p95-latency capacity threshold on real dev EKS (not estimated).
- [ ] Chaos experiments (pod deletion, node drain) run against a real cluster with recorded results.

See [`CLAUDE.md` §13](../CLAUDE.md) for the fully detailed, always-current status write-up.
