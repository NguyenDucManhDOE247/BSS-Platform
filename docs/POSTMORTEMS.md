# Postmortems

Định dạng: **Tóm tắt → Tác động → Dòng thời gian → Nguyên nhân gốc → Vì sao không phát hiện sớm
hơn → Cách sửa → Bài học**. Chỉ ghi sự cố có giá trị học thật (không phải mọi bug nhỏ — xem
`learning/01-hien-trang-va-danh-sach-loi.md` cho danh sách đầy đủ B-xx).

---

## PM-01 — Cơ chế chống trùng hóa đơn "đã sửa" nhưng không hoạt động thật suốt ~4 tháng

- **Mức độ:** 🔴 Cao (data correctness — có thể phát hành **2 hóa đơn cho 1 đơn hàng**, hoặc mất
  hóa đơn, tùy thời điểm trùng lặp xảy ra).
- **Thời gian tồn tại:** 2026-05-28 (PR #47, tưởng đã fix) → 2026-09-22 (CI thật phát hiện, PR #102 sửa dứt điểm) ≈ **4 tháng**.
- **Liên quan:** B-10, B-11 (`learning/01-hien-trang-va-danh-sach-loi.md` mục 4.2).

### Tóm tắt

`billing-service` chống trùng hóa đơn bằng một bảng `processed_event(event_id PK)`: nhận event
`OrderCompleted` từ SQS → nếu `event_id` đã có trong bảng → bỏ qua (đã xử lý rồi) → nếu chưa có →
lưu `event_id` + tạo hóa đơn, trong cùng 1 transaction. Giai đoạn 1 (PR #47) đã sửa **2 lỗi thật**
trong cơ chế này (B-10: `@Transactional` vô hiệu do self-invocation; B-11: dedup sai theo
`envelope.id` thay vì `eventId` ổn định) — kèm test `OrderCompletedHandlerIT` báo **xanh**.

Cả hai bản vá đều **có tác dụng đúng như thiết kế** — nhưng dedup vẫn không hoạt động, vì một lỗi
thứ ba, ở một lớp hoàn toàn khác (ORM), không ai biết tới cho tới 4 tháng sau.

### Tác động

Không ghi nhận sự cố thật trên dữ liệu khách hàng (chưa có traffic thật ở giai đoạn này của dự án).
Tác động thực tế: **~4 tháng** codebase chạy với một lớp bảo vệ tưởng tồn tại nhưng không hề hoạt
động — nếu dự án đã lên production ở giai đoạn đó, một lần SQS giao lại message (chuyện bình
thường, "at-least-once delivery") có thể đã tạo ra hóa đơn trùng thật.

### Dòng thời gian

| Ngày | Sự kiện |
|---|---|
| 2026-05-28 | PR #47: sửa B-10 (self-invocation), B-11 (dedup key) cho `billing-service`. `OrderCompletedHandlerIT` viết mới, **báo xanh**. |
| 2026-09-14/15 | Giai đoạn 1: cố chạy `mvn verify` (Testcontainers) tại chỗ để tự tay xác nhận test — **bị chặn bởi lỗi môi trường Docker Desktop/docker-java trên Windows**, tái lập được, xác nhận không phải lỗi code. Test coi như "đã viết đúng, để CI thật chạy sau". |
| 2026-09-22 | Giai đoạn 3: CI thật (GitHub Actions, Docker gốc Linux) lần đầu chạy đủ sâu, đủ dữ liệu tích lũy qua nhiều test case → lộ ra `ProcessedEvent` không hề chặn trùng. |
| 2026-09-22 | PR #102: sửa nguyên nhân gốc (đổi cách sinh khóa chính, xem dưới). CI xanh **thật** lần này — xác nhận bằng cách đọc `Tests run` và log test, không chỉ tin dấu tích xanh. |

### Nguyên nhân gốc

`ProcessedEvent` dùng khóa chính **gán tay từ code** (`@Id private String eventId;`, không phải
`@GeneratedValue`). Với Spring Data JPA, `save()` trên một entity có PK **do người dùng tự gán**
(không do database/JPA sinh ra) khiến Hibernate không biết chắc đây là bản ghi mới hay đã tồn tại —
hành vi mặc định là gọi `merge()` (coi như UPDATE một bản ghi có thể đã tồn tại) thay vì `persist()`
(INSERT chắc chắn là bản ghi mới). `merge()` với PK không tồn tại trong DB vẫn thành công (Hibernate
tự "upsert") — nghĩa là gọi `save()` **hai lần với cùng `eventId`** vẫn chạy trót lọt cả hai lần,
không hề ném lỗi trùng khóa như code kỳ vọng. Cơ chế dedup dựa trên giả định "insert trùng khóa
chính sẽ ném exception" — giả định đó **sai** với cách JPA xử lý entity có PK gán tay.

### Vì sao không phát hiện sớm hơn — đây là phần quan trọng nhất

1. **Test "trông đúng logic" nhưng chưa từng thực sự chạy.** `OrderCompletedHandlerIT` dùng
   Testcontainers (Postgres thật trong Docker) — đúng cách làm được khuyến khích (CLAUDE.md §9:
   "không mock DB ở integration test"). Nhưng ở Giai đoạn 1, Testcontainers **bị chặn bởi lỗi môi
   trường** (Docker Desktop/docker-java trên Windows) — nên "test đã viết, đã tưởng chạy xanh ở PR
   #47" thực ra **chưa từng được chạy trên máy nào** cho tới khi có CI Linux thật.
2. **CI ban đầu "xanh" không đồng nghĩa "đã chạy".** Giai đoạn 3 tự phát hiện một vấn đề khác cùng
   họ (B-09: thiếu `maven-failsafe-plugin`, khiến `mvn verify` có thể báo xanh với **0 test `*IT`
   nào thực sự thực thi**). Cho tới khi cả hai được xác nhận (failsafe được thêm + CI thật chạy
   được Testcontainers), không ai *biết chắc* `OrderCompletedHandlerIT` đã từng thực thi.
3. **Bug nằm sai lớp so với nơi người viết code đang nhìn.** B-10/B-11 là bug *nghiệp vụ* (đường đi
   của transaction, chọn sai trường làm khóa). Bug thật (merge/persist) là bug *cơ chế ORM* — người
   review code đúng logic nghiệp vụ (dùng `eventId` ổn định, đúng transaction boundary) vẫn có thể
   bỏ sót, vì nó đòi hỏi hiểu **Hibernate quyết định INSERT hay UPDATE dựa trên điều gì** — kiến
   thức nằm ngoài phạm vi "đọc lại code nghiệp vụ".

### Cách sửa (PR #102)

Đổi `ProcessedEvent` sang dùng chiến lược cho phép Hibernate/JPA biết chắc đây luôn là bản ghi
**mới** (ví dụ: interface `Persistable<String>` trả `isNew() = true` tường minh, hoặc dùng
`saveAndFlush` bắt `DataIntegrityViolationException` từ ràng buộc `UNIQUE`/PK ở tầng DB thay vì dựa
vào hành vi ngầm định của `save()`). Cách sửa đúng cho **cả hai trường hợp** entity có PK gán tay
trong hệ thống. Xem diff PR #102 để có chi tiết implementation.

### Bài học

1. **"CI xanh" chỉ đáng tin khi biết chắc nó đã THỰC SỰ chạy** — luôn đọc số `Tests run` trong log,
   không chỉ nhìn dấu ✓. Một pipeline có thể xanh vì test pass, hoặc xanh vì test **không hề chạy**
   — hai trạng thái nhìn giống hệt nhau trên giao diện GitHub Actions.
2. Khi một môi trường (ở đây: Testcontainers cục bộ trên Windows) bị chặn bởi lỗi hạ tầng, đừng coi
   phần việc phụ thuộc vào nó là "xong" — ghi rõ **"chưa xác nhận được, sẽ xác nhận ở môi trường
   khác"** (đúng như `learning/20-lo-trinh-hoan-thanh.md` đã làm), và quay lại xác nhận thật ngay
   khi môi trường đó sẵn sàng.
3. Một entity có khóa chính **gán tay** (không để JPA/DB tự sinh) luôn cần tự hỏi: "Hibernate sẽ
   coi `save()` lần đầu là INSERT hay UPDATE?" — câu trả lời mặc định (`merge()`) thường **không**
   phải điều bạn muốn cho một bảng dùng để chống trùng.
4. Bug hiểm nhất không phải bug logic sai rõ ràng — mà là bug khiến **cơ chế bảo vệ tưởng đang chạy
   nhưng thực ra là no-op**. Luôn có ít nhất 1 test **cố tình gọi 2 lần với cùng input**, chạy thật
   (không mock), để tận mắt thấy lần gọi thứ 2 bị chặn — không chỉ tin vào "logic đọc có vẻ đúng".
