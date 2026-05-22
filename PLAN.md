# Business Support System (BSS) Platform on GKE - Kế hoạch triển khai chi tiết

Tài liệu này trình bày kế hoạch chi tiết để xây dựng, triển khai và vận hành hệ thống BSS (Business Support System) dựa trên kiến trúc Microservices trên nền tảng Google Kubernetes Engine (GKE).

---

## 1. Mục tiêu hệ thống
*   **Scalability**: Khả năng mở rộng linh hoạt theo tải trọng thực tế.
*   **Resilience**: Đảm bảo tính sẵn sàng cao (High Availability) cho các nghiệp vụ viễn thông quan trọng.
*   **Compliance**: Tuân thủ tiêu chuẩn ngành (TM Forum Open APIs).
*   **Observability**: Giám sát toàn diện hiệu năng và lỗi hệ thống.
*   **Automation**: Tự động hoá hoàn toàn luồng hạ tầng (IaC) và ứng dụng (CI/CD).

## 2. Kiến trúc tổng thể

### 2.1. Lớp hạ tầng (GCP Infrastructure)
*   **Compute**: GKE Autopilot (ưu tiên sự đơn giản và tối ưu chi phí) hoặc GKE Standard (nếu cần tùy chỉnh sâu Node).
*   **Database**: Cloud SQL (PostgreSQL) cho dữ liệu có cấu trúc.
*   **Caching**: Cloud Memorystore (Redis).
*   **Messaging**: Google Cloud Pub/Sub cho truyền thông bất đồng bộ giữa các microservices.
*   **Networking**: Shared VPC, Cloud NAT, Cloud DNS, Private Service Connect.
*   **Security**: Workload Identity (để dịch vụ K8s truy cập tài nguyên GCP không cần key), IAM.

### 2.2. Lớp Microservices (Domain Design)
Hệ thống được thiết kế theo các domain chuẩn TM Forum:
1.  **Customer Service (TMF629)**: Quản lý thông tin khách hàng, định danh và hồ sơ.
2.  **Product Catalog (TMF620)**: Quản lý danh mục gói cước, sản phẩm và chính sách giá.
3.  **Order Management (TMF622)**: Tiếp nhận và điều phối quy trình thực hiện đơn hàng.
4.  **Billing & Invoicing (TMF678)**: Tính cước, tạo hóa đơn và xử lý thanh toán.

### 2.3. Tech Stack
*   **Backend**: Java 21, Spring Boot 3.3+.
*   **API**: RESTful API, tài liệu Swagger/OpenAPI.
*   **Container**: Docker, Google Artifact Registry.
*   **IaC**: Terraform.
*   **CI/CD**: GitHub Actions.
*   **Observability**: Prometheus, Grafana, Cloud Logging, Cloud Trace.

---

## 3. Lộ trình triển khai (6 Giai đoạn)

### Giai đoạn 1: Thiết lập nền tảng & Local Development
*   Thiết lập môi trường phát triển (JDK 21, Docker, Terraform, gcloud CLI).
*   Phát triển Microservice đầu tiên (`customer-service`) với đầy đủ kết nối Database local.
*   Xây dựng Docker image chuẩn hóa và tối ưu.

### Giai đoạn 2: Hạ tầng như một đoạn mã (IaC với Terraform)
*   Tạo tài khoản dịch vụ (Service Account) và phân quyền IAM.
*   Viết code Terraform để tự động hóa việc tạo VPC, Subnets.
*   Provision cụm GKE Autopilot và instance Cloud SQL.
*   Thiết lập Artifact Registry để quản lý image.

### Giai đoạn 3: Triển khai lên Kubernetes
*   Viết manifest K8s (Deployment, Service, HPA, PDB) sử dụng **Kustomize**.
*   Cấu hình Workload Identity để microservice kết nối DB an toàn.
*   Thiết lập Ingress (Cloud Load Balancer) để public API ra ngoài.
*   Cấu hình cơ chế Health Check (Liveness/Readiness/Startup Probes).

### Giai đoạn 4: Tự động hóa CI/CD
*   Xây dựng Pipeline trên GitHub Actions:
    *   **CI**: Unit test, Linting, Build image, Security scan (Trivy/GCP Scan).
    *   **CD**: Tự động deploy lên môi trường Dev/Staging sau khi test pass.
*   Áp dụng chiến lược triển khai an toàn (Rolling Update hoặc Blue/Green).

### Giai đoạn 5: Giám sát & Quản trị (Observability)
*   Triển khai cụm Prometheus & Grafana lên K8s.
*   Xây dựng Dashboard theo dõi các chỉ số quan trọng (CPU, RAM, Request Rate, Error Rate).
*   Thiết lập cảnh báo (Alertmanager) gửi về Slack/Telegram khi có sự cố.
*   Tích hợp Cloud Trace để theo dõi vết yêu cầu xuyên suốt các service.

### Giai đoạn 6: Mở rộng Domain & Mesh
*   Tiếp tục phát triển các service còn lại (`Product`, `Order`, `Billing`).
*   Triển khai Pub/Sub để xử lý các nghiệp vụ event-driven (ví dụ: tạo hóa đơn sau khi đơn hàng hoàn tất).
*   (Tùy chọn) Triển khai Istio/Anthos Service Mesh nếu số lượng service tăng lên đáng kể.

---

## 4. Quản lý chi phí (Cost Optimization)
*   Sử dụng **GKE Autopilot** để chỉ trả phí cho CPU/RAM mà Pod thực tế sử dụng.
*   Sử dụng **Cloud SQL Proxy** hoặc **Sidecar** để tối ưu kết nối.
*   Thiết lập **Horizontal Pod Autoscaler (HPA)** để giảm số lượng Pod vào giờ thấp điểm.
*   Áp dụng **Cloud Storage Lifecycle** cho các bản build cũ trong Artifact Registry.

---

## 5. Danh sách công việc ưu tiên (Action Items)
1.  [ ] Hoàn thiện Code cơ bản cho `customer-service`.
2.  [ ] Thực thi lệnh `terraform apply` để tạo hạ tầng thô.
3.  [ ] Thiết lập CI/CD luồng Build & Push image.
4.  [ ] Deploy bản stable đầu tiên lên GKE.

---
*Tài liệu này được tạo bởi Antigravity AI Assistant.*
