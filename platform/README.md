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
