/// <reference types="vite/client" />

interface ImportMetaEnv {
  /**
   * Giai đoạn 9: ghi đè địa chỉ Keycloak (tùy chọn). Bản build cho kind/AWS KHÔNG đặt biến này:
   * địa chỉ suy ra từ origin của trang (cùng origin, path /auth — ADR-008 quyết định 2), nhờ vậy 1
   * image chạy được ở mọi môi trường ("build once, deploy many"). Xem src/auth/oidcConfig.ts.
   */
  readonly VITE_OIDC_AUTHORITY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
