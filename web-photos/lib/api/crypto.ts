import { apiClient } from './client';

export interface CryptoEnvelopeResponse {
  envelope: any | null;
  updated_at?: string | null;
}

export const cryptoApi = {
  async getEnvelope(): Promise<CryptoEnvelopeResponse> {
    return apiClient.get<CryptoEnvelopeResponse>(`/crypto/envelope`);
  },
  async saveEnvelope(envelope: any): Promise<{ ok: boolean }> {
    return apiClient.post<{ ok: boolean }>(`/crypto/envelope`, envelope);
  },
};

