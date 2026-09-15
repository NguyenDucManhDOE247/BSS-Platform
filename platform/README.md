# Platform addons

Components in this folder are **cluster-wide infrastructure** (not application code).
They are installed once per EKS cluster, typically via Helm.

## Install order

After `terraform apply` finishes and `aws eks update-kubeconfig` is set:

```bash
# 1. AWS Load Balancer Controller (creates ALBs from Ingress resources)
helm repo add eks https://aws.github.io/eks-charts
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system -f networking/aws-load-balancer-controller-values.yaml \
  --set clusterName=bss-dev-eks \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform -chdir=../infrastructure/terraform/environments/dev output -raw aws_lb_controller_role_arn)

# 2. External DNS (auto-creates Route 53 records)
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm upgrade --install external-dns external-dns/external-dns \
  -n kube-system -f networking/external-dns-values.yaml

# 3. Karpenter (auto-provisioner for workload nodes)
helm repo add karpenter oci://public.ecr.aws/karpenter
helm upgrade --install karpenter karpenter/karpenter \
  -n karpenter --create-namespace
kubectl apply -f networking/karpenter-nodepool.yaml

# 4. Secrets Store CSI Driver
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system -f secrets/secrets-store-csi-values.yaml
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml

# 5. Fluent Bit (logs → CloudWatch)
helm upgrade --install fluent-bit eks/aws-for-fluent-bit \
  -n amazon-cloudwatch --create-namespace \
  -f logging/fluent-bit-values.yaml

# 6. OpenTelemetry Collector (traces → X-Ray)
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  -n observability --create-namespace \
  -f tracing/otel-collector-values.yaml

# 7. Prometheus + Grafana
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

> The `Makefile` wraps these into `make platform-install`.

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
