# 11 — Frontend: React 18 + Vite + TanStack Query + Nginx

> Mục tiêu bài: đọc hiểu 2 ứng dụng frontend, biết chúng build ra gì, được phục vụ thế nào trong container và K8s,
> và sửa B-04, B-05, B-06. Thời lượng: 2–3h đọc + 4–6h lab. Đọc ở **Giai đoạn 1**.
> Là DevOps, bạn không cần viết UI đẹp — nhưng phải hiểu **build, cấu hình runtime, routing, phục vụ tĩnh**.

---

## 1. React cho người đã biết Vue 3

| Vue 3 (đồ án) | React 18 (dự án) |
|---|---|
| File `.vue` (template + script + style) | File `.tsx` — HTML viết trong JS bằng **JSX** |
| `ref()`, `reactive()` | `useState()` |
| `computed`, `watch` | `useMemo`, `useEffect` |
| `vue-router` (`<router-view>`) | `react-router-dom` (`<Routes><Route/></Routes>`) |
| Pinia (state) | zustand (UI state) — có trong dependency web-portal nhưng chưa dùng |
| axios gọi API trong `onMounted` | **TanStack Query** (`useQuery`, `useMutation`) lo cache, loading, retry, refetch |
| `v-for`, `v-if` | `array.map(...)`, `{cond && <X/>}` |

🧠 **Vì sao TanStack Query ("react-query")?** Dữ liệu từ server không phải "state của UI" — nó có thể cũ, cần làm mới, cần cache. `useQuery({ queryKey, queryFn })` tự: gọi API, lưu cache theo `queryKey`, trả `isLoading/error/data`, gọi lại khi quay lại tab, và `refetchInterval` để poll. `useMutation` cho POST/DELETE, kèm `invalidateQueries` để làm mới danh sách liên quan.

---

## 2. Cấu trúc & build

🔍 [web-portal/package.json](../apps/frontend/web-portal/package.json)

| Script | Làm gì |
|---|---|
| `dev` | `vite` — dev server có hot reload, port **3000** (admin: 3001) |
| `build` | `tsc && vite build` — kiểm tra kiểu TypeScript (không sinh file vì `noEmit`) rồi Vite đóng gói ra `dist/` (HTML + JS/CSS đã minify, tên file có hash) |
| `preview` | Chạy thử bản build |
| `lint` | ESLint — ⚠️ **không có file cấu hình** (B-04) |
| `test` | vitest — ⚠️ **không có file test** (B-04) |

🔁 Handout 4: "frontend cần transpile + minify + bundle" — ở đây Vite (dùng esbuild + Rollup) làm việc của webpack. Output `dist/` là **artifact tĩnh**, không cần Node lúc chạy → phục vụ bằng Nginx.

🔍 [vite.config.ts](../apps/frontend/web-portal/vite.config.ts)
- `server.proxy['/api'] → http://localhost:8080`: khi dev, trình duyệt gọi `localhost:3000/api/...`, Vite chuyển tiếp sang gateway → **cùng origin, không cần CORS**. Chỉ có tác dụng ở `npm run dev`, không có trong bản build.
- `build.sourcemap: true`: sinh file `.map` để debug — ⚖️ lên prod sẽ lộ mã nguồn gốc; cân nhắc tắt hoặc chỉ upload lên công cụ theo dõi lỗi.
- `test: { environment: 'jsdom' }` — cấu hình vitest (giả lập DOM).

🔍 [tsconfig.json](../apps/frontend/web-portal/tsconfig.json): `strict: true`, `noUnusedLocals`... đúng quy ước "không `any`". `include: ["src"]` → `vite.config.ts` không bị `tsc` kiểm.

---

## 3. Đọc code web-portal

| File | Điểm chính |
|---|---|
| [main.tsx](../apps/frontend/web-portal/src/main.tsx) | Tạo `QueryClient`, bọc app trong `QueryClientProvider` + `BrowserRouter`; `StrictMode` (dev chạy effect 2 lần để bắt lỗi) |
| [App.tsx](../apps/frontend/web-portal/src/App.tsx) | 4 route: `/`, `/plans`, `/order/:offeringId`, `/bills` |
| [api/client.ts](../apps/frontend/web-portal/src/api/client.ts) | axios `baseURL: '/api'` (đường dẫn **tương đối** → cùng domain với trang → ALB route `/api` sang gateway); `DEMO_CUSTOMER_ID` cố định vì chưa có đăng nhập; `formatVND` dùng `Intl.NumberFormat('vi-VN')` |
| [PlansPage.tsx](../apps/frontend/web-portal/src/pages/PlansPage.tsx) | `useQuery` lấy offering `lifecycleStatus=Active`. ⚠️ Dùng `axios` trực tiếp với `/api/...` thay vì instance `api` — không nhất quán (đổi baseURL sau này sẽ sót) |
| [OrderPage.tsx](../apps/frontend/web-portal/src/pages/OrderPage.tsx) | Lấy offering theo id → `useMutation` POST order với **`unitPrice: offering.priceAmount`** — chính là chỗ frontend "quyết định giá" (B-13); thành công → invalidate `bills` và điều hướng `/bills` |
| [BillsPage.tsx](../apps/frontend/web-portal/src/pages/BillsPage.tsx) | `refetchInterval: 5000` — poll vì hóa đơn đến **bất đồng bộ** (eventual consistency). Đây là cách UI "sống chung" với kiến trúc event-driven |

❓ Tự kiểm tra: *Nếu billing-service chết 10 phút, trang Hóa đơn hiển thị gì? Khách có mất tiền/mất hóa đơn không?* (Gợi ý: SQS giữ message tới 4 ngày.)

## 4. Đọc code admin-console

| File | Điểm chính |
|---|---|
| [DashboardPage.tsx](../apps/frontend/admin-console/src/pages/DashboardPage.tsx) | Đếm bằng `data.length` với `limit=100` → tối đa hiển thị 100. Đúng ra đọc header `X-Total-Count` |
| [CustomersPage.tsx](../apps/frontend/admin-console/src/pages/CustomersPage.tsx) | Form tạo khách (luôn `status: 'Active'`), nút Xóa gọi DELETE — **không có xác thực** (B-18) |
| [OfferingsPage.tsx](../apps/frontend/admin-console/src/pages/OfferingsPage.tsx) | Liệt kê category + offering (chỉ đọc) |

`packages/ui-kit` (Button, Card) **không được import** ở đâu. Để dùng: npm workspaces (root `package.json` với `"workspaces": ["apps/frontend/*", "packages/ui-kit"]`) — nhưng khi đó Dockerfile phải build từ gốc repo (context lớn hơn). ⚖️ Monorepo JS luôn có trade-off này.

---

## 5. Phục vụ trong container: Nginx

🔍 [nginx.conf](../apps/frontend/web-portal/nginx.conf)

```nginx
server {
  listen 8080;                         # port >1024 → user thường mở được (non-root không mở được port 80)
  root /usr/share/nginx/html;
  location / {
    try_files $uri $uri/ /index.html;  # SPA fallback: /plans không phải file thật → trả index.html, React Router lo phần còn lại
  }
  location ~* \.(js|css|woff2|svg|png|jpg|jpeg|gif|ico)$ {
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";   # an toàn vì tên file có hash
  }
  location = /healthz { return 200 'ok'; }   # cho probe K8s
}
```

⚠️ `index.html` **không** được đánh cache riêng → trình duyệt/CDN có thể giữ bản cũ trỏ tới JS cũ. Best practice: `index.html` → `Cache-Control: no-cache`; asset có hash → `immutable`.

⚠️ Nginx **không** proxy `/api` (khác lab 3.3 của course nói). Trên K8s việc đó do ALB/Ingress làm. Chạy `docker run` riêng image frontend thì trang Plans sẽ lỗi gọi API — đó là đúng thiết kế.

🔍 [Dockerfile](../apps/frontend/web-portal/Dockerfile)

| Dòng | Code | Ghi chú |
|---|---|---|
| 7–12 | `node:20-alpine` build: copy `package.json` + `package-lock.json*` trước → `npm ci || npm install` → copy source → `npm run build` | Thứ tự copy tận dụng cache layer (🔁 handout 7). ⚠️ `npm ci` cần lockfile; `|| npm install` che lỗi và cho build không tái lập (B-04). Thiếu `.dockerignore` → `node_modules` local bị copy vào context |
| 14–16 | `nginx:1.27-alpine`, copy `dist/` và `nginx.conf` | |
| 17–18 | tạo user uid 1000, `chown`, `USER nginx-user` | ⚠️ B-05: nginx vẫn cần ghi `/run/nginx.pid` → lỗi quyền khi `docker run`. Dùng `nginxinc/nginx-unprivileged:1.27-alpine` (đã cấu hình pid ở `/tmp`, chạy uid 101, port 8080) |

⚖️ **Cấu hình theo môi trường cho SPA:** biến `VITE_*` bị "nướng" vào bundle lúc build → trái nguyên tắc *build once, deploy many*. Dự án né được nhờ dùng đường dẫn tương đối `/api` (mọi môi trường giống nhau). Nếu sau này cần URL khác nhau theo môi trường → sinh file `/config.js` lúc container khởi động (entrypoint script) thay vì build lại.

---

## 6. B-06: admin-console dưới `/admin`

Ingress gửi `/admin*` → admin-console. Nhưng HTML của admin tham chiếu `/assets/index-abc.js` (base `/`) → ALB thấy `/assets` không bắt đầu bằng `/admin` → gửi sang **web-portal** → 404 hoặc trả nhầm file. Hai cách:

| Cách | Làm | ⚖️ |
|---|---|---|
| Base path | `vite.config.ts`: `base: '/admin/'`; `<BrowserRouter basename="/admin">`; `nginx.conf` phục vụ dưới `/admin/` | Một domain; phải sửa 3 chỗ |
| Tách host | Ingress rule host `admin.dev.<domain>` | Gọn, tách quyền truy cập dễ (WAF/IP allowlist riêng cho admin); cần thêm DNS/cert |

---

## 7. Labs

| Lab | Nội dung | Lỗi | Đạt khi |
|---|---|---|---|
| 11.1 | `npm install` → commit `package-lock.json` cho 2 app; `npm run build` | B-04 | `npm ci` chạy được |
| 11.2 | Thêm cấu hình ESLint (flat config `eslint.config.js`), sửa cảnh báo | B-04 | `npm run lint` exit 0 |
| 11.3 | Viết test vitest + Testing Library cho `formatVND` và `PlansPage` (mock API) | B-04 | `npm test` xanh |
| 11.4 | Chạy `npm run dev` + gateway local (sau lab 10.3) → đặt hàng qua UI → thấy hóa đơn | — | Flow UI end-to-end |
| 11.5 | Đổi Dockerfile sang `nginx-unprivileged`, thêm `.dockerignore`, cache header cho `index.html` | B-05 | `docker run -p 8080:8080` mở được trang |
| 11.6 | Sửa admin dưới `/admin` (chọn 1 trong 2 cách, ghi ADR ngắn) | B-06 | Asset admin tải đúng |
| 11.7 | PlansPage dùng instance `api`; Dashboard đọc `X-Total-Count` | — | Nhất quán |

## 8. Tự kiểm tra

1. Vì sao frontend build xong không cần Node.js lúc chạy?
2. `try_files $uri $uri/ /index.html` giải quyết vấn đề gì của SPA?
3. Vite dev proxy khác Ingress ALB thế nào — cái nào có mặt ở production?
4. Vì sao biến `VITE_API_URL` đi ngược nguyên tắc build once, deploy many?
5. Vì sao container non-root phải lắng nghe port ≥ 1024?
