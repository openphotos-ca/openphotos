'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';

import { useAuthStore } from '@/lib/stores/auth';
import { logger } from '@/lib/logger';

export default function OAuthCallbackPage() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const rawHash = typeof window !== 'undefined' ? window.location.hash : '';
        const rawQuery = typeof window !== 'undefined' ? window.location.search : '';
        const hashParams = new URLSearchParams(rawHash.startsWith('#') ? rawHash.slice(1) : rawHash);
        const queryParams = new URLSearchParams(rawQuery.startsWith('?') ? rawQuery.slice(1) : rawQuery);

        const token = hashParams.get('token') || queryParams.get('token');
        const expiresInRaw = hashParams.get('expires_in') || queryParams.get('expires_in');
        const expiresIn = expiresInRaw ? parseInt(expiresInRaw, 10) : undefined;

        if (!token) {
          throw new Error('Missing OAuth token');
        }

        // Remove the token from the URL bar/history as soon as possible.
        try {
          window.history.replaceState({}, document.title, window.location.pathname);
        } catch {}

        const meRes = await fetch('/api/auth/me', {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (!meRes.ok) {
          throw new Error('Failed to complete sign-in');
        }
        const user = await meRes.json();

        if (cancelled) return;
        useAuthStore.getState().login(token, user);
        try {
          const { apiClient } = await import('@/lib/api/client');
          apiClient.scheduleProactiveRefresh(expiresIn);
        } catch {}

        router.replace('/');
      } catch (e: any) {
        logger.error('[OAUTH] callback error', e);
        if (!cancelled) setError(e?.message || 'OAuth sign-in failed');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [router]);

  return (
    <div className="min-h-screen flex items-center justify-center bg-background text-foreground px-4">
      <div className="w-full max-w-md rounded-xl border bg-card p-6 text-center shadow-sm">
        {error ? (
          <>
            <h1 className="text-xl font-semibold mb-2">Sign-in failed</h1>
            <p className="text-sm text-muted-foreground mb-4">{error}</p>
            <button
              className="w-full rounded-md bg-primary px-4 py-2 text-primary-foreground"
              onClick={() => router.replace('/auth')}
            >
              Back to login
            </button>
          </>
        ) : (
          <>
            <div className="mx-auto mb-4 h-10 w-10 animate-spin rounded-full border-2 border-muted border-t-primary" />
            <h1 className="text-xl font-semibold mb-2">Completing sign-in…</h1>
            <p className="text-sm text-muted-foreground">You will be redirected automatically.</p>
          </>
        )}
      </div>
    </div>
  );
}

