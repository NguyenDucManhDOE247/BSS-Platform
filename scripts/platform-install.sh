#!/usr/bin/env bash
# Giai đoạn 5: installs the cluster addons a freshly-`terraform apply`'d EKS cluster needs before
# `kubectl apply -k infrastructure/kubernetes/overlays/$ENV` will actually work end-to-end.
#
# Mirrors platform/README.md's "Phase 5 (dev minimum)" section exactly — read that file for the
# "why" behind each addon; this script exists so the sequence is one command instead of
# copy-pasting ~10 lines by hand and risking the order, a version flag, or the clusterName
# --set getting typo'd (B-60: "Makefile platform-install" used to just `echo` a pointer to the
# README with nothing to actually run).
#
# NOT included here (first-class Terraform-managed EKS addons instead — see
# infrastructure/terraform/modules/eks/main.tf's aws_eks_addon resources): metrics-server (B-43),
# EBS CSI driver (B-41's IAM half). Also NOT included: Fluent Bit, OTel Collector, Prometheus/Grafana
# (their own scripts/*-install.sh). Karpenter (ADR-010) and ExternalDNS (B-23, ADR-012) ARE included,
# each skipped when the Terraform outputs say the environment doesn't use it.
#
# Usage: ./scripts/platform-install.sh [dev|staging|prod]
set -euo pipefail

ENV="${1:-dev}"
REGION="${AWS_REGION:-ap-southeast-1}"
TF_DIR="infrastructure/terraform/environments/$ENV"
CLUSTER="bss-$ENV-eks"

# Chart được tải bằng curl (có retry) rồi cài từ FILE, không qua `helm repo add` + tên chart: trình tải của Helm
# không retry, và trong WSL nó lúc được lúc treo 120 s ở "awaiting headers" khi lấy .tgz từ GitHub Pages (gặp lại
# 2026-10-05 khi dựng staging — cùng URL đó curl lấy trong 0,4 s). Phiên bản vẫn ghim: nó nằm trong tên file.
CHART_DIR="$(mktemp -d)"
trap 'rm -rf "$CHART_DIR"' EXIT
fetch_chart() {
  local url="$1" out
  out="$CHART_DIR/${url##*/}"
  curl -fsSL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 60 -o "$out" "$url"
  echo "$out"
}

echo "=== 1/7 — kubeconfig for $CLUSTER ==="
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

echo ""
echo "=== 2/7 — namespace bss (with Pod Security labels) ==="
# Giai đoạn 6: the CD deployer role can only touch objects INSIDE namespace `bss` (namespace-scoped
# EKS access policy), and a Namespace is cluster-scoped — so overlays/{dev,staging,prod} drop it
# from what `kubectl apply -k` sends (see the `$patch: delete` at the top of their `patches:`), and
# this admin-run script creates it instead, once per cluster. Idempotent.
kubectl apply -f infrastructure/kubernetes/base/namespace.yaml

echo ""
echo "=== 3/7 — AWS Load Balancer Controller (creates the ALB from Ingress) ==="
# Chart/app version 3.5.0 MUST match the iam_policy.json version pinned in
# infrastructure/terraform/modules/platform-iam/main.tf — see the comment there.
helm upgrade --install aws-load-balancer-controller \
  "$(fetch_chart https://aws.github.io/eks-charts/aws-load-balancer-controller-3.5.0.tgz)" \
  -n kube-system -f platform/networking/aws-load-balancer-controller-values.yaml \
  --set clusterName="$CLUSTER" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$(terraform -chdir="$TF_DIR" output -raw aws_lb_controller_role_arn)"

echo ""
echo "=== 4/7 — gp3 StorageClass (B-41: EKS ships none by default) ==="
kubectl apply -f platform/storage/storageclass-gp3.yaml

echo ""
echo "=== 5/7 — Secrets Store CSI Driver + AWS provider (B-20: per-service RDS credentials) ==="
helm upgrade --install csi-secrets-store \
  "$(fetch_chart https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts/secrets-store-csi-driver-1.6.1.tgz)" \
  -n kube-system -f platform/secrets/secrets-store-csi-values.yaml
# Pinned to a release tag, not "main" (B-42) — an unpinned branch can change under you between
# two runs of this exact same script with no changelog to check.
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/3.1.4/deployment/aws-provider-installer.yaml

echo ""
echo "=== 6/7 — Karpenter (ADR-010 — chỉ môi trường có enable_karpenter trong Terraform) ==="
# Version PHẢI khớp template IAM đã dịch trong modules/platform-iam/karpenter.tf (xem comment ở đó).
KARPENTER_VERSION="1.14.1"
KARPENTER_ROLE="$(terraform -chdir="$TF_DIR" output -raw karpenter_role_arn 2>/dev/null || true)"
if [ -n "$KARPENTER_ROLE" ] && [ "$KARPENTER_ROLE" != "null" ]; then
  helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
    --version "$KARPENTER_VERSION" -n kube-system \
    --set settings.clusterName="$CLUSTER" \
    --set settings.interruptionQueue="$(terraform -chdir="$TF_DIR" output -raw karpenter_interruption_queue)" \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$KARPENTER_ROLE" \
    --set controller.resources.requests.cpu=250m --set controller.resources.requests.memory=512Mi \
    --set controller.resources.limits.cpu=1 --set controller.resources.limits.memory=512Mi \
    --set replicas=1 \
    --wait
  # CRD NodePool/EC2NodeClass do chart vừa cài — áp sau `--wait` để API đã nhận CRD.
  sed "s/__CLUSTER__/$CLUSTER/g" platform/networking/karpenter-nodepool.yaml | kubectl apply -f -
  kubectl wait --for=condition=Ready ec2nodeclass/default --timeout=120s
else
  echo "(bỏ qua — $ENV không bật Karpenter; node group cố định, ADR-006/010)"
fi

echo ""
echo "=== 7/7 — ExternalDNS (B-23, ADR-012 — bản ghi Route 53 cho host của Ingress) ==="
EXTERNAL_DNS_ROLE="$(terraform -chdir="$TF_DIR" output -raw external_dns_role_arn 2>/dev/null || true)"
if [ -n "$EXTERNAL_DNS_ROLE" ] && [ "$EXTERNAL_DNS_ROLE" != "null" ]; then
  helm upgrade --install external-dns \
    "$(fetch_chart https://github.com/kubernetes-sigs/external-dns/releases/download/external-dns-helm-chart-1.23.0/external-dns-1.23.0.tgz)" \
    -n kube-system -f platform/networking/external-dns-values.yaml \
    --set txtOwnerId="$CLUSTER" \
    --set "domainFilters={$(terraform -chdir="$TF_DIR" output -raw dns_zone_name)}" \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$EXTERNAL_DNS_ROLE" \
    --wait
  echo "  host công khai: https://$(terraform -chdir="$TF_DIR" output -raw public_hostname)"
else
  echo "(bỏ qua — state shared chưa có zone Route 53; xem infrastructure/terraform/environments/shared/dns.tf)"
fi

echo ""
echo "✓ Addons installed. metrics-server + EBS CSI driver already came from Terraform"
echo "  (aws_eks_addon) — nothing to do for those here."
echo ""
echo "Next: kubectl apply -k infrastructure/kubernetes/overlays/$ENV"
