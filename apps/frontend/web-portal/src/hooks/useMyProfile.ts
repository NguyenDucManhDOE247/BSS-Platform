import { useQuery } from '@tanstack/react-query';
import { isAxiosError } from 'axios';
import { useAuth } from 'react-oidc-context';
import { api } from '../api/client';

export type CustomerStatus = 'Initialized' | 'Validated' | 'Active' | 'Suspended' | 'Terminated';

export interface MyProfile {
  id: string;
  name: string;
  email: string;
  phoneNumber?: string | null;
  status: CustomerStatus;
}

/**
 * Hồ sơ khách hàng của người đang đăng nhập (`GET /customer/me`). `null` = đã đăng nhập Keycloak
 * nhưng CHƯA tạo hồ sơ (API trả 404) — trang Hồ sơ hiện form "hoàn tất hồ sơ" lúc đó.
 */
export function useMyProfile() {
  const auth = useAuth();
  return useQuery({
    queryKey: ['me', auth.user?.profile.sub],
    enabled: auth.isAuthenticated,
    queryFn: async (): Promise<MyProfile | null> => {
      try {
        return (await api.get<MyProfile>('/tmf-api/customerManagement/v4/customer/me')).data;
      } catch (err) {
        if (isAxiosError(err) && err.response?.status === 404) return null;
        throw err;
      }
    },
  });
}

/** Câu giải thích trạng thái cho khách (ADR-008 quyết định 3: phải được admin duyệt mới mua được). */
export const statusText: Record<CustomerStatus, string> = {
  Initialized: 'Đang chờ nhân viên duyệt hồ sơ — bạn chưa thể đăng ký gói cho tới khi được duyệt.',
  Validated: 'Hồ sơ đã được xác minh, đang chờ kích hoạt.',
  Active: 'Đã kích hoạt — bạn có thể đăng ký gói cước.',
  Suspended: 'Tài khoản đang bị tạm khóa — vui lòng liên hệ tổng đài.',
  Terminated: 'Tài khoản đã chấm dứt.',
};
