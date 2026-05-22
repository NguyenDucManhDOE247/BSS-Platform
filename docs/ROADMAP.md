# Learning Roadmap

This repo is designed to be **built up**, not just cloned. Below is a 6-week plan that takes you from zero to a fully working BSS platform on GKE.

Each week ends with a concrete deliverable you can push to `main` — meaning your commit history itself becomes a portfolio of progressively harder work, which is **more impressive than a perfect repo with one giant commit**.

## Week 1 — Foundations & local development

**Goal:** Get the customer service running on your laptop with a real database.

- [ ] Install: `jdk21`, `maven`, `docker`, `kubectl`, `kustomize`, `terraform`, `gcloud`
- [ ] Read `services/customer-service/` end-to-end. Understand how Spring Boot wires the controller → repository → JPA → Postgres.
- [ ] `docker compose up` a Postgres instance, run `mvn spring-boot:run`, hit `POST /tmf-api/customerManagement/v4/customer` with curl.
- [ ] Read `services/customer-service/Dockerfile`. Understand each line. Build the image. Run it.

**Commit message at end of week:** `feat(customer-service): scaffold TMF629 customer API`

## Week 2 — GCP infrastructure

**Goal:** Click-free, repeatable infrastructure.

- [ ] Read `terraform/main.tf`, then `network.tf`, then `gke.tf`. Draw the network on paper. **Drawing it is the test.**
- [ ] Create a fresh GCP project. Enable billing. `gcloud auth application-default login`.
- [ ] `terraform apply`. Confirm cluster exists. Run `kubectl get nodes`.
- [ ] **Stretch:** move state to a GCS bucket (uncomment the `backend "gcs"` block in `main.tf`).
- [ ] **Stretch:** add a `tfsec` and `tflint` pre-commit hook.

**Commit message:** `feat(terraform): provision GKE Autopilot + Cloud SQL + Artifact Registry`

## Week 3 — Kubernetes

**Goal:** Customer service running on GKE, reachable through a LoadBalancer.

- [ ] Push the image to Artifact Registry manually (`docker push ...`).
- [ ] `kubectl apply -k kubernetes/overlays/dev`. Debug whatever breaks.
- [ ] Add a Cloud SQL Auth Proxy sidecar (or use the new Cloud SQL connector). Wire DB credentials via Workload Identity instead of a static secret.
- [ ] Add an `Ingress` (GCE LB) or a managed Gateway API resource.
- [ ] **Read & explain to yourself:** liveness vs readiness vs startup probes, why we set `runAsNonRoot`, what a PodDisruptionBudget actually prevents.

**Commit message:** `feat(k8s): deploy customer-service with HPA, PDB, Workload Identity`

## Week 4 — CI/CD

**Goal:** Push to main → it's live in dev within 5 minutes.

- [ ] Set up Workload Identity Federation between GitHub and GCP. **No service-account JSON keys.**
- [ ] Add `GCP_PROJECT_ID`, `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA` to GitHub Secrets.
- [ ] Trigger `cd.yml`. Watch a real deployment happen.
- [ ] Break something on purpose. Use `kubectl rollout undo` to recover, then add an automated rollback step to `cd.yml`.
- [ ] **Stretch:** add a manual approval gate for the `prod` environment.

**Commit message:** `feat(ci): build, scan, push, deploy via WIF — no static keys`

## Week 5 — Observability

**Goal:** When something breaks, you find out before users do.

- [ ] Install kube-prometheus-stack with `monitoring/prometheus/values.yaml`.
- [ ] Create the `bss-dashboards` ConfigMap from `monitoring/grafana/dashboards/`.
- [ ] Apply `monitoring/alerts/bss-alerts.yaml`. Force a `BssHighErrorRate` alert by returning 500s from a test endpoint.
- [ ] Wire Alertmanager to your Slack or Discord.
- [ ] **Stretch:** add distributed tracing with OpenTelemetry + Google Cloud Trace.

**Commit message:** `feat(monitoring): Prometheus + Grafana + alerts wired end-to-end`

## Week 6 — Build out the other services

**Goal:** Make this a real BSS, not just one service in a fancy box.

- [ ] Scaffold `product-catalog` (TMF620), `order-management` (TMF622), `billing-service` (TMF678) following the same template as `customer-service`.
- [ ] Add an event bus (Pub/Sub or Kafka via Strimzi) for order → billing flow.
- [ ] Write an ADR (Architecture Decision Record) in `docs/adr/` explaining your event-vs-REST choice for inter-service comms.
- [ ] Update the README architecture diagram.

**Commit message:** `feat(platform): complete TMF-aligned BSS with event-driven order flow`

---

## After 6 weeks: what to talk about in interviews

When a recruiter or interviewer asks "tell me about a project on your GitHub," walk them through this repo by answering these questions:

1. **Why this architecture?** (Microservices for independent deployability, TMF for industry alignment.)
2. **Why GKE Autopilot vs Standard?** (Operational simplicity, pay-per-pod.)
3. **Why Workload Identity Federation over JSON keys?** (Key rotation, blast radius.)
4. **What would you do differently at 100x scale?** (Per-service Cloud SQL, regional clusters, service mesh, Spinnaker, etc.)
5. **What was the hardest bug you hit?** (Have a concrete answer. Write it down in a `docs/POSTMORTEMS.md` as you go.)

The repo is the artifact. Your ability to **narrate why each piece exists** is what gets you hired.
