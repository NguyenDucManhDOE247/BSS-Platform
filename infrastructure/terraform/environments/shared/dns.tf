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

# Apex và wildcard dùng CHUNG 1 bản ghi CNAME xác thực (ACM sinh cùng tên) → gom theo tên bản ghi để không
# tạo 2 resource ghi đè nhau.
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in flatten([for c in aws_acm_certificate.main : c.domain_validation_options]) :
    dvo.resource_record_name => dvo...
  }

  zone_id = aws_route53_zone.main[0].zone_id
  name    = each.value[0].resource_record_name
  type    = each.value[0].resource_record_type
  records = [each.value[0].resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "main" {
  count = local.dns_enabled && var.dns_delegated ? 1 : 0

  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]

  timeouts {
    create = "30m"
  }
}
