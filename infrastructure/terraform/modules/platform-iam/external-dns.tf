# ── ExternalDNS (B-23, ADR-012) ──────────────────────────────────────────
# Tạo/xóa bản ghi Route 53 cho host của Ingress (alias A → ALB do ALB Controller dựng). Zone nằm ở state
# SHARED và dùng chung 3 môi trường, nên quyền phải hẹp hơn "sửa cả zone": mỗi cluster chỉ được ghi đúng
# tên của mình (`record_names`) — cluster staging bị chiếm cũng không chuyển hướng được apex của prod.
#
# `ChangeResourceRecordSetsNormalizedRecordNames` = tên bản ghi đã chuẩn hóa (chữ thường, không dấu chấm
# cuối) của MỌI thay đổi trong 1 lệnh gọi; `ForAllValues` → chỉ cần 1 tên ngoài danh sách là cả lệnh bị từ
# chối. Danh sách phải gồm cả bản ghi TXT "sở hữu" ExternalDNS tự tạo cạnh bản ghi chính — tên CHÍNH XÁC
# `extdns-<kiểu>.<host>` (`--txt-prefix=extdns-%{record_type}.` trong platform/networking/external-dns-values.yaml).
#
# Lỗi thật trên prod 2026-10-02: bản đầu dùng định dạng mặc định `a-<host>` + mẫu `*-<host>`. Ở dev/staging chạy
# đúng, nhưng với APEX `a-bssplatform.dpdns.org` nằm NGOÀI zone (anh em dưới dpdns.org) → ExternalDNS lặng lẽ bỏ TXT,
# chỉ tạo A/AAAA không chủ → xóa Ingress không xóa bản ghi (treo), teardown/orphan_finder (dò theo TXT) không
# thấy. Không dùng wildcard nữa: `*.bssplatform.dpdns.org` của prod sẽ phủ luôn tên của dev/staging.

resource "aws_iam_role" "external_dns" {
  count = var.external_dns_zone_id == null ? 0 : 1

  name = "${var.name_prefix}-external-dns"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.cluster_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = merge(local.oidc_trust_condition.StringEquals, {
          "${var.cluster_oidc_provider_url}:sub" = "system:serviceaccount:kube-system:external-dns"
        })
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "external_dns" {
  count = var.external_dns_zone_id == null ? 0 : 1

  name = "route53-own-records"
  role = aws_iam_role.external_dns[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ChangeOwnRecordsOnly"
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.external_dns_zone_id}"
        Condition = {
          "ForAllValues:StringLike" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = flatten([
              for h in var.external_dns_hostnames : concat([h], [for t in ["a", "aaaa", "cname"] : "extdns-${t}.${h}"])
            ])
          }
        }
      },
      {
        Sid      = "ReadZone"
        Effect   = "Allow"
        Action   = ["route53:ListResourceRecordSets", "route53:ListTagsForResources"]
        Resource = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.external_dns_zone_id}"
      },
      {
        # Không hỗ trợ giới hạn theo resource — ExternalDNS liệt kê zone để tìm zone khớp --domain-filter.
        Sid      = "ListZones"
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones"]
        Resource = "*"
      },
    ]
  })
}
