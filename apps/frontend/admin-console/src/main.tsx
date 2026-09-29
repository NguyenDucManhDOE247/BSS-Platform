import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { AuthProvider } from 'react-oidc-context';
import App from './App';
import AdminGate from './components/AdminGate';
import { oidcConfig } from './auth/oidcConfig';
import './index.css';

const queryClient = new QueryClient();

// Giai đoạn 9 (ADR-008): AuthProvider bọc ngoài cùng (xử lý ?code=... khi Keycloak chuyển về), rồi
// AdminGate chặn MỌI trang với người không có role admin — admin-console không có trang công khai nào.
ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <AuthProvider {...oidcConfig}>
      <QueryClientProvider client={queryClient}>
        <BrowserRouter basename="/admin">
          <AdminGate>
            <App />
          </AdminGate>
        </BrowserRouter>
      </QueryClientProvider>
    </AuthProvider>
  </React.StrictMode>,
);
