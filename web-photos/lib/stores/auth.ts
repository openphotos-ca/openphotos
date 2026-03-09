import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import { logger } from '@/lib/logger';
import { resolveApiBaseUrl } from '@/lib/api/base';

export interface User {
  id: number;
  user_id: string;
  name: string;
  email: string | null;
  organization_id: number;
  role: string;
  avatar: string | null;
  status: string;
}

interface AuthState {
  token: string | null;
  user: User | null;
  isAuthenticated: boolean;
  hasHydrated: boolean;
  
  // Actions
  login: (token: string, user: User) => void;
  updateToken: (token: string, user?: User | null) => void;
  logout: () => void;
  updateUser: (user: Partial<User>) => void;
  setHydrated: () => void;
}

export const useAuthStore = create<AuthState>()(
  persist(
    (set, get) => ({
      token: null,
      user: null,
      isAuthenticated: false,
      hasHydrated: false,

      login: (token: string, user: User) => {
        logger.info('[AUTH STORE] Login called:', {
          tokenLength: token.length,
          userId: user.id,
          userName: user.name
        });
        // Set cookie for middleware (avoid `secure` on http during dev)
        if (typeof document !== 'undefined') {
          const attrs = [
            'path=/',
            `max-age=${7 * 24 * 60 * 60}`,
            'samesite=strict',
          ];
          if (window.location.protocol === 'https:') {
            attrs.push('secure');
          }
          document.cookie = `auth-token=${token}; ${attrs.join('; ')}`;
          logger.debug('[AUTH STORE] Set auth cookie');
        }
        
        set({
          token,
          user,
          isAuthenticated: true,
        });
        logger.info('[AUTH STORE] State updated - authenticated');
      },

      updateToken: (token: string, user?: User | null) => {
        logger.info('[AUTH STORE] updateToken called:', {
          tokenLength: token?.length || 0,
          hasUser: !!user,
          userId: user?.id,
          userName: user?.name,
        });
        set((state) => ({
          token,
          user: user === undefined ? state.user : user,
          isAuthenticated: !!token,
        }));
      },

      logout: () => {
        logger.info('[AUTH STORE] Logout called');
        const token = get().token;
        if (typeof window !== 'undefined') {
          const apiBase = resolveApiBaseUrl(process.env.NEXT_PUBLIC_API_URL || '/api');
          // Best-effort server logout so HttpOnly refresh cookies are cleared too.
          void fetch(`${apiBase}/auth/logout`, {
            method: 'POST',
            headers: token
              ? { 'Authorization': `Bearer ${token}` }
              : undefined,
            credentials: 'same-origin',
          }).catch((error) => {
            logger.warn('[AUTH STORE] Server logout failed', error);
          });
        }
        // Clear cookie
        if (typeof document !== 'undefined') {
          const attrs = ['path=/', 'expires=Thu, 01 Jan 1970 00:00:01 GMT'];
          if (window.location.protocol === 'https:') {
            attrs.push('secure');
          }
          document.cookie = `auth-token=; ${attrs.join('; ')}`;
          logger.debug('[AUTH STORE] Cleared auth cookie');
        }
        // Clear proactive refresh timer
        (async () => {
          try { const { apiClient } = await import('@/lib/api/client'); apiClient.clearProactiveRefresh(); } catch {}
        })();
        
        set({
          token: null,
          user: null,
          isAuthenticated: false,
        });
        logger.info('[AUTH STORE] State updated - logged out');
      },

      updateUser: (updatedUser: Partial<User>) => {
        const currentUser = get().user;
        if (currentUser) {
          set({
            user: { ...currentUser, ...updatedUser },
          });
        }
      },

      setHydrated: () => {
        logger.debug('[AUTH STORE] Hydration completed');
        set({ hasHydrated: true });
      },
    }),
    {
      name: 'auth-storage',
      partialize: (state) => ({
        token: state.token,
        user: state.user,
        isAuthenticated: state.isAuthenticated,
      }),
    }
  )
);

// Initialize hydration immediately when the store is created
if (typeof window !== 'undefined') {
  logger.debug('[AUTH STORE] Initializing hydration on client side');
  // Give Zustand a moment to rehydrate from localStorage, then mark as hydrated
  setTimeout(() => {
    logger.debug('[AUTH STORE] Triggering hydration flag after 100ms');
    useAuthStore.getState().setHydrated();
  }, 100);
}
