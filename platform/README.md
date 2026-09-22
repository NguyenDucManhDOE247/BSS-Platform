# Platform addons

Components in this folder are **cluster-wide infrastructure** (not application code).
They are installed once per EKS cluster, typically via Helm.

## Install order

Steps are labeled by the `learning/20` giai đoạn (phase) that actually needs them — don't run a
later phase's addons just because they're in this file; each one costs something (a running pod
at minimum, sometimes an AWS resource with an hourly charge) for zero benefit until its phase.
`./scripts/platform-install.sh $ENV` runs steps 1–3 (the Giai đoạn 5 minimum) in order with pinned
versions — read this file for the "why" behind each one; `make platform-install` calls that script.

After `terraform apply` finishes and `aws eks update-kubeconfig` is set:

```bash
# 1. AWS Load Balancer Controller (creates the ALB from the Ingress resource) — Giai đoạn 5.
# Chart/app version MUST match the iam_policy.json version pinned in
# infrastructure/terraform/modules/platform-iam/main.tf (mismatched binary vs. IAM policy is a
# real way to get AccessDenied on ALB creation that "helm upgrade succeeded" won't warn you
# about) — re-check both together before bumping either.
helm repo add eks https://aws.github.io/eks-charts
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 3.5.0 \
  -n kube-system -f networking/aws-load-balancer-controller-values.yaml \
  --set clusterName=bss-dev-eks \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform -chdir=../infrastructure/terraform/environments/dev output -raw aws_lb_controller_role_arn)

# 2. gp3 StorageClass (B-41) — Giai đoạn 5. EKS ships no default StorageClass; without one,
# every PVC that doesn't name a class explicitly (Prometheus/Grafana/Alertmanager's, step 7
# below) sits Pending forever. Needs the EBS CSI driver, which Terraform already installed as a
# first-class aws_eks_addon (environments/*/main.tf) — nothing to helm-install for that part.
kubectl apply -f storage/storageclass-gp3.yaml

# 3. Secrets Store CSI Driver + AWS provider (B-20) — Giai đoạn 5. Powers the 4 per-service
# SecretProviderClass resources in infrastructure/kubernetes/overlays/dev/secrets/.
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --version 1.6.1 \
  -n kube-system -f secrets/secrets-store-csi-values.yaml
# Pinned to a release TAG, not "main" (B-42) — an unpinned branch reference can change under you
# between two identical-looking runs of this command with no changelog to check.
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/3.1.4/deployment/aws-provider-installer.yaml

# --- everything below is LATER phases (see learning/20) — not needed for Giai đoạn 5's
# "7 service chạy trên EKS dev, truy cập qua ALB" checkpoint. Listed here for when you get there.

# 4. External DNS (auto-creates Route 53 records) — needs a real domain first (Giai đoạn 6+).
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm upgrade --install external-dns external-dns/external-dns \
  -n kube-system -f networking/external-dns-values.yaml

# 5. Karpenter (auto-provisioner for workload nodes) — Giai đoạn 8 (cost/scaling work).
helm repo add karpenter oci://public.ecr.aws/karpenter
helm upgrade --install karpenter karpenter/karpenter \
  -n karpenter --create-namespace
kubectl apply -f networking/karpenter-nodepool.yaml

# 6. Fluent Bit (logs → CloudWatch) — Giai đoạn 7 (observability on AWS).
helm upgrade --install fluent-bit eks/aws-for-fluent-bit \
  -n amazon-cloudwatch --create-namespace \
  -f logging/fluent-bit-values.yaml

# 7. OpenTelemetry Collector (traces → X-Ray) — Giai đoạn 7, optional per learning/20.
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  -n observability --create-namespace \
  -f tracing/otel-collector-values.yaml

# 8. Prometheus + Grafana — Giai đoạn 7 (already done for kind/local since Giai đoạn 2 — see the
# "Local (kind)" section below; this is the same stack, pointed at AWS instead).
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f monitoring/prometheus/values.yaml
kubectl apply -f monitoring/alerts/

# Pre-load BSS dashboards as a ConfigMap so the Grafana sidecar picks them up.
kubectl create configmap bss-dashboards \
  --from-file=monitoring/grafana/dashboards/ \
  -n monitoring --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard=1 --dry-run=client -o yaml | \
  kubectl apply -f -
```

> `make ENV=dev platform-install` runs `scripts/platform-install.sh`, which wraps steps 1–3 above
> (the Giai đoạn 5 minimum) into one command with the same pinned versions. Steps 4–8 are still
> manual — deliberately, since each belongs to a later phase you haven't necessarily reached yet.

## Local (kind) — Giai đoạn 2

Chỉ 1 addon áp dụng được ở local: **Prometheus + Grafana + Alertmanager** (metrics/dashboard/
alert thật — checkpoint của Giai đoạn 2). Các addon còn lại (ALB Controller, ExternalDNS,
Karpenter, Secrets CSI, Fluent Bit, OTel→X-Ray) đều gắn chặt với dịch vụ AWS thật, không có bản
tương đương chạy trên kind — xem `learning/16` mục 2 bảng "điều kiện chạy".

```bash
# ingress-nginx + metrics-server: cài bởi scripts/kind-up.sh, không phải bước ở đây.

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
helm --kube-context kind-bss upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version 91.4.0 \
  -n monitoring --create-namespace \
  -f monitoring/prometheus/values-local.yaml

# ServiceMonitor cần CRD do chart trên vừa cài xong mới apply được (B-40).
kubectl --context kind-bss apply -f monitoring/service-monitor.yaml
kubectl --context kind-bss apply -f monitoring/alerts/

# Dashboard: giống hệt bước AWS ở trên, đổi --context.
kubectl --context kind-bss create configmap bss-dashboards \
  --from-file=monitoring/grafana/dashboards/ \
  -n monitoring --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard=1 --dry-run=client -o yaml | \
  kubectl --context kind-bss apply -f -

# Xem Prometheus/Grafana/Alertmanager qua port-forward (kind không có LoadBalancer):
kubectl --context kind-bss -n monitoring port-forward svc/monitoring-grafana 3000:80
kubectl --context kind-bss -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
kubectl --context kind-bss -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093
```

Kiểm tra: Prometheus UI (`:9090`) → Status → Targets → 5 target `bss-services` phải `UP` (4
backend + gateway). Grafana (`:3000`, user `admin`, mật khẩu xem
`values-local.yaml`) → dashboard **BSS / BSS Microservices Overview** có số liệu thật. Webhook
Discord/Slack cho Alertmanager: xem `docs/runbooks/bss-high-error-rate.md` và
`docs/adr/ADR-001-alerting-channel.md`.
