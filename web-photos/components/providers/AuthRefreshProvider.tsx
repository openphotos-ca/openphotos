'use client';

import React, { useEffect } from 'react';
import { useAuthStore } from '@/lib/stores/auth';
import { logger } from '@/lib/logger';

export function AuthRefreshProvider({ children }: { children: React.ReactNode }) {
  useEffect(() => {
    let unsub = false;
    const ensureUserProfile = async (source: 'mount' | 'visible') => {
      try {
        const st = useAuthStore.getState();
        if (!st.token || st.user?.user_id) return;
        const { authApi } = await import('@/lib/api/auth');
        const me = await authApi.me();
        if (unsub || !me?.user_id) return;
        const latestToken = useAuthStore.getState().token;
        if (!latestToken) return;
        useAuthStore.getState().updateToken(latestToken, me);
        logger.info('[AUTH REFRESH] Hydrated missing user profile', { source, userId: me.user_id });
      } catch (e) {
        logger.debug('[AUTH REFRESH] Unable to hydrate missing user profile', { source, error: (e as any)?.message || String(e) });
      }
    };

    const refreshWithStaleGuard = async (source: 'mount' | 'visible') => {
      const tokenBefore = useAuthStore.getState().token;
      try {
        const [{ authApi }, { apiClient }] = await Promise.all([
          import('@/lib/api/auth'),
          import('@/lib/api/client'),
        ]);
        const res = await authApi.refresh();
        if (unsub || !res?.token) return;
        const tokenAfter = useAuthStore.getState().token;
        // Ignore stale refresh responses when auth state changed in flight
        // (for example user completed a different login while this call was pending).
        if (tokenAfter !== tokenBefore) {
          logger.info('[AUTH REFRESH] Ignoring stale refresh result', {
            source,
            hadTokenBefore: !!tokenBefore,
            hasTokenAfter: !!tokenAfter,
          });
          return;
        }
        useAuthStore.getState().updateToken(res.token, res.user ?? undefined);
        apiClient.scheduleProactiveRefresh(res.expires_in);
        await ensureUserProfile(source);
      } catch {}
    };

    (async () => {
      await refreshWithStaleGuard('mount');
      await ensureUserProfile('mount');
    })();

    const onVis = async () => {
      if (document.visibilityState !== 'visible') return;
      await refreshWithStaleGuard('visible');
      await ensureUserProfile('visible');
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
