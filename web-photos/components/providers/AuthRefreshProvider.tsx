'use client';

import React, { useEffect } from 'react';
import { useAuthStore } from '@/lib/stores/auth';

export function AuthRefreshProvider({ children }: { children: React.ReactNode }) {
  useEffect(() => {
    let unsub = false;
    (async () => {
      try {
        const [{ authApi }, { apiClient }] = await Promise.all([
          import('@/lib/api/auth'),
          import('@/lib/api/client'),
        ]);
        const res = await authApi.refresh();
        if (!unsub && res?.token) {
          useAuthStore.getState().updateToken(res.token);
          apiClient.scheduleProactiveRefresh(res.expires_in);
        }
      } catch {}
    })();

    const onVis = async () => {
      if (document.visibilityState !== 'visible') return;
      try {
        const [{ authApi }, { apiClient }] = await Promise.all([
          import('@/lib/api/auth'),
          import('@/lib/api/client'),
        ]);
        const res = await authApi.refresh();
        if (res?.token) {
          useAuthStore.getState().updateToken(res.token);
          apiClient.scheduleProactiveRefresh(res.expires_in);
        }
      } catch {}
    };
    document.addEventListener('visibilitychange', onVis);

    return () => {
      unsub = true;
      document.removeEventListener('visibilitychange', onVis);
      (async () => { try { const { apiClient } = await import('@/lib/api/client'); apiClient.clearProactiveRefresh(); } catch {} })();
    };
  }, []);

  return <>{children}</>;
}

