import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { AuthProvider } from 'react-oidc-context';
import App from './App';
import { oidcConfig } from './auth/oidcConfig';
import './index.css';

const queryClient = new QueryClient();

// Giai đoạn 9 (ADR-008): AuthProvider bọc ngoài cùng — xử lý luôn lúc Keycloak chuyển về kèm
// ?code=...&state=... (đổi code lấy token), trước khi router/trang nào render.
ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <AuthProvider {...oidcConfig}>
      <QueryClientProvider client={queryClient}>
        <BrowserRouter>
          <App />
        </BrowserRouter>
      </QueryClientProvider>
    </AuthProvider>
  </React.StrictMode>,
);
