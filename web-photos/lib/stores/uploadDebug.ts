'use client';

import { create } from 'zustand';

export type UploadDebugEntry = {
  id: string;
  ts: number;
  source: 'tus-js' | 'uppy-tus';
  method?: string;
  url?: string;
  status?: number;
  reqHeaders?: Record<string, string | undefined>;
  resHeaders?: Record<string, string | undefined>;
};

type UploadDebugState = {
  entries: UploadDebugEntry[];
  add: (e: UploadDebugEntry) => void;
  clear: () => void;
};

export const useUploadDebugStore = create<UploadDebugState>((set) => ({
  entries: [],
  add: (e) => set((s) => ({ entries: [e, ...s.entries].slice(0, 200) })),
  clear: () => set({ entries: [] }),
}));

