# ── Tên miền + HTTPS (B-23, ADR-012) ────────────────────────────────────
# Hosted zone + certificate ACM nằm ở SHARED, không ở dev/staging/prod, vì chúng phải SỐNG LÂU HƠN mọi
# môi trường ephemeral (ADR-006):
#   - Zone: mỗi zone mới được AWS cấp 4 name server MỚI. Nếu zone đi theo môi trường thì mỗi buổi dựng lại
#     phải vào DigitalPlat sửa NS bằng tay rồi chờ lan truyền — đúng loại bước tay hay quên/sai.
#   - Cert: xác thực DNS mất vài phút; cert dùng chung (apex + wildcard) cho cả 3 môi trường thì cấp 1 lần,
#     ACM tự gia hạn miễn là bản ghi CNAME xác thực còn trong zone.
# Chi phí: zone $0.50/tháng + truy vấn ($0.40/triệu); cert ACM public miễn phí.
#
# Áp dụng 2 bước (cert chỉ được ACM cấp khi DNS công khai đã trỏ về zone này):
#   1. `terraform apply` (dns_delegated = false) → tạo zone + cert (PENDING_VALIDATION) + bản ghi xác thực.
#      Lấy NS: `terraform output dns_name_servers` → nhập vào DigitalPlat "Use other nameservers".
#   2. Khi `dig NS bssplatform.dpdns.org +short` trả về awsdns-* → đặt dns_delegated = true, apply lại:
#      Terraform chờ tới khi cert ISSUED.

locals {
  dns_enabled = var.domain_name != ""
}

resource "aws_route53_zone" "main" {
  count = local.dns_enabled ? 1 : 0

  name    = var.domain_name
  comment = "BSS Platform — dùng chung dev/staging/prod (ADR-012). Bản ghi A do ExternalDNS từng cluster quản lý."

  tags = local.common_tags
}

resource "aws_acm_certificate" "main" {
  count = local.dns_enabled ? 1 : 0

  domain_name = var.domain_name
  # Wildcard phủ dev.<domain>, staging.<domain> (1 cấp — không phủ a.b.<domain>); apex cho prod.
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# Khóa for_each = 2 tên KHAI BÁO trong cấu hình (biết chắc lúc plan). Lỗi thật ở 2 lần plan đầu (2026-10-01,
# "Invalid for_each argument"): khóa theo tên bản ghi, rồi theo dvo.domain_name, đều hỏng — cert dùng
# `count` nên CẢ tập domain_validation_options là "unknown" tới khi cert được tạo. Giá trị (tên/kiểu/nội
# dung bản ghi) được phép unknown lúc plan, chỉ khóa thì không. Apex và wildcard ra CÙNG 1 bản ghi CNAME
# → 2 resource ghi cùng giá trị, cần allow_overwrite.
locals {
  cert_names = local.dns_enabled ? [var.domain_name, "*.${var.domain_name}"] : []
}

resource "aws_route53_record" "acm_validation" {
  for_each = toset(local.cert_names)

  allow_overwrite = true
  zone_id         = aws_route53_zone.main[0].zone_id
  name            = one([for d in aws_acm_certificate.main[0].domain_validation_options : d.resource_record_name if d.domain_name == each.key])
  type            = one([for d in aws_acm_certificate.main[0].domain_validation_options : d.resource_record_type if d.domain_name == each.key])
  records         = [one([for d in aws_acm_certificate.main[0].domain_validation_options : d.resource_record_value if d.domain_name == each.key])]
  ttl             = 300
}

resource "aws_acm_certificate_validation" "main" {
  count = local.dns_enabled && var.dns_delegated ? 1 : 0

  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]

  timeouts {
    create = "30m"
  }
}
