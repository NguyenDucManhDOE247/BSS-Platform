# BSS Platform System Architecture

Tài liệu này mô tả chi tiết kiến trúc hệ thống **Business Support System (BSS) Platform** được triển khai dưới dạng Monorepo trong repo này. Hệ thống được thiết kế theo chuẩn viễn thông của **TM Forum Open APIs**, hoạt động trên hạ tầng **AWS EKS**, quản lý bằng **Terraform IaC** và có cơ chế **CI/CD** tự động hóa hoàn toàn.

---

## 1. Tổng Quan Kiến Trúc 5 Lớp (5-Layer Architecture)

Hệ thống được cấu trúc thành 5 lớp logic độc lập cùng với một lớp nền tảng (Platform) quản lý các tiện ích bổ trợ của EKS cluster:

```mermaid
graph TD
    %% Styling
    classDef client fill:#3498db,stroke:#2980b9,stroke-width:2px,color:#fff;
    classDef edge fill:#e67e22,stroke:#d35400,stroke-width:2px,color:#fff;
    classDef frontend fill:#9b59b6,stroke:#8e44ad,stroke-width:2px,color:#fff;
    classDef gateway fill:#1abc9c,stroke:#16a085,stroke-width:2px,color:#fff;
    classDef backend fill:#2ecc71,stroke:#27ae60,stroke-width:2px,color:#fff;
    classDef data fill:#f1c40f,stroke:#f39c12,stroke-width:2px,color:#2c3e50;
    classDef platform fill:#95a5a6,stroke:#7f8c8d,stroke-width:2px,color:#fff;

    %% Nodes
    subgraph L1["Lớp 1: Người Dùng (Clients)"]
        User["Web Browser / Mobile Client"]:::client
        Admin["Admin Staff / Operations"]:::client
    end

    subgraph L2["Lớp 2: Edge / Security"]
        CF["CloudFront (CDN)"]:::edge
        ALB["AWS Application Load Balancer (Ingress)"]:::edge
        WAF["AWS WAF (Web Application Firewall)"]:::edge
    end

    subgraph L3["Lớp 3: Frontend (EKS)"]
        WP["web-portal (Vite + React)"]:::frontend
        AC["admin-console (Vite + React)"]:::frontend
    end

    subgraph L4["Lớp 4: API Gateway"]
        GW["api-gateway (Spring Cloud Gateway)"]:::gateway
    end

    subgraph L5["Lớp 5: Backend Microservices (EKS)"]
        CS["customer-service (TMF629)"]:::backend
        PC["product-catalog (TMF620)"]:::backend
        OM["order-management (TMF622)"]:::backend
        BS["billing-service (TMF678)"]:::backend
    end

    subgraph L6["Lớp 6: Lưu trữ & Event Bus"]
        DB[("RDS PostgreSQL (Schema per service)")]:::data
        EB["AWS EventBridge (Custom Bus: bss-{env}-events)"]:::data
        SQS["AWS SQS (Queue: bss-{env}-billing-orders)"]:::data
        S3[("Amazon S3 (File/Blob)")]:::data
    end

    subgraph Platform["EKS Cluster Platform Addons"]
        Karpenter["Karpenter (Auto-scaler)"]:::platform
        Secrets["Secrets Store CSI Driver (Secrets Manager)"]:::platform
        Prom["Prometheus + Grafana (Metrics)"]:::platform
        Fluent["Fluent Bit (CloudWatch Logs)"]:::platform
        OTel["OTel Collector (AWS X-Ray Traces)"]:::platform
    end

    %% Connections
    User -->|HTTPS| CF
    Admin -->|HTTPS| CF
    CF --> WAF
    WAF --> ALB

    %% ALB Routing based on path
    ALB -->|Path: / | WP
    ALB -->|Path: /admin | AC
    ALB -->|Path: /api | GW

    %% Gateway Routing
    GW -->|/api/customers/** | CS
    GW -->|/api/products/** | PC
    GW -->|/api/orders/** | OM
    GW -->|/api/bills/** | BS

    %% Internal Sync Rest API (via Gateway DNS)
    OM -.->|REST /tmf-api/customerManagement| GW
    OM -.->|REST /tmf-api/productCatalog| GW

    %% DB Connections
    CS --->|customer schema| DB
    PC --->|product schema| DB
    OM --->|orders schema| DB
    BS --->|billing schema| DB

    %% Async Integrations
    OM -->|Publish events| EB
    EB -->|Routing Rules| SQS
    SQS -->|Consume events| BS

    %% Platform Integrations
    CS & PC & OM & BS & GW & WP & AC -.-> Karpenter
    CS & PC & OM & BS & GW -.-> Secrets
    CS & PC & OM & BS & GW -.-> Prom
    CS & PC & OM & BS & GW -.-> Fluent
    CS & PC & OM & BS & GW -.-> OTel
```

---

## 2. Luồng Nghiệp Vụ Hướng Sự Kiện (Event-Driven & Outbox Pattern)

Để đảm bảo tính nhất quán dữ liệu cuối cùng (**Eventual Consistency**) giữa các microservices độc lập mà không gây thắt nút cổ chai (bottleneck) hoặc lỗi liên hoàn (cascade failures), hệ thống áp dụng pattern **Transactional Outbox** cùng với **EventBridge** và **SQS**.

### Sơ đồ luồng Order Completed & Billing:

```mermaid
sequenceDiagram
    autonumber
    actor User as Khách Hàng
    participant WP as web-portal (Frontend)
    participant GW as api-gateway
    participant OM as order-management
    participant DB as PostgreSQL (orders DB)
    participant Publisher as OrderEventPublisher (Thread)
    participant EB as AWS EventBridge
    participant SQS as AWS SQS
    participant BS as billing-service
    participant BS_DB as PostgreSQL (billing DB)

    User->>WP: Click thanh toán giỏ hàng (Lite 30)
    WP->>GW: POST /api/tmf-api/orderManagement/v4/productOrder
    GW->>OM: POST /tmf-api/orderManagement/v4/productOrder
    
    Note over OM, DB: Bắt đầu Transaction (Atomic)
    activate OM
    OM->>DB: INSERT INTO product_order (trạng thái: InProgress)
    OM->>DB: INSERT INTO order_item (Lite 30, quantity=1, price=99000)
    OM->>DB: INSERT INTO event_outbox (aggregate_type: 'Order', event_type: 'OrderCompleted', payload: JSON)
    OM->>DB: COMMIT TRANSACTION
    deactivate OM
    
    OM-->>WP: HTTP 201 Created (Trả về thông tin ProductOrder)
    
    loop Cứ mỗi 1 giây (Scheduled Scheduler)
        Publisher->>DB: SELECT * FROM event_outbox WHERE published_at IS NULL (ORDER BY created_at)
        DB-->>Publisher: Trả về danh sách sự kiện chưa gửi
        activate Publisher
        Publisher->>EB: Publish Event (Source: 'bss.order', DetailType: 'OrderCompleted', MessageId)
        EB-->>Publisher: OK (Event ID nhận từ AWS)
        Publisher->>DB: UPDATE event_outbox SET published_at = now() WHERE id = event_id
        deactivate Publisher
    end

    Note over EB, SQS: EventBridge Rule khớp pattern: <br/> source: 'bss.order', detail-type: 'OrderCompleted'
    EB->>SQS: Đẩy sự kiện vào SQS Queue: bss-dev-billing-orders

    loop Nhận tin nhắn (SQS Message Listener)
        activate BS
        SQS->>BS: Nhận tin nhắn OrderCompleted
        
        Note over BS, BS_DB: Bắt đầu Transaction (Atomic)
        BS->>BS_DB: SELECT 1 FROM processed_event WHERE event_id = message_id
        alt Nếu event_id chưa tồn tại (Idempotency Check)
            BS->>BS_DB: INSERT INTO processed_event (event_id, event_type)
            BS->>BS_DB: SELECT * FROM billing_account WHERE customer_id = ...
            BS->>BS_DB: INSERT INTO invoice (billing_account_id, amount=99000, state: 'New')
            BS->>BS_DB: INSERT INTO invoice_item (invoice_id, unit_price=99000, amount=99000)
            BS->>BS_DB: COMMIT TRANSACTION
            BS->>SQS: Xóa tin nhắn khỏi Queue (Acknowledge)
        else Nếu event_id ĐÃ tồn tại
            Note over BS: Trùng lặp sự kiện! (Duplicate Event)
            BS->>BS_DB: ROLLBACK TRANSACTION (Bỏ qua xử lý)
            BS->>SQS: Xóa tin nhắn khỏi Queue (Không xử lý lại)
        end
        deactivate BS
    end
```

---

## 3. Mô Hình Thực Thể Dữ Liệu Chi Tiết (Database Schemas)

Hệ thống tuân thủ nguyên tắc **Database-per-Service**. Mỗi microservice sở hữu một database riêng biệt trong RDS PostgreSQL instance (phân tách schema cứng), không một service nào được phép truy cập trực tiếp vào DB của service khác. Dữ liệu liên thông hoàn toàn qua API RESTful sync hoặc Async Event Bus.

```mermaid
erDiagram
    %% customer-service Schema
    CUSTOMERS {
        uuid id PK
        varchar name
        varchar email UK
        varchar phone_number
        varchar status "Initialized | Active | Suspended"
        timestamptz created_at
        timestamptz updated_at
    }

    %% product-catalog Schema
    CATEGORY {
        uuid id PK
        varchar name
        text description
        uuid parent_id FK
        timestamptz created_at
        timestamptz updated_at
    }
    PRODUCT_SPECIFICATION {
        uuid id PK
        varchar name
        text description
        varchar version
        varchar lifecycle_status
        timestamptz created_at
        timestamptz updated_at
    }
    PRODUCT_OFFERING {
        uuid id PK
        varchar name
        text description
        uuid category_id FK
        uuid specification_id FK
        varchar lifecycle_status "Active | Retired"
        boolean is_bundle
        numeric price_amount
        char price_currency "VND"
        varchar recurring_period "monthly | yearly | one_time"
        timestamptz valid_for_start
        timestamptz valid_for_end
        timestamptz created_at
        timestamptz updated_at
    }

    %% order-management Schema
    PRODUCT_ORDER {
        uuid id PK
        uuid customer_id "Cross-Service Ref (customer)"
        varchar state "Acknowledged | InProgress | Completed | Cancelled | Failed"
        varchar category "new | upgrade | termination"
        text description
        numeric total_amount
        char currency "VND"
        timestamptz requested_start_date
        timestamptz requested_completion_date
        timestamptz completed_at
        timestamptz created_at
        timestamptz updated_at
    }
    ORDER_ITEM {
        uuid id PK
        uuid order_id FK
        uuid product_offering_id "Cross-Service Ref (offering)"
        varchar product_offering_name
        int quantity
        numeric unit_price
        varchar action "add | modify | remove"
    }
    EVENT_OUTBOX {
        uuid id PK
        varchar aggregate_type "Order | Customer"
        uuid aggregate_id
        varchar event_type "OrderCompleted | OrderRefunded"
        jsonb payload
        timestamptz created_at
        timestamptz published_at "NULL if not published yet"
    }

    %% billing-service Schema
    BILLING_ACCOUNT {
        uuid id PK
        uuid customer_id UK "Cross-Service Ref (customer)"
        varchar name
        varchar state "Active | Suspended | Closed"
        varchar payment_method "BankTransfer | CreditCard | Cash"
        char currency "VND"
        timestamptz created_at
        timestamptz updated_at
    }
    INVOICE {
        uuid id PK
        uuid billing_account_id FK
        varchar invoice_number UK
        varchar state "New | Validated | Paid | PartiallyPaid | Cancelled"
        numeric amount
        numeric tax_amount "10% VAT"
        char currency "VND"
        date invoice_date
        date due_date
        timestamptz paid_at
        timestamptz created_at
        timestamptz updated_at
    }
    INVOICE_ITEM {
        uuid id PK
        uuid invoice_id FK
        varchar description
        uuid source_order_id "Cross-Service Ref (order)"
        int quantity
        numeric unit_price
        numeric amount
    }
    PROCESSED_EVENT {
        varchar event_id PK "EventBridge Message ID"
        varchar event_type
        timestamptz processed_at
    }

    %% Relations across DBs (virtual or logical relationships)
    CUSTOMERS ||--o{ PRODUCT_ORDER : "places (Logical)"
    CUSTOMERS ||--|| BILLING_ACCOUNT : "has (Logical)"
    
    CATEGORY ||--o{ CATEGORY : "parent-child"
    CATEGORY ||--o{ PRODUCT_OFFERING : "groups"
    PRODUCT_SPECIFICATION ||--o{ PRODUCT_OFFERING : "specifies"
    
    PRODUCT_OFFERING ||--o{ ORDER_ITEM : "ordered_in (Logical)"
    
    PRODUCT_ORDER ||--|{ ORDER_ITEM : "contains"
    PRODUCT_ORDER ||--o{ INVOICE_ITEM : "billed_in (Logical)"
    
    BILLING_ACCOUNT ||--|{ INVOICE : "invoiced_to"
    INVOICE ||--|{ INVOICE_ITEM : "contains"
```

---

## 4. Kiến Trúc Hạ Tầng Trên AWS EKS (Deployment Topology)

Mô hình kiến trúc hạ tầng chạy trên AWS, được quản lý toàn diện thông qua mã nguồn **Terraform** trong thư mục `infrastructure/terraform`:

```mermaid
graph TD
    subgraph AWS["AWS Cloud (ap-southeast-1)"]
        subgraph VPC["VPC: bss-dev-vpc (10.0.0.0/16)"]
            
            subgraph Public["Public Subnets (Mỗi AZ 1 Subnet - Ingress Facing)"]
                Route53["Route 53 DNS"]
                ALB_AWS["AWS Application Load Balancer"]
            end

            subgraph Private_App["Private App Subnets (Mỗi AZ 1 Subnet - EKS Nodes)"]
                subgraph EKS["EKS Cluster (bss-dev-eks)"]
                    
                    subgraph K8s_System["kube-system Namespace"]
                        ALB_Ctrl["ALB Ingress Controller"]
                        ExtDNS["ExternalDNS"]
                        CSI["Secrets Store CSI Driver"]
                    end
                    
                    subgraph Karpenter_NS["karpenter Namespace"]
                        Kar["Karpenter Controller"]
                    end

                    subgraph BSS_NS["bss Namespace (Workloads)"]
                        subgraph FPods["Frontend Pods (Vite+React+Nginx)"]
                            WP_Pod["web-portal-pod"]
                            AC_Pod["admin-console-pod"]
                        end
                        
                        subgraph GWPods["Gateway Pods (Spring Cloud Gateway)"]
                            GW_Pod["api-gateway-pod"]
                        end
                        
                        subgraph BPods["Backend Pods (Spring Boot 3, Java 21)"]
                            CS_Pod["customer-service-pod"]
                            PC_Pod["product-catalog-pod"]
                            OM_Pod["order-management-pod"]
                            BS_Pod["billing-service-pod"]
                        end
                    end
                    
                    subgraph Obs_NS["observability / monitoring Namespaces"]
                        Prom_Stack["kube-prometheus-stack (Grafana + Prom)"]
                        Fluent_Pod["Fluent Bit Agent"]
                        OTel_Coll["OpenTelemetry Collector"]
                    end
                end
            end

            subgraph Private_DB["Private DB Subnets (Database Layer)"]
                RDS[("RDS PostgreSQL (Multi-AZ)")]
            end
            
            subgraph VPCE["VPC Endpoints (Tiết kiệm NAT Gateway)"]
                VPCE_S3["S3 Gateway Endpoint"]
                VPCE_SM["Secrets Manager Endpoint"]
                VPCE_ECR["ECR Registry Endpoints"]
                VPCE_CW["CloudWatch Endpoint"]
                VPCE_XR["X-Ray Endpoint"]
            end
        end

        subgraph Managed_Services["AWS Managed Services"]
            AWS_SM["AWS Secrets Manager"]
            AWS_ECR["Amazon ECR (Docker Images)"]
            AWS_EB["Amazon EventBridge (Custom Bus)"]
            AWS_SQS["Amazon SQS (Queues + DLQ)"]
            AWS_CW["Amazon CloudWatch Logs"]
            AWS_XR["AWS X-Ray"]
            AWS_S3["Amazon S3 (File Storage)"]
        end
    end

    %% Network Routing Paths
    Route53 -->|Cname / A Record| ALB_AWS
    ALB_AWS -->|Route path: / | WP_Pod
    ALB_AWS -->|Route path: /admin | AC_Pod
    ALB_AWS -->|Route path: /api | GW_Pod
    
    GW_Pod -->|Intra-cluster Service DNS| CS_Pod
    GW_Pod -->|Intra-cluster Service DNS| PC_Pod
    GW_Pod -->|Intra-cluster Service DNS| OM_Pod
    GW_Pod -->|Intra-cluster Service DNS| BS_Pod

    %% DB Connections
    BPods -->|TCP 5432 / IAM Auth / SSL| RDS

    %% EKS Controllers Operations
    ALB_Ctrl -->|Reconcile Ingress| ALB_AWS
    ExtDNS -->|Manage DNS Records| Route53
    Kar -->|Provision Nodes| AWS
    
    %% AWS integrations via VPC Endpoints
    CSI -->|Mount secrets| VPCE_SM --> AWS_SM
    BPods -->|Push images| VPCE_ECR --> AWS_ECR
    OM_Pod -->|PutEvents| AWS_EB
    AWS_EB --> AWS_SQS
    AWS_SQS -->|SQS Consumer| BS_Pod
    
    %% Observability Export
    Fluent_Pod -->|Send Logs| VPCE_CW --> AWS_CW
    OTel_Coll -->|Send Traces| VPCE_XR --> AWS_XR
    BPods -->|Trace Instrumentation| OTel_Coll
    BPods -.->|Actuator Metrics Scrape| Prom_Stack
    
    %% S3 integration
    BPods -->|S3 API| VPCE_S3 --> AWS_S3
```

---

## 5. Các Quyết Định Kiến Trúc Trọng Tâm (Key Architecture Design Decisions)

### 5.1 Database-per-Service Pattern
- **Quyết định:** Mỗi service sở hữu một DB schema độc lập, truy cập thông qua tài khoản DB riêng biệt với quyền truy cập giới hạn duy nhất trong schema đó.
- **Trade-off:**
  - *Ưu điểm:* Cách ly lỗi dữ liệu hoàn toàn. Cho phép mở rộng quy mô (scale) DB độc lập. Dễ dàng chuyển sang các loại database khác (ví dụ: MongoDB cho catalog, Neo4j cho profile) mà không ảnh hưởng tới service khác.
  - *Nhược điểm:* Việc join dữ liệu giữa các thực thể ở các service khác nhau trở nên phức tạp. Phải giải quyết qua REST API gọi chéo hoặc đồng bộ dữ liệu phi cấu trúc thông qua sự kiện (Event-Driven).

### 5.2 Transactional Outbox Pattern
- **Quyết định:** Không bao giờ gọi trực tiếp EventBus (AWS EventBridge) trong luồng xử lý chính của nghiệp vụ (Business Transaction). Thay vào đó, ghi Event vào bảng `event_outbox` ngay trong cùng transaction ghi dữ liệu nghiệp vụ (Order/Customer). Một scheduler chạy ngầm (`OrderEventPublisher`) sẽ làm nhiệm vụ quét bảng này và đẩy lên EventBridge.
- **Trade-off:**
  - *Ưu điểm:* Đảm bảo **At-least-once delivery**. Nếu EventBridge bị sập hoặc gặp sự cố mạng, transaction đặt hàng vẫn thành công, sự kiện sẽ được retry tự động khi EventBridge hoạt động trở lại. Tránh lỗi mất mát sự kiện (Event Loss).
  - *Nhược điểm:* Độ trễ sự kiện (latency) tăng nhẹ do phụ thuộc vào tần suất quét của scheduler (hiện tại đặt là 1 giây). Tốn thêm không gian lưu trữ và tài nguyên I/O của database cho bảng outbox.

### 5.3 Idempotent Consumer Pattern (Billing Service)
- **Quyết định:** SQS Queue hoặc EventBridge có thể phân phối trùng lặp tin nhắn (**Redelivery / At-least-once**). Để tránh việc xuất hóa đơn trùng lặp (Double-Billing), `billing-service` ghi nhận mọi `event_id` đã xử lý thành công vào bảng `processed_event`. Mỗi khi nhận tin nhắn mới, service sẽ check trùng trước khi thực thi nghiệp vụ.
- **Trade-off:**
  - *Ưu điểm:* Đảm bảo tính toàn vẹn tài chính, tuyệt đối không bị trùng lặp dữ liệu do cơ chế phân phối tin nhắn của hạ tầng.
  - *Nhược điểm:* Tăng thêm một lệnh `SELECT` kiểm tra trước mỗi lần ghi dữ liệu, tăng nhẹ latency xử lý hàng đợi.

### 5.4 VPC Endpoints thay vì NAT Gateways (Dev Env)
- **Quyết định:** Trong môi trường Dev, thay vì dùng NAT Gateway (tốn ~$1.10/ngày mỗi cái), hệ thống sử dụng VPC Gateway Endpoints (cho S3) và Interface Endpoints (cho ECR, Secrets Manager, CloudWatch, X-Ray).
- **Trade-off:**
  - *Ưu điểm:* Tiết kiệm chi phí vận hành hàng tháng đáng kể (~$33/tháng/NAT Gateway). Dữ liệu truyền tải nội bộ trong mạng AWS (không đi ra internet công cộng) giúp tăng tốc độ truyền tải image và độ bảo mật cao.
  - *Nhược điểm:* Cần cấu hình chi tiết cho từng VPC Endpoint trong Terraform. Các service bên trong EKS không thể truy cập internet công cộng để tải thư viện ngoài (phải dùng proxy/cache hoặc tải trước trong quá trình build Docker).

### 5.5 Secrets Store CSI Driver thay vì Environment Variables
- **Quyết định:** Ẩn hoàn toàn thông tin credentials của database, API keys... khỏi biến môi trường (Environment Variables) dạng plain-text. Sử dụng Secrets Store CSI Driver để lấy thông tin từ AWS Secrets Manager và mount trực tiếp vào Pod dưới dạng File Volume tạm thời (`/mnt/secrets-store`).
- **Trade-off:**
  - *Ưu điểm:* Bảo mật tối đa. Giảm thiểu nguy cơ rò rỉ secret qua các lệnh debug env (`env`, `printenv`) hoặc log crashdump. Tự động cập nhật (rotation) secret khi thay đổi trên Secrets Manager.
  - *Nhược điểm:* Cấu hình YAML Kubernetes phức tạp hơn (`SecretProviderClass`, `volumeMounts`). Tăng nhẹ thời gian khởi động Pod do phải xác thực qua IAM Role (IRSA) để fetch dữ liệu từ AWS.
