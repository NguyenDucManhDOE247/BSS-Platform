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
| 9 — Real product (identity) | Keycloak + OIDC/PKCE, self-registration → admin approval, per-customer ownership in 4 services, 2 real websites, auth on in every environment, `v2.0.0` | ✅ Done — Playwright on `kind`; `rc-v2.0.0` → staging → `v2.0.0` → prod with authenticated smoke |
| HTTPS + custom domain (B-23) | `bssplatform.dpdns.org`: Route 53 + ACM in the shared state, ExternalDNS, Keycloak behind the ALB, browser login on AWS | ✅ Done — 2026-10-01 on dev EKS: TLS 1.3 with the ACM cert, smoke 7/7 over HTTPS, NetworkPolicy 12/12, real sign-up + sign-in in a browser; 2026-10-02 `rc-v2.2.0` → staging and `v2.2.0` → prod (apex), 7/7 + 12/12 each ([ADR-012](adr/ADR-012-https-ten-mien.md)) |
| Both websites on every environment | One business-flow script for every environment that also checks the staff side; operator-issued staff accounts | ✅ Done — 2026-10-02: `e2e-flow.sh` PASS + Playwright 3/3 on kind, dev, staging and prod, plus a manual staff/customer session on each AWS environment; `admin-user.sh` issues staff accounts (temporary password, admin role only) |
| Debt pass 8 → 0 | Every open item from earlier phases | ✅ Done — Karpenter Spot on dev, NetworkPolicy on EKS (11/11), all 8 Phase-7 items on one EKS cluster, Spring Boot 3.5 (0 HIGH/CRITICAL), expand/migrate/contract on RDS, orphan finder |

Each phase above was executed and **verified against real infrastructure** (not just "code written")
before being marked done — see the architecture decisions in [`docs/adr/`](adr/) and the
verification runbooks in [`docs/runbooks/`](runbooks/) for the evidence behind each checkmark.

## Definition of Done for `v1.0.0`

Reviewed item by item on **2026-09-30** — every ✅ was re-run or re-checked that day unless the evidence date says otherwise.

- [x] Clean-repo bootstrap works — fresh `git clone` → `scripts/e2e-local.sh` PASS (docker-compose + Keycloak, real tokens);
  fresh clone → `kind-down`/`kind-up` → build → `e2e-kind.sh` PASS + Playwright 3/3 in 12.6 min. Running from a clean clone
  surfaced 4 real bugs that existing environments hid (fixed: `kind-up.sh` wait race, 4 scripts without the executable bit,
  `e2e-local.sh` leaving orphan JVMs, `auth-install.sh` swallowing a missing-namespace error).
- [x] All CI workflows green with tests executing (5 services: 61 tests) and Trivy blocking real findings
  (history: Terraform + image CVEs in Phase 3; Keycloak 26.5 CRITICAL CVE found by the new `ci-keycloak.yml` gate).
- [x] `terraform apply` on dev from zero: **110 resources in 17.5 min** (≤ 30); `destroy`: 110 resource xong (teardown tự động mất ~34 phút rồi kẹt ở subnet vì 1 ENI của VPC CNI + 1 SG EKS mồ côi — xóa tay, destroy nốt 11 phút; teardown.sh đã sửa để tự dọn), `orphan_finder.py` clean.
- [x] Merge → dev auto-deploy (8 images incl. Keycloak, run 36684095963); `rc-v2.0.0` → staging and `v2.0.0` + approval → prod
  (2026-09-29); automatic rollback demonstrated (lab 06, runs 36103409336 / 36106816155).
- [x] Dashboards with real data; 9 alerts, each with `runbook_url`, delivered to Discord (146 s on EKS, 2026-09-29);
  `order-management` SLO with fast/slow burn-rate alerts.
- [x] No secrets in git (gitleaks over full history: 14 hits, all commit SHAs in `deploy-state` manifests — false positives);
  one IRSA role + one DB user per service (`customer_svc`, `product_svc`, `orders_svc`, `billing_svc`, `keycloak_svc`,
  checked on EKS); namespace `bss` enforces Pod Security `restricted`.
- [x] 12 ADRs, 16 runbooks, 1 postmortem, `CHANGELOG.md` with `1.0.0` and `2.0.0`.
- [x] Measured capacity threshold on real dev EKS ([labs/07](labs/07-load-test-dev.md)).
- [x] Chaos (pod delete, node drain) on a real cluster ([labs/08](labs/08-chaos-engineering.md)); plus 2026-09-30: deleting a
  Keycloak pod under a 2-replica cluster kept sessions and the authenticated smoke test green.

**Open issues:** none. **B-23 (HTTPS)** — downgraded P1 → P2 on 2026-09-30 while waiting for a domain — and the web
part of **B-18** were closed on 2026-10-01: `bssplatform.dpdns.org` with an ACM certificate, Keycloak behind the ALB
(only `/auth/realms` + `/auth/resources`), and a real browser sign-up/sign-in on dev EKS ([ADR-012](adr/ADR-012-https-ten-mien.md)).

See [`CLAUDE.md` §13](../CLAUDE.md) for the fully detailed, always-current status write-up.
