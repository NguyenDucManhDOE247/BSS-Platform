# Platform addons

Components in this folder are **cluster-wide infrastructure** (not application code).
They are installed once per EKS cluster, typically via Helm.

## Install order

Steps are labeled by the `learning/20` giai đoạn (phase) that actually needs them — don't run a
later phase's addons just because they're in this file; each one costs something (a running pod
at minimum, sometimes an AWS resource with an hourly charge) for zero benefit until its phase.
`./scripts/platform-install.sh $ENV` runs steps 1–3 (the Giai đoạn 5 minimum) in order with pinned
versions — after first creating namespace `bss` (Giai đoạn 6: CD's deployer role can't create a
cluster-scoped Namespace, see `overlays/dev/kustomization.yaml`) — read this file for the "why" behind each one; `make platform-install` calls that script.

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

# 5. Karpenter (auto-provisioner, ưu tiên Spot) — ADR-010, hiện CHỈ dev. KHÔNG cài tay: bước 6/6 của
#    scripts/platform-install.sh cài chart v1.14.1 (oci://public.ecr.aws/karpenter/karpenter, namespace
#    kube-system, IRSA + interruption queue từ `terraform output`) rồi áp networking/karpenter-nodepool.yaml
#    (thay __CLUSTER__). Lệnh cũ ở đây (repo "karpenter/karpenter", namespace riêng, không role/queue) không
#    bao giờ chạy được. Destroy: scripts/teardown.sh xóa NodePool trước (node Karpenter không có trong state).

# 6. Fluent Bit (logs → CloudWatch) — Giai đoạn 7. 1 lệnh (schema values cũ SAI — xem cảnh báo
# lớn ở đầu logging/fluent-bit-values.yaml, đã sửa và kiểm bằng `helm template`).
../scripts/logging-install.sh dev

# 7. OpenTelemetry Collector (traces → X-Ray) — Giai đoạn 7, tùy chọn per learning/20. Java agent
# TỰ inject qua initContainer trong mỗi Deployment (infrastructure/kubernetes/base/*/deployment.yaml)
# — không phải bước ở đây, ở đây chỉ cài nơi NHẬN trace.
../scripts/tracing-install.sh dev

# 8. Prometheus + Grafana + Alertmanager — Giai đoạn 7. Một lệnh (đã gom ~15 lệnh cũ, cùng đường đi
# với kind — xem mục "Local (kind)" bên dưới): tạo Secret mật khẩu Grafana + webhook, cài chart đã
# ghim version, nạp ServiceMonitor + alert + dashboard.
ALERT_WEBHOOK_KIND=discord ALERT_WEBHOOK_URL='https://discord.com/api/webhooks/...' \
  ./scripts/monitoring-install.sh dev
```

> `make ENV=dev platform-install` runs `scripts/platform-install.sh`, which wraps steps 1–3 above
> (the Giai đoạn 5 minimum) into one command with the same pinned versions. Steps 4–8 are still
> manual — deliberately, since each belongs to a later phase you haven't necessarily reached yet.

## Local (kind) — Giai đoạn 2 + 7

**Giai đoạn 2:** Prometheus + Grafana + Alertmanager (metrics/dashboard/alert thật — checkpoint
Giai đoạn 2). **Giai đoạn 7 (mới):** Fluent Bit + OTel Collector **cũng chạy thật trên kind** —
kind dùng containerd giống EKS (cùng định dạng log CRI), nên đây là cách kiểm chứng B-17/B-42 và
việc 3 (OTel) mà **không cần AWS, không tốn tiền**: `./scripts/logging-install.sh kind` (đích đến
là 1 sink HTTP cục bộ thay CloudWatch), `./scripts/tracing-install.sh kind` (đích đến là exporter
`debug` thay X-Ray). Chỉ 3 addon còn lại (ALB Controller, ExternalDNS, Karpenter, Secrets CSI) gắn
chặt với dịch vụ AWS thật, không có bản tương đương trên kind — xem `learning/16` mục 2 bảng
"điều kiện chạy".

```bash
# ingress-nginx + metrics-server: cài bởi scripts/kind-up.sh, không phải bước ở đây.

# Một lệnh (Giai đoạn 7). Bỏ ALERT_WEBHOOK_* nếu chưa có webhook — alert vẫn Firing nhưng không ai nhận
# (script sẽ cảnh báo). Cài kênh: docs/runbooks/alerting-setup.md.
./scripts/monitoring-install.sh kind

# Xem Prometheus/Grafana/Alertmanager qua port-forward (kind không có LoadBalancer):
kubectl --context kind-bss -n monitoring port-forward svc/monitoring-grafana 3000:80
kubectl --context kind-bss -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
kubectl --context kind-bss -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093
```

Kiểm tra: Prometheus UI (`:9090`) → Status → Targets → 5 target `bss-services` phải `UP` (4
backend + gateway). Grafana (`:3000`, user `admin`, mật khẩu: lệnh `kubectl … get secret grafana-admin`
mà script in ra cuối) → dashboard **BSS / BSS Microservices Overview** có số liệu thật. Webhook
Discord/Slack: `docs/runbooks/alerting-setup.md` và `docs/adr/ADR-001-alerting-channel.md`.
Unit test cho alert (không cần cluster): `./scripts/test-alert-rules.sh`.
