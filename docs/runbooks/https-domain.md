# Runbook: tên miền + HTTPS trên AWS (B-23, ADR-012)

Tên miền: **`bssplatform.dpdns.org`** (DigitalPlat, hết hạn **2027-10-01** — gia hạn miễn phí trong 120 ngày cuối).

| Môi trường | URL | Subnet public (NetworkPolicy ALB → Keycloak) |
|---|---|---|
| dev | `https://dev.bssplatform.dpdns.org` | `10.10.0.0/22` |
| staging | `https://staging.bssplatform.dpdns.org` | `10.20.0.0/22` |
| prod | `https://bssplatform.dpdns.org` (apex) | `10.30.0.0/22` |

Trong mỗi host: `/` web-portal, `/admin/` admin-console, `/api` api-gateway, `/auth/realms` + `/auth/resources`
Keycloak. **Không** có `/auth/admin` (quản trị Keycloak: `kubectl -n bss port-forward svc/keycloak 18080:8080`
→ `http://127.0.0.1:18080/auth/admin/`, mật khẩu ở Secret `keycloak-admin` — xem [auth.md](auth.md)).

## 1. Một lần cho cả account: zone + cert (state `shared`)

```bash
make ENV=shared tf-plan          # + zone, cert (PENDING_VALIDATION), bản ghi CNAME xác thực
make ENV=shared tf-apply
terraform -chdir=infrastructure/terraform/environments/shared output dns_name_servers
```

Vào DigitalPlat → *Domains* → `bssplatform.dpdns.org` → **Use other nameservers** → nhập cả 4 NS `ns-*.awsdns-*`
(bỏ dấu chấm cuối nếu form không nhận). Kiểm lan truyền:

```bash
dig NS bssplatform.dpdns.org +short @1.1.1.1      # phải thấy 4 dòng awsdns-*
```

Rồi đặt `dns_delegated = true` trong `environments/shared/terraform.tfvars`, plan + apply lần 2 — Terraform
chờ tới khi cert `ISSUED` (thường 2–10 phút sau khi NS đã lan truyền):

```bash
aws acm list-certificates --region ap-southeast-1 \
  --query "CertificateSummaryList[?DomainName=='bssplatform.dpdns.org'].[Status,CertificateArn]" --output text
```

## 2. Mỗi lần dựng môi trường

Không có bước nào mới so với trước: `tf-apply` (tạo role `bss-<env>-external-dns`) → `scripts/platform-install.sh <env>`
(bước 7/7 cài ExternalDNS) → CD/`kubectl apply -k`. Kiểm:

```bash
kubectl -n kube-system logs deploy/external-dns | grep -E 'Desired change|CREATE|error'   # CREATE A + TXT
kubectl -n bss get ingress bss-ingress            # HOSTS = host môi trường, ADDRESS = ALB
dig +short dev.bssplatform.dpdns.org @1.1.1.1      # IP của ALB (alias)
./scripts/smoke.sh dev                             # 3 kiểm HTTPS + 4 kiểm API
./scripts/netpol-matrix.sh "$(kubectl config current-context)"
```

> Mở trình duyệt **sau** khi `dig` đã ra IP. Hỏi quá sớm thì resolver nhớ NXDOMAIN tới 15 phút (TTL âm của SOA
> Route 53) — đổi resolver (1.1.1.1/8.8.8.8) hoặc chờ.

## 3. Mỗi lần phá môi trường

`scripts/teardown.sh <env>` đã xóa Ingress trước rồi **chờ ExternalDNS xóa bản ghi** (≤ 3 phút). Zone + cert
ở lại (CỐ Ý). Sau đó `python tools/ops/orphan_finder.py` — mục `DNS record` = bản ghi của cluster đã chết.
Dọn tay (thay `<zone-id>`, `<name>`; xóa cả bản ghi A alias lẫn TXT `a-<name>`):

```bash
aws route53 list-resource-record-sets --hosted-zone-id <zone-id> --query "ResourceRecordSets[?contains(Name,'<name>')]"
# rồi change-resource-record-sets với Action=DELETE và đúng nguyên giá trị vừa liệt kê
```

## 4. Sự cố thường gặp

| Triệu chứng | Nguyên nhân | Kiểm / sửa |
|---|---|---|
| Ingress không có `ADDRESS`, `describe ingress` báo *no certificate found for host* | Cert chưa `ISSUED` (chưa làm bước 1 lần 2) hoặc host không khớp cert (vd. `a.dev.<miền>` — wildcard chỉ phủ 1 cấp) | Bước 1; `aws acm describe-certificate` |
| `dig` trả NXDOMAIN dù Ingress có ADDRESS | ExternalDNS chưa cài / thiếu quyền | Log ExternalDNS: `AccessDenied` → host không nằm trong `external_dns_hostnames` của role (Terraform môi trường) |
| Trang đăng nhập Keycloak: *HTTPS required* | Keycloak không thấy `X-Forwarded-Proto` | `KC_PROXY_HEADERS=xforwarded` có trong Pod? (`components/keycloak-aws`) |
| Đăng nhập xong API trả 401, log Spring: *The iss claim is not valid* | `KC_HOSTNAME` của overlay ≠ `…_JWT_ISSUER_URI` | So `curl https://<host>/auth/realms/bss/.well-known/openid-configuration \| jq .issuer` với ConfigMap |
| 502 trên `/auth/*` | Target Keycloak unhealthy | `aws elbv2 describe-target-health`; NetworkPolicy `allow-to-keycloak` có `ipBlock` đúng dải subnet public của môi trường? |
| Keycloak báo *Invalid parameter: redirect_uri* | Host chưa có trong realm | `components/keycloak-realm/bss-realm.json` — realm chỉ import khi DB Keycloak trống (môi trường mới) |
| ACM kẹt `PENDING_VALIDATION` lâu | NS chưa lan truyền, hoặc CAA ở miền cha chặn Amazon | `dig NS`; `dig CAA dpdns.org` (2026-10-01: không có CAA) |
