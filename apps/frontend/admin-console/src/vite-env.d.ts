/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Ghi đè địa chỉ Keycloak (tùy chọn) — xem src/auth/oidcConfig.ts và web-portal cùng tên file. */
  readonly VITE_OIDC_AUTHORITY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
