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
# EBS CSI driver (B-41's IAM half). Also NOT included: ExternalDNS, Karpenter, Fluent Bit, OTel
# Collector, Prometheus/Grafana — later phases (Giai đoạn 6/7/8, see learning/20) that need a real
# domain, a spot-capacity decision, or aren't load-bearing for "7 service chạy + ALB" yet.
#
# Usage: ./scripts/platform-install.sh [dev|staging|prod]
set -euo pipefail

ENV="${1:-dev}"
REGION="${AWS_REGION:-ap-southeast-1}"
TF_DIR="infrastructure/terraform/environments/$ENV"
CLUSTER="bss-$ENV-eks"

echo "=== 1/4 — kubeconfig for $CLUSTER ==="
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

echo ""
echo "=== 2/4 — AWS Load Balancer Controller (creates the ALB from Ingress) ==="
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null
# Chart/app version 3.5.0 MUST match the iam_policy.json version pinned in
# infrastructure/terraform/modules/platform-iam/main.tf — see the comment there.
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 3.5.0 \
  -n kube-system -f platform/networking/aws-load-balancer-controller-values.yaml \
  --set clusterName="$CLUSTER" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$(terraform -chdir="$TF_DIR" output -raw aws_lb_controller_role_arn)"

echo ""
echo "=== 3/4 — gp3 StorageClass (B-41: EKS ships none by default) ==="
kubectl apply -f platform/storage/storageclass-gp3.yaml

echo ""
echo "=== 4/4 — Secrets Store CSI Driver + AWS provider (B-20: per-service RDS credentials) ==="
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts >/dev/null 2>&1 || true
helm repo update secrets-store-csi-driver >/dev/null
helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --version 1.6.1 \
  -n kube-system -f platform/secrets/secrets-store-csi-values.yaml
# Pinned to a release tag, not "main" (B-42) — an unpinned branch can change under you between
# two runs of this exact same script with no changelog to check.
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/3.1.4/deployment/aws-provider-installer.yaml

echo ""
echo "✓ Addons installed. metrics-server + EBS CSI driver already came from Terraform"
echo "  (aws_eks_addon) — nothing to do for those here."
echo ""
echo "Next: kubectl apply -k infrastructure/kubernetes/overlays/$ENV"
