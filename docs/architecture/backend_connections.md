# Backend APIs and Database Connections

Tài liệu này mô tả chi tiết cách thức kết nối của các **Backend APIs**, các API endpoints theo chuẩn **TM Forum Open APIs**, cơ chế định tuyến qua **api-gateway**, cấu trúc kết nối cơ sở dữ liệu **RDS PostgreSQL (Database-per-Service)**, và luồng đồng bộ sự kiện hướng sự kiện (**Event-Driven**) trong hệ thống BSS Platform.

---

## 1. Bản Đồ Kết Nối API & Điều Hướng (API Routing Map)

Toàn bộ các cuộc gọi từ bên ngoài đều đi qua **api-gateway** (Spring Cloud Gateway) chạy ở cổng `8080`. Gateway thực hiện strip prefix `/api` và định tuyến dựa trên đường dẫn path:

```
[Client / Mobile / Admin] 
       │ HTTP REST API
       ▼
 ┌─────────── api-gateway (Port 8080) ───────────┐
 │                                               │
 ├─ StripPrefix=1 (loại bỏ /api)                │
 ├─ /api/customers/** ──► http://customer-service│
 ├─ /api/products/**  ──► http://product-catalog │
 ├─ /api/orders/**    ──► http://order-management│
 ├─ /api/bills/**     ──► http://billing-service │
 └───────────────────────────────────────────────┘
```

---

## 2. Chi Tiết API Endpoints của Từng Microservice

Hệ thống thiết kế theo chuẩn **TM Forum Open APIs** phiên bản mới nhất, hỗ trợ đầy đủ các phương thức HTTP RESTful chuẩn chỉ:

### 2.1 Customer Service (TMF629 Customer Management)
*   **Mục đích:** Quản lý thông tin định danh, vòng đời và trạng thái của khách hàng.
*   **Thư mục mã nguồn:** `apps/backend/customer-service/`
*   **Database:** schema `customer` trong cơ sở dữ liệu PostgreSQL.
*   **Các Endpoints chính:**
    *   `GET /tmf-api/customerManagement/v4/customer` : Lấy danh sách khách hàng (Hỗ trợ phân trang qua `offset` và `limit`, trả về tổng số lượng qua Header `X-Total-Count`).
    *   `GET /tmf-api/customerManagement/v4/customer/{id}` : Lấy thông tin chi tiết một khách hàng theo UUID.
    *   `POST /tmf-api/customerManagement/v4/customer` : Tạo mới tài khoản khách hàng (Mặc định trạng thái ban đầu là `Initialized`).
    *   `PATCH /tmf-api/customerManagement/v4/customer/{id}` : Cập nhật một phần thông tin khách hàng (Sử dụng Content-Type `application/merge-patch+json`).
    *   `DELETE /tmf-api/customerManagement/v4/customer/{id}` : Xóa thông tin khách hàng hoặc đánh dấu trạng thái xóa vật lý.

### 2.2 Product Catalog (TMF620 Product Catalog Management)
*   **Mục đích:** Quản lý danh mục sản phẩm, định nghĩa gói cước, dịch vụ, giá bán, chu kỳ cước.
*   **Thư mục mã nguồn:** `apps/backend/product-catalog/`
*   **Database:** schema `product` trong cơ sở dữ liệu PostgreSQL.
*   **Các Endpoints chính:**
    *   `GET /tmf-api/productCatalog/v4/category` : Lấy danh mục nhóm sản phẩm (Mobile, Broadband, IoT).
    *   `GET /tmf-api/productCatalog/v4/productSpecification` : Lấy thông tin đặc tả kỹ thuật của sản phẩm (Mobile Postpaid, FTTH 1G, IoT SIM).
    *   `GET /tmf-api/productCatalog/v4/productOffering` : Lấy danh sách các gói cước đang mở bán (Lite 30, Pro 80, Home Fiber 200, IoT Starter).
    *   `GET /tmf-api/productCatalog/v4/productOffering/{id}` : Xem chi tiết thông số gói cước và giá tiền.
    *   `POST /tmf-api/productCatalog/v4/productOffering` : Quản trị viên thêm gói cước mới vào catalog.

### 2.3 Order Management (TMF622 Product Order Management)
*   **Mục đích:** Tiếp nhận yêu cầu mua mới, nâng cấp, hoặc hủy dịch vụ của khách hàng. Triển khai Transactional Outbox Pattern.
*   **Thư mục mã nguồn:** `apps/backend/order-management/`
*   **Database:** schema `orders` trong cơ sở dữ liệu PostgreSQL.
*   **Các Endpoints chính:**
    *   `POST /tmf-api/orderManagement/v4/productOrder` : Tạo mới đơn đặt hàng. Đơn hàng gồm danh sách các `orderItem` chứa thông tin gói cước chọn mua.
    *   `GET /tmf-api/orderManagement/v4/productOrder` : Lấy danh sách lịch sử đặt hàng của khách hàng.
    *   `GET /tmf-api/orderManagement/v4/productOrder/{id}` : Xem trạng thái chi tiết của đơn hàng (`Acknowledged`, `InProgress`, `Completed`, `Cancelled`, `Failed`).

### 2.4 Billing Service (TMF678 Customer Bill Management)
*   **Mục đích:** Quản lý tài khoản thanh toán cước, tính toán và xuất hóa đơn VAT, tích hợp cổng thanh toán.
*   **Thư mục mã nguồn:** `apps/backend/billing-service/`
*   **Database:** schema `billing` trong cơ sở dữ liệu PostgreSQL.
*   **Các Endpoints chính:**
    *   `GET /tmf-api/billingManagement/v4/billingAccount` : Lấy danh sách tài khoản cước.
    *   `GET /tmf-api/billingManagement/v4/customerBill` : Xem danh sách hóa đơn.
    *   `GET /tmf-api/billingManagement/v4/customerBill/{id}` : Lấy chi tiết hóa đơn (Gồm tổng tiền cước gốc, cước phát sinh, 10% VAT).

---

## 3. Bản Đồ Kết Nối Cơ Sở Dữ Liệu (Database Connections)

Hệ thống tuân thủ mô hình **Database-per-Service**. Mỗi Microservice kết nối tới schema tương ứng của mình trên PostgreSQL instance thông qua cấu hình Spring Data JPA/Hibernate độc lập.

```
                  ┌───────────────────────────────┐
                  │      RDS PostgreSQL DB        │
                  │  (Host: postgres/rds-domain)  │
                  ├───────────────────────────────┤
                  │ ┌───────────────────────────┐ │
 customer-service ┼─┼► Schema: customer          │ │ (Table: customers)
                  │ └───────────────────────────┘ │
 product-catalog  ┼─┼► Schema: product           │ │ (Tables: category, product_specification, product_offering)
                  │ └───────────────────────────┘ │
 order-management ┼─┼► Schema: orders            │ │ (Tables: product_order, order_item, event_outbox)
                  │ └───────────────────────────┘ │
 billing-service  ┼─┼► Schema: billing           │ │ (Tables: billing_account, invoice, invoice_item, processed_event)
                  │ └───────────────────────────┘ │
                  └───────────────────────────────┘
```

### 3.1 Cấu hình Kết Nối Spring Boot (EKS Production)
Các Service sử dụng biến môi trường do **Secrets Store CSI Driver** mount từ **AWS Secrets Manager** để cấu hình `DataSource`:

*   **URL kết nối (`spring.datasource.url`):** 
    `jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}?currentSchema=${DB_SCHEMA}&ssl=true`
*   **Đồng bộ DB:** 
    Tất cả các service đều đặt cấu hình `spring.jpa.hibernate.ddl-auto=validate` ở môi trường production. Toàn bộ cấu trúc cơ sở dữ liệu được khởi tạo và kiểm soát hoàn chỉnh bởi các file migration của **Flyway** đặt tại thư mục `src/main/resources/db/migration/`.

---

## 4. Cơ Chế Tích Hợp Đồng Bộ Sự Kiện (Transactional Outbox)

Cơ chế gửi sự kiện phi đồng bộ cực kỳ an toàn giữa **Order Management** và **Billing Service** diễn ra thông qua bảng `event_outbox` và hàng đợi SQS:

1.  **Ghi Đồng Thời:** Khi khách hàng đặt đơn hàng thành công, `order-management` mở một Database Transaction để lưu thông tin đơn hàng vào bảng `product_order` và nội dung sự kiện vào bảng `event_outbox`.
2.  **Drain Sự Kiện:** Scheduler của `order-management` chạy ngầm, liên tục đọc các bản ghi chưa gửi trong bảng `event_outbox` (`published_at IS NULL`) để đẩy lên **AWS EventBridge**. Sau khi đẩy thành công, cập nhật cột `published_at = now()`.
3.  **Hàng Đợi SQS:** AWS EventBridge định tuyến sự kiện dựa trên rule vào **Amazon SQS** (`bss-dev-billing-orders`).
4.  **Tiêu Thụ Idempotent:** `billing-service` lắng nghe từ SQS, kiểm tra trùng lặp qua bảng `processed_event`. Nếu sự kiện chưa từng xử lý, ghi nhận sự kiện, tự động xuất hóa đơn mới cước cho khách hàng, và Acknowledge để xóa tin nhắn khỏi hàng đợi SQS.
