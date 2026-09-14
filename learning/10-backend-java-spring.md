# 10 — Backend: Java 21 + Spring Boot, Outbox, Idempotent Consumer

> Mục tiêu bài: đọc hiểu **từng dòng** của 5 service backend, hiểu cơ chế bên dưới (DI, JPA, transaction, proxy),
> và tự sửa các lỗi B-02, B-03, B-10 → B-17, B-19.
> Thời lượng: 6–8h đọc + 10–15h lab. Đọc khi làm **Giai đoạn 1** của [lộ trình](20-lo-trinh-hoan-thanh.md).
> Chuẩn bị: JDK 21 + Maven 3.9 (khuyến nghị cài trong WSL2), Docker Desktop đang chạy (Testcontainers cần).

---

## 1. Java/Spring cho người đến từ Node.js/Express

### 1.1 Bảng ánh xạ khái niệm

| Node.js / Express (đồ án của bạn) | Java / Spring Boot (dự án) |
|---|---|
| `package.json` + `npm` | `pom.xml` + `mvn` |
| `node_modules/` | `~/.m2/repository/` (cache chung cho mọi project) |
| `npm start` | `mvn spring-boot:run` hoặc `java -jar target/app.jar` |
| `const app = express(); app.listen(4001)` | `SpringApplication.run(App.class)` + `server.port: 8080` |
| `router.get('/users/:id', handler)` | `@GetMapping("/{id}") public X get(@PathVariable UUID id)` |
| `req.body` + `express-validator` | `@Valid @RequestBody CreateOrderRequest req` + `@NotNull`, `@Email` |
| middleware `app.use(...)` | Filter / Interceptor / `@RestControllerAdvice` (xử lý lỗi tập trung) |
| `require('./userService')` — tự tạo instance | **Dependency Injection**: Spring tạo và "tiêm" object vào constructor |
| Mongoose `Schema`/`Model` | JPA `@Entity` + `JpaRepository` |
| Mongo tự tạo collection | **Flyway** tạo bảng bằng file SQL có đánh số phiên bản |
| `process.env.DB_URL` | `${DB_URL:giá_trị_mặc_định}` trong `application.yml` |
| `prom-client` + `/metrics` | Micrometer + Actuator `/actuator/prometheus` |
| Jest + Supertest | JUnit 5 + MockMvc + AssertJ |
| MongoMemoryServer | **Testcontainers** (Postgres thật trong Docker) |
| `async/await` | Code chạy đồng bộ trên thread pool của Tomcat (trừ gateway dùng WebFlux) |

### 1.2 Ba cơ chế "phép thuật" cần hiểu để không bị Spring lừa

1. **Inversion of Control / DI.** Khi khởi động, Spring quét package (`@ComponentScan`), thấy class có `@Service`, `@RestController`, `@Component`, `@Configuration` → tạo **một instance duy nhất** (singleton "bean") và nối chúng với nhau qua **constructor**. Ví dụ `CustomerController(CustomerService service)`: bạn không bao giờ viết `new CustomerService(...)`.
2. **Auto-configuration.** Thấy thư viện `postgresql` + `spring-boot-starter-data-jpa` + thuộc tính `spring.datasource.url` → Spring tự tạo `DataSource` (pool HikariCP), `EntityManagerFactory`, `TransactionManager`. Thấy `flyway-core` → tự chạy migration **trước** khi JPA khởi tạo.
3. **Proxy (AOP).** Annotation như `@Transactional` **không làm gì** tự thân. Spring bọc bean trong một **proxy**: gọi `service.create()` từ bên ngoài → proxy mở transaction → gọi method thật → commit/rollback. **Gọi nội bộ `this.method()` đi thẳng vào object thật, bỏ qua proxy** → annotation mất tác dụng. Đây là gốc rễ của lỗi B-10.

```
Controller ──gọi──▶ [ Proxy CustomerService ] ──▶ CustomerService thật
                        │ BEGIN TRANSACTION           │
                        │ ...                        │ this.helper()  ← KHÔNG qua proxy
                        │ COMMIT / ROLLBACK          │
```

---

## 2. `pom.xml` — đọc từng khối (customer-service)

🔍 [customer-service/pom.xml](../apps/backend/customer-service/pom.xml)

| Dòng | Nội dung | Ý nghĩa |
|---|---|---|
| 7–12 | `<parent>spring-boot-starter-parent 3.2.4` | Kế thừa cấu hình chuẩn: version của hàng trăm thư viện (BOM), plugin, encoding UTF-8. Nhờ vậy các dependency bên dưới **không cần ghi version**. `<relativePath/>` = lấy parent từ Maven Central chứ không tìm thư mục cha |
| 14–18 | `groupId/artifactId/version` | "Tọa độ" của artifact: `com.bss:customer-service:0.1.0` → file `target/customer-service-0.1.0.jar` |
| 20–22 | `java.version 21` | Parent dùng property này để cấu hình compiler |
| 26–29 | `spring-boot-starter-web` | Spring MVC + Tomcat nhúng + Jackson (JSON) |
| 32–40 | `data-jpa` + `postgresql` (runtime) | JPA/Hibernate + JDBC driver. `runtime` = chỉ cần lúc chạy, không cần lúc compile |
| 43–46 | `flyway-core` | Migration. ⚠️ Flyway 10+ với Postgres cần thêm `flyway-database-postgresql` — Boot 3.2 dùng Flyway 9 nên chưa cần; khi nâng Boot 3.3+ phải thêm |
| 49–52 | `validation` | Hibernate Validator (Bean Validation: `@NotBlank`, `@Email`) |
| 55–62 | `actuator` + `micrometer-registry-prometheus` | `/actuator/health`, `/actuator/prometheus` |
| 65–84 | `test` scope: starter-test, spring-boot-testcontainers, junit-jupiter, postgresql (Testcontainers) | Chỉ có trong classpath khi chạy test |
| 87–94 | `spring-boot-maven-plugin` | Đóng gói "fat JAR" (chứa mọi dependency) chạy được bằng `java -jar` |

Maven lifecycle bạn cần nhớ (🔁 handout 4): `validate → compile → test → package → verify → install → deploy`. Chạy một pha = chạy mọi pha trước nó.

⚠️ **B-09 — Test có thực sự chạy không?** Pha `test` do plugin **surefire** chạy, mặc định chỉ nhận file tên `Test*.java`, `*Test.java`, `*Tests.java`, `*TestCase.java`. Các file `*IT.java` theo quy ước dành cho plugin **failsafe** (pha `integration-test`/`verify`) — nhưng không pom nào khai báo failsafe (parent chỉ để sẵn trong `pluginManagement`, chưa kích hoạt). Nghĩa là rất có thể `mvn verify` **xanh mà không chạy test nào**. Hãy tự kiểm chứng ở Lab 10.1: xem log có dòng `Tests run:` cho `CustomerControllerIT` không. Cách sửa: khai báo `maven-failsafe-plugin` trong `<build><plugins>` (khuyến nghị — tách unit test và integration test), hoặc đổi tên thành `*Test`.

> 🧪 Mẹo điều tra: `mvn help:effective-pom | grep -A20 surefire` để xem cấu hình surefire thật mà parent đưa vào.

---

## 3. Chuyện gì xảy ra khi `java -jar app.jar`?

```
main() → SpringApplication.run()
  1. Đọc application.yml + biến môi trường + profile (SPRING_PROFILES_ACTIVE)
  2. Quét @Component/@Service/@RestController trong package com.bss.customer
  3. Auto-config DataSource (HikariCP) theo spring.datasource.*
  4. Flyway: tạo bảng flyway_schema_history, chạy V1__init_customer.sql nếu chưa chạy
  5. Hibernate khởi tạo, ddl-auto=validate: so entity với bảng thật → lệch là CRASH ngay
  6. Tạo proxy cho @Transactional, tạo controller
  7. Tomcat lắng nghe :8080; Actuator bật; readiness = ACCEPTING_TRAFFIC
```

⚖️ Vì sao `ddl-auto: validate` chứ không `update`? `update` để Hibernate tự sửa schema → không kiểm soát, không review, không rollback được, nguy hiểm ở prod. `validate` bắt Flyway làm chủ schema, Hibernate chỉ kiểm tra — lệch là fail sớm lúc khởi động (tốt hơn fail lúc khách đang dùng).

---

## 4. customer-service — đọc từng dòng

### 4.1 `application.yml`

🔍 [application.yml](../apps/backend/customer-service/src/main/resources/application.yml)

```yaml
spring:
  application:
    name: customer-service                 # tên app; dùng làm tag metric (dòng 36)
  datasource:
    url: ${DB_URL:jdbc:postgresql://localhost:5432/customer}   # ${BIẾN:mặc_định}
    username: ${DB_USER:bss}
    password: ${DB_PASSWORD:bss}           # mặc định "bss" chỉ hợp lệ ở local
  jpa:
    hibernate:
      ddl-auto: validate                   # schema do Flyway sở hữu
    properties:
      hibernate:
        dialect: org.hibernate.dialect.PostgreSQLDialect   # thừa: Hibernate 6 tự nhận diện
  flyway:
    enabled: true
    baseline-on-migrate: true   # nếu DB đã có bảng mà chưa có lịch sử Flyway → coi là "baseline"
    locations: classpath:db/migration
server:
  port: 8080
  shutdown: graceful            # nhận SIGTERM: ngừng nhận request mới, chờ request đang chạy xong
management:
  endpoints.web.exposure.include: health,info,prometheus,metrics
  endpoint.health.probes.enabled: true      # bật /actuator/health/liveness và /readiness
  endpoint.health.show-details: when_authorized   # không có Spring Security → không bao giờ hiện chi tiết
  metrics.tags.application: ${spring.application.name}   # ⚠️ chỉ service này có (B-16)
  prometheus.metrics.export.enabled: true
logging.pattern.console: '%d{...} [%thread] %-5level %logger{36} - %msg%n'   # text, chưa phải JSON (B-17)
```

🔁 Handout Databases slide "Configure DB connection 4.1": "định nghĩa biến trong code, set giá trị từ ngoài theo từng môi trường" — đúng cú pháp `${DB_URL:...}`. Trên K8s, `DB_URL` đến từ ConfigMap, `DB_USER/PASSWORD` từ Secret.

Relaxed binding: biến môi trường `SPRING_DATASOURCE_URL` cũng ghi đè được `spring.datasource.url` (Spring tự đổi `_` → `.`). Vì vậy course lab 3.2 dùng `-e SPRING_DATASOURCE_URL=...` vẫn chạy.

### 4.2 Migration `V1__init_customer.sql`

🔍 [V1__init_customer.sql](../apps/backend/customer-service/src/main/resources/db/migration/V1__init_customer.sql)

- Tên file: `V` + phiên bản `1` + **hai dấu gạch dưới** + mô tả. Flyway chạy theo thứ tự phiên bản, lưu checksum vào `flyway_schema_history`.
- ⚠️ **Không bao giờ sửa file migration đã chạy** — checksum đổi → Flyway từ chối khởi động. Muốn đổi schema → tạo `V2__...`.
- `id UUID PRIMARY KEY` — không có `DEFAULT gen_random_uuid()` vì ứng dụng tự sinh UUID.
- `email ... UNIQUE` — ràng buộc DB là **nguồn sự thật cuối cùng** cho tính duy nhất (code có kiểm tra cũng vẫn có race condition).
- `TIMESTAMPTZ` — lưu mốc thời gian tuyệt đối (UTC), hiển thị theo múi giờ phiên. Luôn dùng thay `TIMESTAMP`.
- `CREATE INDEX ix_customers_status` — tăng tốc lọc theo trạng thái.
- 💡 Cột `phone_number` đã có sẵn → Lab 2.5 của course ("thêm cột phone_number") phải đổi thành cột khác (vd. `date_of_birth`).

### 4.3 Entity `Customer.java`

🔍 [Customer.java](../apps/backend/customer-service/src/main/java/com/bss/customer/model/Customer.java)

| Dòng | Code | Giải thích |
|---|---|---|
| 12–13 | `@Entity @Table(name="customers")` | Class ↔ bảng `customers` |
| 16–18 | `@Id @GeneratedValue(strategy = GenerationType.UUID)` | Hibernate tự sinh UUID khi persist. ⚠️ Đây là **UUID v4 (ngẫu nhiên)**, CLAUDE.md nói v7 (có thứ tự thời gian → index B-tree ít phân mảnh hơn). Hibernate 6.2+ có `@UuidGenerator(style = TIME)` gần với v7 |
| 20–22 | `@NotBlank @Column(nullable=false)` | Validation ở tầng API + ràng buộc ở tầng DB — hai lớp khác nhau |
| 24–26 | `@Email @Column(unique = true)` | `unique` ở đây chỉ là metadata (ddl-auto không tạo gì); ràng buộc thật nằm trong SQL |
| 34–36 | `@Enumerated(EnumType.STRING)` | Lưu `'Active'` thay vì số thứ tự `2`. ⚖️ ORDINAL gọn hơn nhưng **chèn thêm giá trị enum vào giữa là hỏng dữ liệu cũ** |
| 44–53 | `@PrePersist / @PreUpdate` | Hook vòng đời JPA tự đặt `createdAt/updatedAt` |
| 59–61 | `TODO(learner)` | Thầy để lại gợi ý cho người học |

⚠️ **Rủi ro mass-assignment (hãy tự kiểm chứng):** controller nhận **chính entity** làm `@RequestBody`. Jackson mặc định bật `INFER_PROPERTY_MUTATORS`: field private nào có getter public (như `id`) **vẫn có thể được gán từ JSON**. Nếu client POST kèm `"id": "<id của khách khác>"`, `repo.save()` thấy id khác null → gọi `merge()` → có thể **ghi đè khách hàng khác** mà vẫn trả 201. Các service khác dùng DTO (`CreateOfferingRequest`, `CreateOrderRequest`) nên an toàn hơn. → Lab 10.4: viết test chứng minh/bác bỏ giả thuyết này, rồi chuyển sang DTO `CreateCustomerRequest`.

### 4.4 Repository

🔍 [CustomerRepository.java](../apps/backend/customer-service/src/main/java/com/bss/customer/repository/CustomerRepository.java)

`interface CustomerRepository extends JpaRepository<Customer, UUID>` — **không có code implement**. Spring Data sinh class lúc chạy với sẵn `save, findById, findAll(Pageable), deleteById, existsById, count`... Method `findByEmail` là **derived query**: Spring phân tích tên method → `SELECT c FROM Customer c WHERE c.email = ?`. (Hiện chưa ai gọi `findByEmail`.)

### 4.5 Service — transaction và phân trang

🔍 [CustomerService.java](../apps/backend/customer-service/src/main/java/com/bss/customer/service/CustomerService.java)

- Dòng 15–16: `@Service @Transactional` ở **mức class** → mọi method public đều chạy trong transaction. Method đọc ghi đè bằng `@Transactional(readOnly = true)` → Hibernate bỏ dirty-checking, driver có thể tối ưu.
- Dòng 21–23: constructor injection (quy ước CLAUDE.md: không `@Autowired` field) → dễ test, field `final`.
- Dòng 26–30 — **phân trang**: `PageRequest.of(offset / limit, limit)`. TMF dùng `offset` (vị trí bản ghi), Spring dùng `page` (số trang). Phép chia nguyên làm **mất phần dư**: `offset=10&limit=20` → trang 0 → trả bản ghi 0–19 thay vì 10–29. `limit=0` → `PageRequest.of(0,0)` ném `IllegalArgumentException` → HTTP 500. Offset âm → cũng 500. → Lab 10.5 (test trước, sửa sau; gợi ý: dùng `OffsetBasedPageRequest` tự viết hoặc `Limit`/`ScrollPosition` của Spring Data 3.1+).
- Dòng 42–49 — PATCH: chỉ đổi field khác `null`. Không cần gọi `save()` (entity đang "managed", Hibernate tự UPDATE khi commit) — gọi cũng không sai.
- Dòng 51–56 — DELETE: kiểm tra tồn tại trước để trả 404 thay vì im lặng. ⚖️ Xóa cứng khách hàng trong BSS thật là không được phép (dữ liệu hóa đơn, pháp lý) — thật sẽ là "soft delete" chuyển `status = Terminated`.

### 4.6 Controller — HTTP đúng chuẩn

🔍 [CustomerController.java](../apps/backend/customer-service/src/main/java/com/bss/customer/controller/CustomerController.java)

| Endpoint | Code | HTTP trả về |
|---|---|---|
| `GET /customer?offset&limit` | `Math.min(limit, 100)` chặn trang quá lớn; header `X-Total-Count` | 200 |
| `POST /customer` | `ResponseEntity.created(URI)` | **201** + header `Location` |
| `GET /customer/{id}` | `@PathVariable UUID id` — id không phải UUID → Spring trả 400 | 200 / 404 |
| `PATCH /customer/{id}` | `consumes` cả `application/json` và `application/merge-patch+json` | 200 |
| `DELETE /customer/{id}` | `ResponseEntity.noContent()` | **204** |

⚠️ Merge-patch (RFC 7396) quy định `{"phoneNumber": null}` nghĩa là **xóa** trường. Record `PatchCustomerRequest` không phân biệt "không gửi" và "gửi null" → không xóa được số điện thoại. Muốn đúng chuẩn cần đọc `JsonNode` hoặc dùng `JsonNullable`. Ghi chú này để bạn biết giới hạn, chưa cần sửa.

### 4.7 Xử lý lỗi — RFC 7807 ProblemDetail

🔍 [GlobalExceptionHandler.java](../apps/backend/customer-service/src/main/java/com/bss/customer/exception/GlobalExceptionHandler.java)

- `@RestControllerAdvice` = "middleware lỗi" toàn cục (🔁 như `app.use((err, req, res, next) => ...)`).
- `NotFoundException` → 404; `MethodArgumentNotValidException` (lỗi `@Valid`) → **422 Unprocessable Entity** (dữ liệu đúng cú pháp JSON nhưng sai nghiệp vụ; 400 dành cho JSON hỏng); `DataIntegrityViolationException` (vi phạm UNIQUE) → **409 Conflict**.
- `ProblemDetail` sinh JSON chuẩn: `{"type":"about:blank","title":"Not Found","status":404,"detail":"Customer not found: ..."}`.
- Chỉ lấy lỗi validation **đầu tiên** (`findFirst`) — client phải sửa từng lỗi một. Cải tiến: trả mảng `errors` trong `ProblemDetail.setProperty(...)`.

### 4.8 Integration test

🔍 [CustomerControllerIT.java](../apps/backend/customer-service/src/test/java/com/bss/customer/CustomerControllerIT.java)

| Dòng | Code | Giải thích |
|---|---|---|
| 24 | `@SpringBootTest` | Khởi động **toàn bộ** ứng dụng như thật |
| 25 | `@AutoConfigureMockMvc` | Gọi controller qua HTTP giả lập (không mở port) |
| 26, 29–31 | `@Testcontainers`, `@Container static PostgreSQLContainer` | Chạy Postgres 15 thật trong Docker, dùng chung cho mọi test trong class |
| 30 | `@ServiceConnection` (Boot 3.1+) | Tự điền `spring.datasource.url/username/password` từ container — không cần cấu hình tay |
| 33–36 | `@DynamicPropertySource` | Ghi đè property lúc chạy (ở đây hơi thừa vì Flyway đã bật) |
| 42–80 | `create_get_patch_delete` | Một test đi hết vòng đời: POST 201 → GET → PATCH chỉ đổi tên, email giữ nguyên → DELETE 204 → GET 404 |
| 82–92 | email sai → 422 | Edge case validation |
| 94–109 | email trùng → 409 | Edge case ràng buộc DB |

🔁 So với Jest + MongoMemoryServer: Testcontainers chạy **đúng engine** Postgres → bắt được lỗi SQL/ràng buộc mà DB giả không bắt. Đổi lại: test chậm hơn (khởi động container ~5–10s) và **cần Docker** (CI GitHub có sẵn).

---

## 5. product-catalog — cái gì mới so với customer

🔍 [product-catalog/src/main/java/com/bss/product/](../apps/backend/product-catalog/src/main/java/com/bss/product/)

1. **DTO bằng `record`** — `CreateOfferingRequest`, `ProductOfferingDto`: bất biến, tự có constructor/`equals`/`toString`. `ProductOfferingDto.from(entity)` là *static factory* chuyển entity → DTO (tách "hình dạng DB" khỏi "hình dạng API" — đổi DB không vỡ API).
2. **Lọc động** — [ProductOfferingService.java:37-45](../apps/backend/product-catalog/src/main/java/com/bss/product/service/ProductOfferingService.java) chọn 1 trong 4 derived query theo tham số nào có. ⚖️ Thêm 1 bộ lọc nữa → 8 nhánh. Cách mở rộng được: `JpaSpecificationExecutor` / Criteria API / Querydsl.
3. **`LifecycleStatus`** — vòng đời sản phẩm theo TMF620 (`InStudy → InDesign → InTest → Active → Launched → Retired → Obsolete`). Web-portal chỉ hiện `Active`.
4. **`CategoryController` gọi thẳng repository** — bỏ qua tầng service (chấp nhận được với endpoint chỉ đọc, nhưng lệch quy ước).
5. **Seed data trong `V1__init_product.sql`** — 3 category, 3 specification, 4 offering với UUID "dễ nhớ" (`d2222222-...` là Pro 80). ⚖️ Seed trong migration có phiên bản → chạy cả ở prod. Tách thành `R__seed.sql` (repeatable) hoặc profile riêng nếu không muốn dữ liệu mẫu ở prod.
6. **Tiền = `BigDecimal` + `NUMERIC(12,2)`** — không bao giờ dùng `double` cho tiền (0.1 + 0.2 ≠ 0.3). `CHAR(3)` cho mã tiền tệ ISO 4217 (`VND`).
7. **Test** [ProductCatalogIT.java](../apps/backend/product-catalog/src/test/java/com/bss/product/ProductCatalogIT.java): kiểm tra seed đã nạp. ⚠️ `header().string("X-Total-Count", greaterThanOrEqualTo("4"))` so sánh **chuỗi** — `"10" >= "4"` là **false** theo thứ tự chữ cái (B-14). Sửa: đọc header, `Integer.parseInt`, rồi so sánh số.

---

## 6. order-management — Transactional Outbox

### 6.1 Bài toán "ghi kép" (dual-write)

Khi đặt hàng, ta phải (1) lưu đơn vào DB **và** (2) phát sự kiện cho billing. Hai hệ thống khác nhau → không có transaction chung:

| Cách làm ngây thơ | Chuyện gì xảy ra khi lỗi |
|---|---|
| Lưu DB rồi gọi EventBridge | Commit xong, EventBridge lỗi/timeout → đơn có, **hóa đơn không bao giờ có** |
| Gọi EventBridge rồi lưu DB | Event đã đi, DB rollback → **hóa đơn cho đơn không tồn tại** |
| Gọi EventBridge **trong** transaction | EventBridge thành công, commit lỗi → giống trường hợp 2 |

**Outbox** giải bằng cách biến (2) thành một phần của (1): ghi sự kiện vào **bảng trong cùng DB, cùng transaction**. Một tiến trình khác đọc bảng và gửi đi, thử lại đến khi thành công → đảm bảo **"nếu đơn commit thì sự kiện chắc chắn sẽ được gửi (ít nhất một lần)"**.

```mermaid
flowchart LR
    A[POST productOrder] --> B[(BEGIN)]
    B --> C[INSERT product_order + order_item]
    C --> D[INSERT event_outbox published_at=NULL]
    D --> E[(COMMIT)]
    F[@Scheduled mỗi 2s] --> G[SELECT outbox chưa gửi LIMIT 10]
    G --> H[PutEvents EventBridge]
    H -->|OK| I[UPDATE published_at=now]
    H -->|lỗi| J[để nguyên → lần sau thử lại]
```

### 6.2 Aggregate `ProductOrder` + `OrderItem`

🔍 [ProductOrder.java](../apps/backend/order-management/src/main/java/com/bss/order/model/ProductOrder.java), [OrderItem.java](../apps/backend/order-management/src/main/java/com/bss/order/model/OrderItem.java)

- `@OneToMany(mappedBy = "order", cascade = ALL, orphanRemoval = true)` — lưu đơn thì lưu luôn các dòng hàng; bỏ dòng khỏi list thì xóa trong DB. `mappedBy` = khóa ngoại nằm ở phía `OrderItem.order`.
- `@ManyToOne(fetch = LAZY)` — chỉ tải đơn cha khi thật sự truy cập.
- `addItem()` (dòng 69–72) đặt **cả hai chiều** của quan hệ — quên chiều `item.setOrder(this)` là lỗi JPA kinh điển (khóa ngoại null).
- `recomputeTotal()` — `unitPrice × quantity` cộng dồn bằng `BigDecimal`.
- SQL [V1__init_order.sql:23](../apps/backend/order-management/src/main/resources/db/migration/V1__init_order.sql): `product_offering_id UUID NOT NULL` **không có FOREIGN KEY** — vì offering nằm ở DB của service khác (database-per-service). Toàn vẹn tham chiếu giữa service phải kiểm bằng code (B-13).

### 6.3 `OrderService.create()` từng bước

🔍 [OrderService.java:39-74](../apps/backend/order-management/src/main/java/com/bss/order/service/OrderService.java)

1. Dựng `ProductOrder` từ request, thêm từng item. ⚠️ `unitPrice` lấy **từ client** (B-13).
2. `recomputeTotal()`.
3. Đặt thẳng `Completed` + `completedAt` (giản lược: BSS thật sẽ `Acknowledged → InProgress` → gọi OSS → `Completed`).
4. `orders.save(order)` → cascade lưu item.
5. `outbox.save(EventOutbox.of("ProductOrder", id, "OrderCompleted", json))` — **cùng transaction** (class có `@Transactional`).
6. Payload JSON: `orderId, customerId, amount (chuỗi — tránh float), currency, completedAt` — khớp [OrderCompleted.schema.json](../packages/api-contracts/events/OrderCompleted.schema.json).

### 6.4 `EventOutbox` — cột JSONB

🔍 [EventOutbox.java](../apps/backend/order-management/src/main/java/com/bss/order/model/EventOutbox.java)

- `@JdbcTypeCode(SqlTypes.JSON)` + `columnDefinition = "jsonb"` — Hibernate 6 bind chuỗi Java vào cột `jsonb` của Postgres (không cần thư viện ngoài).
- `aggregate_type / aggregate_id / event_type` — metadata chuẩn của outbox (dùng được cho nhiều loại sự kiện).
- SQL dòng 46–48: **partial index** `WHERE published_at IS NULL` — index chỉ chứa dòng *chưa gửi* → nhỏ gọn dù bảng có hàng triệu dòng đã gửi. 🧠 Kỹ thuật Postgres rất đáng nhớ.

### 6.5 `OrderEventPublisher` — người "xả" outbox

🔍 [OrderEventPublisher.java](../apps/backend/order-management/src/main/java/com/bss/order/event/OrderEventPublisher.java)

| Dòng | Code | Giải thích |
|---|---|---|
| 29 | `BATCH_SIZE = 10` | Giới hạn cứng của `PutEvents`: tối đa 10 entry/lần |
| 43 | `@Scheduled(fixedDelay = 2000)` | Chạy lại **2s sau khi lần trước kết thúc** (khác `fixedRate`). Cần `@EnableScheduling` ở class Application |
| 44 | `@Transactional` | Gọi từ scheduler (bên ngoài) → qua proxy → có transaction ✅ |
| 46 | `findUnpublished(PageRequest.of(0, 10))` | 10 dòng cũ nhất chưa gửi (JPQL ở repository) |
| 51–59 | `PutEventsRequestEntry` | `source = "bss.order"`, `detailType = "OrderCompleted"`, `detail = payload` — EventBridge rule lọc theo 2 trường đầu |
| 61 | `client.putEvents(...)` | ⚠️ Gọi mạng **bên trong** transaction DB → giữ connection DB trong lúc chờ AWS |
| 63–72 | duyệt `result.entries()` | PutEvents có thể thành công **một phần** — kết quả trả theo đúng thứ tự entry; chỉ đánh dấu những entry không có `errorCode` |
| 73 | `saveAll(pending)` | Ghi `published_at` |

⚠️ **B-12** — hai pod cùng chạy hàm này → cùng đọc 10 dòng → gửi trùng. Cách sửa phổ biến:

```sql
-- native query trong repository; mỗi pod "khóa" những dòng nó lấy, pod khác bỏ qua
SELECT * FROM event_outbox
WHERE published_at IS NULL
ORDER BY created_at
LIMIT 10
FOR UPDATE SKIP LOCKED;
```

⚠️ **B-11** — Kể cả có SKIP LOCKED, vẫn còn tình huống "PutEvents thành công → pod chết trước khi commit `published_at`" → lần sau gửi lại. **At-least-once là bản chất** — nên consumer phải idempotent theo một khóa **ổn định** (id dòng outbox), không phải id do EventBridge sinh.

### 6.6 `AwsConfig` — cùng code chạy LocalStack lẫn AWS thật

🔍 [order-management/config/AwsConfig.java](../apps/backend/order-management/src/main/java/com/bss/order/config/AwsConfig.java)

- Có `aws.endpoint-url` (local) → trỏ LocalStack `http://localhost:4566` + credential giả `test/test`.
- Không có (AWS) → `DefaultCredentialsProvider`: thử lần lượt **biến môi trường → system property → web identity token (IRSA) → profile file → container → instance profile (IMDS)**.
- 🧠 **IRSA hoạt động thế nào ở phía Pod:** ServiceAccount có annotation `eks.amazonaws.com/role-arn` → webhook của EKS tự tiêm vào Pod biến `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` và mount một token OIDC. SDK đọc token → gọi **STS `AssumeRoleWithWebIdentity`** → nhận credential tạm (1h, tự làm mới).
- ⚠️ **B-19** — bước "gọi STS" cần module `software.amazon.awssdk:sts` trong `pom.xml`; hiện **không có** → IRSA không hoạt động, lỗi chỉ lộ ra khi lên EKS.

---

## 7. billing-service — Idempotent Consumer

### 7.1 SQS: những điều phải thuộc

| Khái niệm | Ý nghĩa với code |
|---|---|
| **At-least-once** (Standard queue) | Một message có thể được giao 2+ lần → phải chống trùng |
| **Visibility timeout** (Terraform: 60s) | Sau khi `ReceiveMessage`, message "ẩn" 60s. Không `DeleteMessage` kịp → hiện lại → giao lại |
| **DeleteMessage = ACK** | Chỉ xóa khi đã xử lý xong |
| **Long polling** `waitTimeSeconds(10)` | Chờ tối đa 10s nếu hàng đợi rỗng → ít request rỗng, rẻ hơn |
| **Redrive policy** `maxReceiveCount: 5` | Nhận 5 lần mà vẫn không xóa → chuyển sang **DLQ** |
| **Receipt handle** | "Vé" để xóa đúng lần nhận đó (không phải message id) |

Message EventBridge đẩy vào SQS có dạng:

```json
{
  "version": "0",
  "id": "6a7e8feb-b491-4cf7-a9f1-bf3703467718",
  "detail-type": "OrderCompleted",
  "source": "bss.order",
  "account": "123456789012",
  "time": "2026-09-10T08:00:00Z",
  "region": "ap-southeast-1",
  "resources": [],
  "detail": { "orderId": "...", "customerId": "...", "amount": "199000", "currency": "VND", "completedAt": "..." }
}
```

### 7.2 `OrderEventListener` từng dòng

🔍 [OrderEventListener.java](../apps/backend/billing-service/src/main/java/com/bss/billing/listener/OrderEventListener.java)

| Dòng | Code | Giải thích |
|---|---|---|
| 37 | `static ObjectMapper json = new ObjectMapper()` | Tự tạo thay vì dùng bean của Spring (không có module Java Time...) — tiểu tiết |
| 54 | `@Scheduled(fixedDelay = 5000)` | Poll liên tục, nghỉ 5s giữa các lần |
| 56–60 | `ReceiveMessageRequest` tối đa 10 message, chờ 10s | |
| 62–73 | vòng lặp: `handle` → `ack`; trùng → vẫn `ack`; lỗi khác → **không ack** (để SQS giao lại → cuối cùng vào DLQ) | Đúng tinh thần |
| 76–77 | `@Transactional void handle(...)` | ⚠️ **B-10**: gọi từ `poll()` cùng class → **không có transaction** |
| 81 | `eventId = envelope.id` | ⚠️ **B-11**: id do EventBridge sinh mỗi lần PutEvents |
| 85–92 | chỉ xử lý `OrderCompleted`, parse `detail` | `OrderRefunded` có trong rule nhưng bị bỏ qua (log) và vẫn ACK |
| 98–105 | `saveDedupKey`: `save` + `flush`, bắt `DataIntegrityViolationException` → `DuplicateEventException` | Dùng **khóa chính của bảng** làm "khóa chống trùng" — ý tưởng đúng |

### 7.3 Vì sao B-10 làm mất hóa đơn — kịch bản cụ thể

```
Lần giao 1:
  poll() → this.handle(msg)          ← không qua proxy, KHÔNG có transaction bao ngoài
    processed.save(E1) + flush()     ← repository tự có transaction → COMMIT NGAY
    billing.invoiceFromOrder(...)    ← giả sử lỗi (DB chập chờn) → ném exception
  → catch Exception: không ack → message quay lại hàng đợi sau 60s
Lần giao 2:
    processed.save(E1) → vi phạm PRIMARY KEY → DuplicateEventException
  → catch Duplicate: ACK → message bị xóa
Kết quả: có dòng processed_event E1, KHÔNG có hóa đơn. Mất vĩnh viễn, không log lỗi ở lần 2.
```

Nếu `@Transactional` hoạt động đúng, lần 1 sẽ **rollback cả** `processed_event` → lần 2 xử lý lại bình thường.

**Cách sửa đúng tinh thần CLAUDE.md ("bug fix kèm test tái hiện"):**
1. Viết test: dùng `@SpyBean BillingService`, cho `invoiceFromOrder` ném lỗi ở lần gọi đầu; gọi handler 2 lần với cùng message; khẳng định cuối cùng **có đúng 1 hóa đơn**. Test phải **đỏ** trên code hiện tại.
2. Tách logic sang bean mới, ví dụ `OrderCompletedHandler` với `@Transactional public void handle(Message msg)`; `OrderEventListener` inject và gọi bean đó.
3. Chạy lại test → **xanh**.

### 7.4 `BillingService`

🔍 [BillingService.java](../apps/backend/billing-service/src/main/java/com/bss/billing/service/BillingService.java)

- `openAccount` (38–49): đã có account cho customer thì trả lại account cũ → **idempotent theo `customerId`** (kèm `UNIQUE(customer_id)` trong SQL làm lưới an toàn).
- `invoiceFromOrder` (84–117): tự mở account nếu chưa có ("lazy"); VAT = `amount × 0.10` làm tròn `HALF_UP` 2 chữ số; `invoice.amount` = **tổng đã gồm VAT**, `item.amount` = tiền trước thuế; `dueDate` = +15 ngày; trạng thái `Validated`.
- `generateInvoiceNumber` (119–125): `BSS-YYYYMMDD-<8 hex>` = 32 bit ngẫu nhiên/ngày → xác suất trùng đáng kể khi vài chục nghìn hóa đơn/ngày (bài toán ngày sinh). Có `UNIQUE` → trùng thì lỗi → message được giao lại → sinh số mới. Hóa đơn thật cần **dãy số liên tục** (quy định kế toán) → dùng `SEQUENCE` của Postgres.
- `findByBillingAccount_CustomerId` — derived query đi xuyên quan hệ (`invoice.billingAccount.customerId`), dấu `_` tách thuộc tính lồng.

---

## 8. api-gateway — Spring Cloud Gateway

🔍 [application.yml](../apps/backend/api-gateway/src/main/resources/application.yml)

- Gateway chạy trên **Spring WebFlux + Netty** (non-blocking) chứ không phải Tomcat.
- Mỗi route: `id`, `uri` (đích), `predicates` (điều kiện khớp — ở đây là `Path`), `filters`.
- `default-filters`: `StripPrefix=1` (bỏ 1 đoạn path đầu = `/api`) và `AddResponseHeader=X-Gateway, bss-api-gateway` (dễ nhận biết response đi qua gateway).
- `uri: http://customer-service.bss.svc.cluster.local` — DNS Service K8s dạng `<service>.<namespace>.svc.cluster.local`, cổng 80 (Service map 80 → 8080).
- ⚠️ **B-03**: route `/api/customers/**` → sau strip thành `/customers/**` → service không có → 404.
- Actuator mở thêm `gateway` → `GET /actuator/gateway/routes` xem route đang nạp (rất tiện để debug).
- **Còn thiếu** (so với mô tả "routing, auth, rate-limit"): timeout (`spring.cloud.gateway.httpclient.connect-timeout` / `response-timeout`), filter `Retry`, `CircuitBreaker` (Resilience4j), `RequestRateLimiter` (cần Redis), CORS, xác thực JWT (B-18).

🔁 Đồ án bạn dùng Nginx làm gateway (`osm-gateway`). Tương đương Nginx: `location /api/ { proxy_pass http://upstream/; }` — dấu `/` cuối trong `proxy_pass` chính là "strip prefix".

---

## 9. `bss-common-java` — thư viện dùng chung chưa ai dùng

🔍 [packages/bss-common-java](../packages/bss-common-java/)

Không service nào khai báo dependency `com.bss:bss-common-java`. Muốn dùng có 3 cách:

| Cách | Làm | ⚖️ |
|---|---|---|
| `mvn install` local | Build lib vào `~/.m2`, service khai báo dependency | Đơn giản; CI phải build lib trước |
| Maven multi-module | Tạo `apps/backend/pom.xml` (parent, `<modules>`) gồm lib + 5 service | Build một lần cho tất cả; mất tính độc lập từng service |
| Publish lên GitHub Packages (tinh thần Nexus) | `mvn deploy` lib có version; service dùng version cố định | Chuẩn nhất, đổi lib có kiểm soát; cần cấu hình registry + token |

Lưu ý thêm: nếu dùng `GlobalExceptionHandler` chung, service phải `@Import` hoặc đặt package quét — vì package `com.bss.common` nằm ngoài `com.bss.customer`.

---

## 10. Các chủ đề xuyên suốt

| Chủ đề | Hiện trạng | Cần làm |
|---|---|---|
| Probes | `/actuator/health/liveness` & `/readiness` được bật và manifest K8s dùng đúng | ✅ Hiểu: liveness **không** gồm DB (tránh restart hàng loạt khi DB chậm) |
| Metrics | Micrometer có sẵn `http_server_requests_seconds_*`, `jvm_*`, `hikaricp_*` | Bật histogram + tag `application` cho mọi service (B-16) |
| Logging | Text | Thêm `logstash-logback-encoder` hoặc (Boot 3.4+) structured logging; MDC `trace_id` (B-17) |
| Graceful shutdown | `server.shutdown: graceful` | Thêm `spring.lifecycle.timeout-per-shutdown-phase: 20s` + `preStop: sleep 5` ở K8s |
| Timeout/retry/circuit breaker | Không có | Resilience4j khi gọi service khác (B-13) |
| Idempotency-Key cho POST | Không có | Header `Idempotency-Key` + bảng lưu kết quả (quy ước CLAUDE.md §7) |

---

## 11. Labs

> Mỗi lab = 1 nhánh git + 1 PR. Chạy trong WSL2 cho giống Linux CI.

| Lab | Nội dung | Lỗi | Kiểm tra đạt |
|---|---|---|---|
| 10.1 | `mvn -B verify` cho từng service. **Điều tra**: test `*IT` có thực sự chạy không (đếm `Tests run`)? Nếu không, cấu hình surefire/failsafe cho đúng | B-09 | Log có `Tests run: 3` cho CustomerControllerIT |
| 10.2 | Khởi động customer-service với Postgres từ docker-compose; đọc log Flyway; `\dt` trong psql thấy `flyway_schema_history` | — | GET trả `[]` |
| 10.3 | Tạo `application-local.yml` cho 5 service (port 8081–8085, DB riêng, LocalStack) + gateway profile local | B-02 | Chạy đủ 5 service cùng lúc |
| 10.4 | Test giả thuyết mass-assignment (POST kèm `id` đã tồn tại); chuyển sang `CreateCustomerRequest` | B-15 | Test chứng minh trước/sau |
| 10.5 | Test phân trang `offset=10&limit=20`, `limit=0`, offset âm → sửa | B-15 | 3 test xanh |
| 10.6 | Test tái hiện mất hóa đơn → tách handler bean | **B-10** | Test đỏ → xanh |
| 10.7 | Thêm `eventId` (id outbox) vào payload + schema, dedup theo nó; thêm `UNIQUE(source_order_id)` ở `invoice_item` (Flyway V2) | B-11 | Giao cùng sự kiện 2 lần với 2 envelope id khác → 1 hóa đơn |
| 10.8 | `FOR UPDATE SKIP LOCKED` cho outbox; test 2 luồng drain song song | B-12 | Không có event gửi trùng |
| 10.9 | order gọi product-catalog lấy giá (RestClient + Resilience4j timeout/retry/circuit breaker) | B-13 | Gửi `unitPrice` sai → bị bỏ qua; product down → 503 rõ ràng |
| 10.10 | Sửa route gateway + thêm timeout + test gateway | B-03 | `/api/customers/...` hoặc bị bỏ hoặc chạy đúng |
| 10.11 | Thêm `sts` vào 2 pom; histogram + tag `application` cho 4 service | B-19, B-16 | `/actuator/prometheus` có `_bucket` và `application="..."` |
| 10.12 | Tắt scheduling trong test + stub mock; sửa so sánh chuỗi | B-14 | Log test sạch NPE |

---

## 12. Tự kiểm tra

1. Vì sao `@Transactional` trên method gọi nội bộ không có tác dụng? Nêu 2 cách khắc phục.
2. Outbox đảm bảo "exactly-once" hay "at-least-once"? Vì sao consumer vẫn phải idempotent?
3. Khác nhau giữa 400 và 422? 404 và 409 dùng khi nào trong dự án?
4. `ddl-auto: validate` giúp gì? Chuyện gì xảy ra nếu bạn sửa `V1__init_customer.sql` sau khi đã chạy?
5. Tại sao `product_offering_id` trong `order_item` không có FOREIGN KEY?
6. `fixedDelay` khác `fixedRate` thế nào? Với outbox nên dùng cái nào?
7. IRSA: liệt kê 4 bước từ annotation ServiceAccount đến lúc SDK có credential. Thiếu module nào thì bước cuối hỏng?
8. Tiền nên lưu bằng kiểu gì trong Java và Postgres? Vì sao?

<details><summary>Gợi ý đáp án ngắn</summary>

1. Gọi `this.x()` đi thẳng vào object thật, không qua proxy. Sửa: tách sang bean khác; hoặc inject chính mình qua proxy (`@Lazy` self-injection) / dùng `TransactionTemplate`.
2. At-least-once; publisher có thể gửi lại khi không kịp đánh dấu, SQS có thể giao lại.
3. 400: request hỏng cú pháp; 422: đúng cú pháp nhưng sai ràng buộc. 404 không tìm thấy; 409 xung đột trạng thái (email trùng).
4. Hibernate kiểm entity khớp bảng, lệch thì không khởi động. Sửa V1 → checksum lệch → Flyway báo lỗi validate và app không chạy.
5. Offering nằm ở database của service khác (database-per-service).
6. `fixedDelay` tính từ lúc kết thúc lần trước — tránh chồng lấn khi một lần chạy lâu.
7. Webhook tiêm `AWS_ROLE_ARN` + token file → SDK đọc token → gọi STS AssumeRoleWithWebIdentity → credential tạm. Thiếu `software.amazon.awssdk:sts`.
8. `BigDecimal` + `NUMERIC(p,s)`; số thực nhị phân không biểu diễn chính xác số thập phân.

</details>
