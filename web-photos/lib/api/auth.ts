import { apiClient } from './client';
import { User } from '@/lib/stores/auth';

export interface LoginRequest {
  email: string;
  password: string;
}

export interface RegisterRequest {
  name: string;
  email: string;
  password: string;
  organization_id?: number;
}

export interface AuthResponse {
  token: string;
  user: User;
  refresh_token?: string;
  expires_in?: number; // seconds
  password_change_required?: boolean;
}

export interface LoginStartRequest { email: string }
export interface LoginStartResponseItem { organization_id: number; organization_name: string; display_name?: string }
export interface LoginStartResponse { accounts: LoginStartResponseItem[] }

export interface LoginFinishRequest { email: string; organization_id: number; password: string }

export const authApi = {
  async login(data: LoginRequest): Promise<AuthResponse> {
    return apiClient.post<AuthResponse>('/auth/login', data);
  },

  async loginStart(data: LoginStartRequest): Promise<LoginStartResponse> {
    return apiClient.post<LoginStartResponse>('/auth/login/start', data);
  },

  async loginFinish(data: LoginFinishRequest): Promise<AuthResponse> {
    return apiClient.post<AuthResponse>('/auth/login/finish', data);
  },

  async register(data: RegisterRequest): Promise<AuthResponse> {
    return apiClient.post<AuthResponse>('/auth/register', data);
  },

  async refresh(body?: { refresh_token?: string }): Promise<AuthResponse> {
    // If body omitted, server will read refresh-token cookie
    return apiClient.post<AuthResponse>('/auth/refresh', body);
  },

  async logout(): Promise<void> {
    return apiClient.post<void>('/auth/logout');
  },

  async changePassword(body: { new_password: string; current_password?: string }): Promise<void> {
    return apiClient.post<void>('/auth/password/change', body);
  },

  async me(): Promise<User> {
    return apiClient.get<User>('/auth/me');
  },

  async getGoogleAuthUrl(): Promise<{ url: string }> {
    return apiClient.get<{ url: string }>('/auth/oauth/google');
  },

  async getGitHubAuthUrl(): Promise<{ url: string }> {
    return apiClient.get<{ url: string }>('/auth/oauth/github');
  },
};
