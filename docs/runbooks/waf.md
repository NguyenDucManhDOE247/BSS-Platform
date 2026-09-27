# Runbook: AWS WAF trước ALB (Giai đoạn 7, việc 7)

## 1. Bức tranh chung

`infrastructure/terraform/modules/waf/` tạo 1 `aws_wafv2_web_acl` scope `REGIONAL` cho mỗi env
(dev/staging/prod, mỗi cluster 1 Web ACL riêng — không dùng chung 1 ACL cho cả 3 vì rate-limit và
mức độ nghiêm khắc khác nhau theo môi trường). 4 rule, theo thứ tự priority:

| Priority | Rule | Nguồn | Chặn gì |
|---|---|---|---|
| 1 | `aws-common-rule-set` | AWS managed (`AWSManagedRulesCommonRuleSet`) | Các lỗi OWASP phổ biến (path traversal, oversized body, ...) |
| 2 | `aws-known-bad-inputs` | AWS managed (`AWSManagedRulesKnownBadInputsRuleSet`) | Pattern khai thác đã biết (log4j, request rác...) |
| 3 | `aws-sqli-rule-set` | AWS managed (`AWSManagedRulesSQLiRuleSet`) | SQL injection trong query string/body/header |
| 4 | `rate-limit-per-ip` | Tự viết (`rate_based_statement`) | > `rate_limit_per_5min` request/5 phút từ 1 IP (dev/staging 2000, prod 1000) |

`default_action = allow` — chỉ 4 rule trên mới chặn, mọi request khác đi qua.

**Vì sao KHÔNG có `aws_wafv2_web_acl_association` trong Terraform:** ALB trong repo này không phải
resource Terraform — AWS Load Balancer Controller tự tạo/xóa nó từ object `Ingress`
(`infrastructure/kubernetes/base/ingress.yaml`), Terraform không bao giờ biết ARN của ALB đó để
`resource_arn` trỏ vào. Controller hỗ trợ sẵn annotation `alb.ingress.kubernetes.io/wafv2-acl-arn`
để tự làm việc association — `scripts/wire-waf.sh` chỉ gắn annotation đó lên Ingress đang chạy rồi
xác nhận thật qua `aws wafv2 get-web-acl-for-resource`, không hardcode ARN vào overlay Kustomize
(ARN đổi mỗi lần Web ACL bị tạo lại, giống bài học RDS hostname ở ADR-004).

Quyền IAM cho ALB Controller gọi WAF API đã có sẵn từ trước (B-35) — policy chính thức AWS
(`modules/platform-iam/main.tf`, `data.http.alb_controller_policy`) vốn đã bao gồm cả nhóm quyền
`wafv2:*Association`/`wafv2:GetWebACL*`, không cần thêm gì.

## 2. Trình tự chạy thật (sau `terraform apply` + `platform-install.sh` + deploy)

```bash
make ENV=dev tf-apply                 # tạo Web ACL cùng lúc với VPC/EKS/RDS/...
./scripts/platform-install.sh dev     # ALB Controller (đã có sẵn quyền WAF, xem trên)
kubectl apply -k infrastructure/kubernetes/overlays/dev   # tạo Ingress -> Controller tạo ALB
make ENV=dev wire-waf                 # gắn Web ACL vào ALB vừa tạo, tự xác nhận qua AWS API thật
```

## 3. Tự kiểm chứng THẬT — WAF có thật sự chặn traffic qua ALB không

`kubectl annotate` (hay bất kỳ lệnh AWS API nào báo "thành công") không tự chứng minh traffic thật
bị chặn — giống bài học ở `docs/runbooks/network-policy.md` §2 (object lưu vào etcd/AWS không đồng
nghĩa enforcement đúng). Test bằng chính ALB DNS name thật:

```bash
HOST="$(kubectl -n bss get ingress bss-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

# (a) Request bình thường — phải KHÔNG bị WAF chặn (403 từ WAF có header x-amzn-waf-action,
#     phân biệt được với 503/502 do backend chưa healthy — vẫn OK cho việc này vì mục tiêu là
#     chứng minh WAF CHO QUA, không phải chứng minh app chạy đúng)
curl -s -o /dev/null -w '%{http_code}\n' "http://$HOST/api/tmf-api/productCatalog/v4/productOffering"

# (b) SQL injection trong query string — PHẢI bị chặn bởi aws-sqli-rule-set (403)
curl -s -o /dev/null -w '%{http_code}\n' "http://$HOST/api/tmf-api/customerManagement/v4/customer?id=1%27%20OR%20%271%27%3D%271"

# (c) Rate limit — gửi > rate_limit_per_5min request nhanh từ 1 IP, PHẢI thấy 403 xuất hiện trước
#     khi đạt hết vòng lặp (dev/staging limit 2000 — dùng số nhỏ hơn để test nhanh nếu muốn, xem §4)
for i in $(seq 1 50); do curl -s -o /dev/null -w '%{http_code} ' "http://$HOST/"; done; echo
```

Phân biệt request bị WAF chặn với lỗi backend thường: response WAF-block có header
`x-amzn-waf-action` (xem bằng `curl -sD - -o /dev/null ...`) — nếu chỉ nhìn mã 403 không đủ, vì
backend cũng có thể tự trả 403.

**Kết quả đã tự chạy thật (điền sau khi verify trên cluster dev thật — xem
`learning/nhat-ky-hoc-tap.md` mục Giai đoạn 7 việc 7):**

| Kịch bản | Kỳ vọng | Kết quả thật |
|---|---|---|
| Request bình thường | Đi qua WAF (không có `x-amzn-waf-action`) | _điền sau_ |
| SQLi trong query string | 403, có `x-amzn-waf-action: block` | _điền sau_ |
| > rate limit từ 1 IP | 403 sau khi vượt ngưỡng | _điền sau_ |

## 4. Sự cố hay gặp

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| `wire-waf.sh` timeout ở bước "chờ Ingress có hostname" | ALB Controller chưa cài hoặc lỗi IAM | `kubectl -n kube-system logs deploy/aws-load-balancer-controller`; xem lại `platform-install.sh` bước 3 |
| `wire-waf.sh` timeout ở bước "xác nhận association" dù annotate không báo lỗi | Controller cần thêm 1-2 phút để reconcile; hoặc annotation bị gõ sai key | `kubectl -n bss get ingress bss-ingress -o yaml \| grep wafv2`; kiểm đúng key `alb.ingress.kubernetes.io/wafv2-acl-arn` |
| Mọi request đều 403 kể cả request hợp lệ | `AWSManagedRulesCommonRuleSet` quá chặt cho payload nghiệp vụ thật (ví dụ body JSON lớn, hoặc field tên trùng pattern nhạy cảm) | Xem CloudWatch metric/sampled request của rule đó (`visibility_config` đã bật `sampled_requests_enabled`); cân nhắc `rule_action_override` để set rule con về `count` thay vì `block` nếu false positive |
| Muốn test rate-limit nhanh hơn không đợi cả 2000 request | `rate_based_statement` có ngưỡng tối thiểu AWS cho phép (100) | Tạm sửa `rate_limit_per_5min` trong `environments/dev/main.tf` xuống 100, `terraform apply`, test xong trả lại 2000 |
| Cluster bị `tf-destroy` xong dựng lại — annotation cũ trên Ingress cũ mất theo, ARN Web ACL mới cũng khác | Đúng thiết kế (Giai đoạn 5 pattern: mọi thứ dev là ephemeral) | Chạy lại `make ENV=dev wire-waf` sau mỗi lần dựng lại cluster + deploy — không tự động, chưa đưa vào CD (xem việc còn lại) |

## 5. Việc còn lại / deferred

- `wire-waf.sh` chưa được gọi tự động trong `cd-dev.yml` — mỗi lần cluster dev dựng lại từ đầu cần
  chạy tay 1 lần. Đưa vào CD là một cải tiến riêng, không phải phần bắt buộc của việc 7.
- Chưa bật WAF logging (`aws_wafv2_web_acl_logging_configuration` → CloudWatch Logs) — thêm nếu
  cần điều tra chi tiết request bị chặn thay vì chỉ xem metric CloudWatch.
- CLAUDE.md LỚP 2 vẽ `CloudFront → ALB → AWS WAF` — CloudFront chưa tồn tại (domain/HTTPS bị hoãn,
  xem memory `bss-platform-phase0-decisions` mục 4), nên hôm nay WAF (`scope = REGIONAL`) nằm thẳng
  trên ALB. Nếu sau này thêm CloudFront, WAF cho CloudFront cần 1 Web ACL **riêng** với
  `scope = CLOUDFRONT` (khác region, luôn phải là `us-east-1`) — không dùng lại ACL này.
