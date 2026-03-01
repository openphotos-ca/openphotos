'use client';

import React from 'react';
import { useUploadDebugStore } from '@/lib/stores/uploadDebug';

export function UploadDebugModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const entries = useUploadDebugStore((s) => s.entries);
  const clear = useUploadDebugStore((s) => s.clear);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-[75]">
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div className="absolute inset-0 grid place-items-center p-4">
        <div className="w-full max-w-4xl bg-background text-foreground border border-border rounded-lg shadow-2xl">
          <div className="px-4 py-3 border-b border-border flex items-center justify-between">
            <div className="font-medium">Upload Debug (TUS requests)</div>
            <div className="flex items-center gap-2">
              <button onClick={clear} className="px-2 py-1 text-xs rounded border border-border bg-muted hover:bg-muted/80">Clear</button>
              <button onClick={onClose} className="px-2 py-1 text-xs rounded border border-border bg-muted hover:bg-muted/80">Close</button>
            </div>
          </div>
          <div className="p-3 max-h-[70vh] overflow-auto text-xs">
            <table className="w-full border-separate" style={{ borderSpacing: 0 }}>
              <thead>
                <tr className="text-left">
                  <th className="px-2 py-1 border-b border-border">Time</th>
                  <th className="px-2 py-1 border-b border-border">Source</th>
                  <th className="px-2 py-1 border-b border-border">Method</th>
                  <th className="px-2 py-1 border-b border-border">Status</th>
                  <th className="px-2 py-1 border-b border-border">URL</th>
                </tr>
              </thead>
              <tbody>
                {entries.map((e) => (
                  <tr key={e.id} className="align-top">
                    <td className="px-2 py-1 border-b border-border whitespace-nowrap">{new Date(e.ts).toLocaleTimeString()}</td>
                    <td className="px-2 py-1 border-b border-border whitespace-nowrap">{e.source}</td>
                    <td className="px-2 py-1 border-b border-border whitespace-nowrap">{e.method || ''}</td>
                    <td className="px-2 py-1 border-b border-border whitespace-nowrap">{e.status ?? ''}</td>
                    <td className="px-2 py-1 border-b border-border">
                      <div className="truncate" title={e.url}>{e.url}</div>
                      <div className="mt-1 grid grid-cols-2 gap-2">
                        <div>
                          <div className="text-muted-foreground">Req Headers</div>
                          {Object.entries(e.reqHeaders || {}).map(([k,v]) => (
                            v ? <div key={k}><span className="text-muted-foreground">{k}:</span> {v}</div> : null
                          ))}
                        </div>
                        <div>
                          <div className="text-muted-foreground">Res Headers</div>
                          {Object.entries(e.resHeaders || {}).map(([k,v]) => (
                            v ? <div key={k}><span className="text-muted-foreground">{k}:</span> {v}</div> : null
                          ))}
                        </div>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
  );
}

