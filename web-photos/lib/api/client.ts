import { useAuthStore } from '@/lib/stores/auth';
import { logger } from '@/lib/logger';
import { resolveApiBaseUrl } from './base';

const API_BASE_URL = resolveApiBaseUrl(process.env.NEXT_PUBLIC_API_URL || '/api');

class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
    public response?: Response
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export class ApiClient {
  private baseUrl: string;
  private refreshTimer: any = null;

  constructor(baseUrl: string = API_BASE_URL) {
    this.baseUrl = resolveApiBaseUrl(baseUrl || '/api');
  }

  private getAuthHeaders(): HeadersInit {
    const token = useAuthStore.getState().token;
    const authState = useAuthStore.getState();
    logger.debug('[API CLIENT] Auth headers check:', {
      hasToken: !!token,
      tokenLength: token?.length || 0,
      isAuthenticated: authState.isAuthenticated,
      userId: authState.user?.id
    });
    if (token) {
      return {
        'Authorization': `Bearer ${token}`,
      };
    }
    return {};
  }

  private async handleResponse<T>(response: Response): Promise<T> {
    logger.debug('[API CLIENT] Response status:', response.status, response.statusText);
    if (!response.ok) {
      let errorMessage = `HTTP error! status: ${response.status}`;
      
      try {
        const errorData = await response.json();
        // Prefer human-readable `message` when provided, but fall back to `error` code/string.
        errorMessage = errorData.message || errorData.error || errorMessage;
        logger.debug('[API CLIENT] Error response data:', errorData);
      } catch {
        // Ignore JSON parse errors
        logger.debug('[API CLIENT] Could not parse error response as JSON');
      }

      if (response.status === 401) {
        // Avoid logging out for PIN-related endpoints or PIN-specific errors
        let skipLogout = false;
        try {
          const url = new URL(response.url);
          if (url.pathname.includes('/pin/') || url.pathname.includes('/crypto/envelope')) {
            skipLogout = true;
          }
        } catch {}

        const upperMsg = (errorMessage || '').toUpperCase();
        if (upperMsg.includes('PIN')) skipLogout = true;

        if (!skipLogout) {
          logger.info('[API CLIENT] 401 response');
        } else {
          logger.info('[API CLIENT] 401 on PIN-related request - not logging out');
        }
      }

      throw new ApiError(errorMessage, response.status, response);
    }

    const contentType = response.headers.get('content-type');
    if (contentType && contentType.includes('application/json')) {
      return response.json();
    }
    
    return response.text() as unknown as T;
  }

  private async tryRefresh(): Promise<boolean> {
    // Use a raw fetch to avoid recursive calls through post() which would
    // re-enter tryRefresh on 401 and spam /auth/refresh.
    try {
      const token = useAuthStore.getState().token;
      const res = await fetch(`${this.baseUrl}/auth/refresh`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
      });
      if (res.ok) {
        const data = await res.json();
        if (data?.token) {
          useAuthStore.getState().updateToken(data.token);
          this.scheduleProactiveRefresh(data.expires_in);
          return true;
        }
      }
    } catch (e) {
      logger.warn('[API CLIENT] Refresh failed', e);
    }
    return false;
  }

  async get<T>(endpoint: string, params?: Record<string, any>): Promise<T> {
    let url: URL;
    const fullUrl = `${this.baseUrl}${endpoint}`;
    
    try {
      // Handle both absolute and relative URLs
      if (fullUrl.startsWith('http')) {
        url = new URL(fullUrl);
      } else {
        url = new URL(fullUrl, window.location.origin);
      }
    } catch (error) {
      logger.error('Failed to construct URL:', fullUrl, error);
      throw new Error(`Failed to construct URL: ${fullUrl}`);
    }
    
    if (params) {
      Object.entries(params).forEach(([key, value]) => {
        if (value !== undefined && value !== null) {
          if (Array.isArray(value)) {
            value.forEach(v => url.searchParams.append(key, String(v)));
          } else {
            url.searchParams.append(key, String(value));
          }
        }
      });
    }

    let response = await fetch(url.toString(), {
      method: 'GET',
      headers: {
        'Content-Type': 'application/json',
        ...this.getAuthHeaders(),
      },
    });
    try {
      return await this.handleResponse<T>(response);
    } catch (err) {
      const isCryptoEnvelope = (() => { try { return url.pathname.includes('/crypto/envelope'); } catch { return false; } })();
      if (err instanceof ApiError && err.status === 401) {
        const ok = await this.tryRefresh();
        if (ok) {
          response = await fetch(url.toString(), {
            method: 'GET',
            headers: {
              'Content-Type': 'application/json',
              ...this.getAuthHeaders(),
            },
          });
          return this.handleResponse<T>(response);
        }
        if (!isCryptoEnvelope) {
          useAuthStore.getState().logout();
        }
      }
      throw err;
    }
  }

  async post<T>(endpoint: string, data?: any): Promise<T> {
    let response = await fetch(`${this.baseUrl}${endpoint}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...this.getAuthHeaders(),
      },
      body: data ? JSON.stringify(data) : undefined,
    });
    try {
      return await this.handleResponse<T>(response);
    } catch (err) {
      const isCryptoEnvelope = endpoint.includes('/crypto/envelope');
      if (err instanceof ApiError && err.status === 401 && endpoint !== '/auth/refresh') {
        const ok = await this.tryRefresh();
        if (ok) {
          response = await fetch(`${this.baseUrl}${endpoint}`, {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              ...this.getAuthHeaders(),
            },
            body: data ? JSON.stringify(data) : undefined,
          });
          return this.handleResponse<T>(response);
        }
        if (!isCryptoEnvelope) {
          useAuthStore.getState().logout();
        }
      }
      throw err;
    }
  }

  async put<T>(endpoint: string, data?: any): Promise<T> {
    let response = await fetch(`${this.baseUrl}${endpoint}`, {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
        ...this.getAuthHeaders(),
      },
      body: data ? JSON.stringify(data) : undefined,
    });
    try {
      return await this.handleResponse<T>(response);
    } catch (err) {
      const isCryptoEnvelope = endpoint.includes('/crypto/envelope');
      if (err instanceof ApiError && err.status === 401) {
        const ok = await this.tryRefresh();
        if (ok) {
          response = await fetch(`${this.baseUrl}${endpoint}`, {
            method: 'PUT',
            headers: {
              'Content-Type': 'application/json',
              ...this.getAuthHeaders(),
            },
            body: data ? JSON.stringify(data) : undefined,
          });
          return this.handleResponse<T>(response);
        }
        if (!isCryptoEnvelope) {
          useAuthStore.getState().logout();
        }
      }
      throw err;
    }
  }

  async delete<T>(endpoint: string): Promise<T> {
    let response = await fetch(`${this.baseUrl}${endpoint}`, {
      method: 'DELETE',
      headers: {
        'Content-Type': 'application/json',
        ...this.getAuthHeaders(),
      },
    });
    try {
      return await this.handleResponse<T>(response);
    } catch (err) {
      const isCryptoEnvelope = endpoint.includes('/crypto/envelope');
      if (err instanceof ApiError && err.status === 401) {
        const ok = await this.tryRefresh();
        if (ok) {
          response = await fetch(`${this.baseUrl}${endpoint}`, {
            method: 'DELETE',
            headers: {
              'Content-Type': 'application/json',
              ...this.getAuthHeaders(),
            },
          });
          return this.handleResponse<T>(response);
        }
        if (!isCryptoEnvelope) {
          useAuthStore.getState().logout();
        }
      }
      throw err;
    }
  }

  async uploadFile<T>(endpoint: string, file: File, additionalData?: Record<string, any>): Promise<T> {
    const formData = new FormData();
    formData.append('file', file);
    
    if (additionalData) {
      Object.entries(additionalData).forEach(([key, value]) => {
        formData.append(key, String(value));
      });
    }

    const response = await fetch(`${this.baseUrl}${endpoint}`, {
      method: 'POST',
      headers: {
        ...this.getAuthHeaders(),
      },
      body: formData,
    });

    return this.handleResponse<T>(response);
  }

  getImageUrl(assetId: string): string {
    // URL encode the asset ID to handle special characters like forward slashes
    const encodedAssetId = encodeURIComponent(assetId);
    return `${this.baseUrl}/images/${encodedAssetId}`;
  }

  getFaceThumbnailUrl(personId: string): string {
    // Use query param endpoint which supports cookie/Authorization fallback
    return `${this.baseUrl}/face-thumbnail?personId=${encodeURIComponent(personId)}`;
  }
  
  scheduleProactiveRefresh(expiresIn?: number) {
    if (!expiresIn || expiresIn <= 0) return;
    const skew = 60; // seconds
    const jitter = Math.floor(Math.random() * 5); // seconds
    const delaySec = Math.max(30, expiresIn - skew + jitter);
    if (this.refreshTimer) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = null;
    }
    this.refreshTimer = setTimeout(async () => {
      try {
        const res = await fetch(`${this.baseUrl}/auth/refresh`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          // Send empty body; server will use HttpOnly refresh cookie
        });
        if (res.ok) {
          const data = await res.json();
          if (data?.token) {
            useAuthStore.getState().updateToken(data.token);
            const next = typeof data.expires_in === 'number' ? data.expires_in : undefined;
            this.scheduleProactiveRefresh(next);
            return;
          }
      }
      // If anything fails, let normal 401 flow handle logout
    } catch {}
  }, delaySec * 1000);
  }

  clearProactiveRefresh() {
    if (this.refreshTimer) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = null;
    }
  }
}

export const apiClient = new ApiClient();
