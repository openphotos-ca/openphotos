'use client';

import React, { useEffect, useState, useRef } from 'react';
import { X } from 'lucide-react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';
import { PinDialog } from '@/components/security/PinDialog';
import { useQueryState } from '@/hooks/useQueryState';
import { useFacesThumbVersion } from '@/hooks/useFacesThumbVersion';
import { useRouter } from 'next/navigation';

export function FiltersDrawer({ open, onClose, inline = false, inlineWidth }: { open: boolean; onClose: () => void; inline?: boolean; inlineWidth?: number }) {
  const { state, setFaces, setTypes, setLocation, setDateRange, setLocked, setRating } = useQueryState();

  const router = useRouter();

  const { data: faces } = useQuery({
    queryKey: ['faces'],
    queryFn: () => photosApi.getFaces(),
    staleTime: 60_000,
    enabled: open,
  });

  const { data: meta } = useQuery({
    queryKey: ['filters-metadata'],
    queryFn: () => photosApi.getFilterMetadata(),
    staleTime: 5 * 60_000,
    enabled: open,
  });

  const activeFaces = new Set(state.faces || []);
  const [facesExpanded, setFacesExpanded] = useState<boolean>(false);

  // Persist expanded state locally
  useEffect(() => {
    try {
      const v = localStorage.getItem('filters-faces-expanded');
      if (v !== null) setFacesExpanded(v === '1');
    } catch {}
  }, []);
  useEffect(() => {
    try { localStorage.setItem('filters-faces-expanded', facesExpanded ? '1' : '0'); } catch {}
  }, [facesExpanded]);
  const types = new Set(state.type || []);
  const qc = useQueryClient();
  const facesThumbV = useFacesThumbVersion();
  // PIN dialog state
  const [pinOpen, setPinOpen] = useState(false);
  const [pinMode, setPinMode] = useState<'verify' | 'set'>("verify");
  const pinResolverRef = useRef<((ok: boolean) => void) | null>(null);

  const ensurePinVerified = async (): Promise<boolean> => {
    try {
      const st: any = await photosApi.getPinStatus();
      if (!st?.is_set) setPinMode('set'); else if (!st?.verified) setPinMode('verify'); else return true;
      setPinOpen(true);
      return await new Promise<boolean>((resolve) => { pinResolverRef.current = resolve; });
    } catch {
      return false;
    }
  };

  // Editing is handled in Manage Faces; labels here toggle selection like thumbnails.

  const toggleFace = (id: string) => {
    const next = new Set(activeFaces);
    if (next.has(id)) next.delete(id); else next.add(id);
    setFaces(Array.from(next));
  };
  const toggleType = (t: 'screenshot' | 'live') => {
    const next = new Set(types);
    if (next.has(t)) next.delete(t); else next.add(t);
    setTypes(Array.from(next) as any);
  };

  const onToggleLockedOnly = async (on: boolean) => {
    if (!on) {
      setLocked(false);
      try { await qc.invalidateQueries({ queryKey: ['photos'] }); await qc.refetchQueries({ queryKey: ['photos'] }); } catch {}
      try { await qc.invalidateQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' }); await qc.refetchQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' }); } catch {}
      return;
    }
    const ok = await ensurePinVerified();
    if (ok) {
      setLocked(true);
      try { await qc.invalidateQueries({ queryKey: ['photos'] }); await qc.refetchQueries({ queryKey: ['photos'] }); } catch {}
      try { await qc.invalidateQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' }); await qc.refetchQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' }); } catch {}
    }
  };

  const onDateChange = (key: 'start'|'end', value: string) => {
    const start = key === 'start' ? value : state.start;
    const end = key === 'end' ? value : state.end;
    setDateRange({ start, end });
  };

  const asideRef = useRef<HTMLDivElement | null>(null);
  if (!open) return null;

  // Inline split-pane variant (desktop): render just the panel content without overlay
  if (inline) {
    return (
      <div className="relative h-full" style={{ width: inlineWidth ?? 320 }}>
      <aside ref={asideRef} className="absolute inset-0 bg-background overflow-y-auto border-r border-border">
        <div className="p-4 border-b flex items-center justify-between">
          <h3 className="text-lg font-medium">Filters</h3>
          <button className="w-7 h-7 rounded-full grid place-items-center bg-card border border-border hover:bg-muted" onClick={onClose} aria-label="Close filters">
            <X className="w-4 h-4" />
          </button>
        </div>
        {/* Duplicate of content below; returned early for inline mode */}
        <div className="p-4 space-y-6">
          {/* Faces */}
          <section>
            <div className="flex items-center justify-between mb-2">
              <button
                type="button"
                className="font-semibold flex items-center gap-2"
                onClick={() => setFacesExpanded(!facesExpanded)}
                aria-expanded={facesExpanded}
              >
                <span>Faces</span>
                <span className="text-xs text-muted-foreground">({faces?.length ?? 0})</span>
                <span className={`transition-transform ${facesExpanded ? 'rotate-90' : ''}`}>›</span>
              </button>
              <div className="flex items-center gap-2">
                <button
                  className="px-2 py-0.5 rounded-full border bg-card border-border text-foreground hover:bg-muted text-xs"
                  onClick={() => { router.push('/faces/manage'); onClose(); }}
                  title="Manage faces"
                >Manage</button>
                {!facesExpanded && (state.faces?.length ?? 0) > 0 && (
                  <div className="flex items-center gap-1">
                    {state.faces!.slice(0,3).map(id => (
                      <img key={id} src={`${photosApi.getFaceThumbnailUrl(id)}&t=${facesThumbV}`} alt={id} title={id} className="w-6 h-6 rounded-full object-cover border border-gray-300" />
                    ))}
                  {state.faces!.length > 3 && (
                    <span className="text-xs text-muted-foreground">+{state.faces!.length - 3}</span>
                  )}
                  <button className="text-xs text-muted-foreground hover:underline ml-1" onClick={() => setFaces([])}>Clear</button>
                </div>
              )}
              </div>
            </div>

            {facesExpanded && (
              <div className="grid grid-cols-3 gap-3 max-h-56 overflow-y-auto pr-1">
              {(faces || []).map((f) => {
                const id = (f as any).person_id || (f as any).id || '';
                const labelBase = (f as any).name || (f as any).display_name || id;
                const count = (f as any).face_count || (f as any).photo_count;
                const label = count ? `${labelBase} (${count})` : labelBase;
                const selected = activeFaces.has(id);
                const thumbUrl = `${photosApi.getFaceThumbnailUrl(id)}&t=${facesThumbV}`;
                return (
                  <div key={id} className={`flex flex-col items-center text-xs rounded-md overflow-hidden border ${selected ? 'border-purple-400 ring-2 ring-purple-200' : 'border-gray-200'}`}
                    title={label}>
                    <button onClick={() => toggleFace(id)} className="w-full">
                      <img src={thumbUrl} alt={label} className="w-full aspect-square object-cover bg-gray-100" loading="lazy" />
                    </button>
                    <button onClick={() => toggleFace(id)} className={`w-full truncate px-1 py-1 text-left ${selected ? 'text-primary' : 'text-foreground'}`}>{label}</button>
                  </div>
                );
              })}
              </div>
            )}
          </section>
          {/* Time range */}
          <section>
            <h4 className="font-semibold mb-2">Time Range</h4>
            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="block text-xs text-muted-foreground mb-1">Start</label>
                <input type="date" value={(state.start || '').slice(0,10)} onChange={e => onDateChange('start', e.target.value ? new Date(e.target.value).toISOString() : '')} className="w-full border border-border bg-background text-foreground rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent" />
              </div>
              <div>
                <label className="block text-xs text-muted-foreground mb-1">End</label>
                <input type="date" value={(state.end || '').slice(0,10)} onChange={e => onDateChange('end', e.target.value ? new Date(e.target.value).toISOString() : '')} className="w-full border border-border bg-background text-foreground rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent" />
              </div>
            </div>
          </section>
          {/* Type flags */}
          <section>
            <h4 className="font-semibold mb-2">Type</h4>
            <div className="flex gap-2">
              <button onClick={() => toggleType('screenshot')} className={`px-2 py-1 rounded-full border ${types.has('screenshot') ? 'bg-primary/10 border-primary/30 text-primary hover:bg-primary/20' : 'bg-card border-border text-foreground hover:bg-muted'}`}>Screenshots</button>
              <button onClick={() => toggleType('live')} className={`px-2 py-1 rounded-full border ${types.has('live') ? 'bg-primary/10 border-primary/30 text-primary hover:bg-primary/20' : 'bg-card border-border text-foreground hover:bg-muted'}`}>Live Photos</button>
            </div>
          </section>
          {/* Rating */}
          <section>
            <h4 className="font-semibold mb-2">Rating</h4>
            <div className="flex items-center gap-2">
              {[1,2,3,4,5].map(n => (
                <button key={n} className="text-red-500 text-xl" aria-label={`Minimum ${n} stars`} onClick={()=> setRating(n)}>
                  <span>{(parseInt(state.rating||'0',10)||0) >= n ? '★' : '☆'}</span>
                </button>
              ))}
              <button className="ml-2 text-xs text-muted-foreground underline" onClick={()=> setRating(undefined)}>Clear</button>
            </div>
          </section>
          {/* Security */}
          <section>
            <h4 className="font-semibold mb-2">Security</h4>
            <label className="inline-flex items-center gap-2 text-sm">
              <input type="checkbox" className="accent-primary" checked={state.locked === '1'} onChange={(e) => onToggleLockedOnly(e.target.checked)} />
              <span>Locked only</span>
            </label>
          </section>
          {/* Location */}
          <section>
            <h4 className="font-semibold mb-2">Location</h4>
            <div className="space-y-2">
              <div>
                <label className="block text-xs text-muted-foreground mb-1">Country</label>
                <select value={state.country || ''} onChange={e => setLocation({ country: e.target.value || undefined, region: state.region, city: state.city })} className="w-full border border-border bg-background text-foreground rounded px-2 py-1">
                  <option value="">Any</option>
                  {(meta?.countries || []).map(c => <option key={c} value={c}>{c}</option>)}
                </select>
              </div>
              <div>
                <label className="block text-xs text-muted-foreground mb-1">Province/State</label>
                <input value={state.region || ''} onChange={e => setLocation({ country: state.country, region: e.target.value || undefined, city: state.city })} className="w-full border border-border bg-background text-foreground rounded px-2 py-1" placeholder="Any" />
              </div>
              <div>
                <label className="block text-xs text-muted-foreground mb-1">City</label>
                <select value={state.city || ''} onChange={e => setLocation({ country: state.country, region: state.region, city: e.target.value || undefined })} className="w-full border border-border bg-background text-foreground rounded px-2 py-1">
                  <option value="">Any</option>
                  {(meta?.cities || []).map(c => <option key={c} value={c}>{c}</option>)}
                </select>
              </div>
            </div>
          </section>
          <div className="pt-4 border-t flex justify-between">
            <button className="text-sm text-muted-foreground underline" onClick={() => { setFaces([]); setTypes([]); setDateRange({ start: undefined, end: undefined }); setLocation({ country: undefined, region: undefined, city: undefined }); setRating(undefined); }}>
              Clear all
            </button>
            <button className="px-3 py-1.5 bg-primary text-primary-foreground rounded" onClick={onClose}>Done</button>
          </div>
        </div>
      </aside>
      <PinDialog
        open={pinOpen}
        mode={pinMode}
        onClose={() => { setPinOpen(false); pinResolverRef.current?.(false); pinResolverRef.current = null; }}
        onVerified={() => { setPinOpen(false); pinResolverRef.current?.(true); pinResolverRef.current = null; }}
      />
      </div>
    );
  }

  // Overlay drawer (mobile)
  return (
    <div
      className="fixed inset-0 z-50"
      onMouseDown={(e) => {
        if (asideRef.current && !asideRef.current.contains(e.target as Node)) {
          onClose();
        }
      }}
    >
      <aside ref={asideRef} className="absolute right-0 top-0 h-full w-80 bg-background shadow-xl overflow-y-auto border-l-4 border-border" onMouseDown={(e) => e.stopPropagation()}>
        <div className="p-4 border-b flex items-center justify-between">
          <h3 className="text-lg font-medium">Filters</h3>
          <button className="w-7 h-7 rounded-full grid place-items-center bg-card border border-border hover:bg-muted" onClick={onClose} aria-label="Close filters">
            <X className="w-4 h-4" />
          </button>
        </div>
        <div className="p-4 space-y-6">
          {/* Faces */}
          <section>
            <div className="flex items-center justify-between mb-2">
              <button
                type="button"
                className="font-semibold flex items-center gap-2"
                onClick={() => setFacesExpanded(!facesExpanded)}
                aria-expanded={facesExpanded}
              >
                <span>Faces</span>
                <span className="text-xs text-muted-foreground">({faces?.length ?? 0})</span>
                <span className={`transition-transform ${facesExpanded ? 'rotate-90' : ''}`}>›</span>
              </button>
              <div className="flex items-center gap-2">
                <button
                  className="px-2 py-0.5 rounded-full border bg-card border-border text-foreground hover:bg-muted text-xs"
                  onClick={() => { router.push('/faces/manage'); onClose(); }}
                  title="Manage faces"
                >Manage</button>
              {!facesExpanded && (state.faces?.length ?? 0) > 0 && (
                <div className="flex items-center gap-1">
                  {state.faces!.slice(0,3).map(id => (
                    <img key={id} src={photosApi.getFaceThumbnailUrl(id)} alt={id} title={id} className="w-6 h-6 rounded-full object-cover border border-gray-300" />
                  ))}
                  {state.faces!.length > 3 && (
                    <span className="text-xs text-muted-foreground">+{state.faces!.length - 3}</span>
                  )}
                  <button className="text-xs text-muted-foreground hover:underline ml-1" onClick={() => setFaces([])}>Clear</button>
                </div>
              )}
              </div>
            </div>

            {facesExpanded && (
              <div className="grid grid-cols-3 gap-3 max-h-56 overflow-y-auto pr-1">
              {(faces || []).map((f) => {
                const id = (f as any).person_id || (f as any).id || '';
                const labelBase = (f as any).name || (f as any).display_name || id;
                const count = (f as any).face_count || (f as any).photo_count;
                const label = count ? `${labelBase} (${count})` : labelBase;
                const selected = activeFaces.has(id);
                const thumbUrl = photosApi.getFaceThumbnailUrl(id);
                return (
                  <div key={id} className={`flex flex-col items-center text-xs rounded-md overflow-hidden border ${selected ? 'border-purple-400 ring-2 ring-purple-200' : 'border-gray-200'}`}
                    title={label}>
                    <button onClick={() => toggleFace(id)} className="w-full">
                      <img src={thumbUrl} alt={label} className="w-full aspect-square object-cover bg-gray-100" loading="lazy" />
                    </button>
                    <button onClick={() => toggleFace(id)} className={`w-full truncate px-1 py-1 text-left ${selected ? 'text-primary' : 'text-foreground'}`}>{label}</button>
                  </div>
                );
              })}
              </div>
            )}
          </section>

          {/* Time range */}
          <section>
            <h4 className="font-semibold mb-2">Time Range</h4>
            <div className="grid grid-cols-2 gap-2">
              <div>
                <label className="block text-xs text-muted-foreground mb-1">Start</label>
                <input type="date" value={(state.start || '').slice(0,10)} onChange={e => onDateChange('start', e.target.value ? new Date(e.target.value).toISOString() : '')} className="w-full border border-border bg-background text-foreground rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent" />
              </div>
              <div>
                <label className="block text-xs text-muted-foreground mb-1">End</label>
                <input type="date" value={(state.end || '').slice(0,10)} onChange={e => onDateChange('end', e.target.value ? new Date(e.target.value).toISOString() : '')} className="w-full border border-border bg-background text-foreground rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent" />
              </div>
            </div>
          </section>

          {/* Type flags */}
          <section>
            <h4 className="font-semibold mb-2">Type</h4>
            <div className="flex gap-2">
              <button onClick={() => toggleType('screenshot')} className={`px-2 py-1 rounded-full border ${types.has('screenshot') ? 'bg-primary/10 border-primary/30 text-primary hover:bg-primary/20' : 'bg-card border-border text-foreground hover:bg-muted'}`}>Screenshots</button>
              <button onClick={() => toggleType('live')} className={`px-2 py-1 rounded-full border ${types.has('live') ? 'bg-primary/10 border-primary/30 text-primary hover:bg-primary/20' : 'bg-card border-border text-foreground hover:bg-muted'}`}>Live Photos</button>
            </div>
          </section>

          {/* Location */}
          <section>
            <h4 className="font-semibold mb-2">Location</h4>
            <div className="space-y-2">
              <div>
                <label className="block text-xs text-muted-foreground mb-1">Country</label>
                <select value={state.country || ''} onChange={e => setLocation({ country: e.target.value || undefined, region: state.region, city: state.city })} className="w-full border border-border bg-background text-foreground rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent">
                  <option value="">Any</option>
                  {(meta?.countries || []).map(c => <option key={c} value={c}>{c}</option>)}
                </select>
              </div>
              <div>
                <label className="block text-xs text-muted-foreground mb-1">Province/State</label>
                <input value={state.region || ''} onChange={e => setLocation({ country: state.country, region: e.target.value || undefined, city: state.city })} className="w-full border border-border bg-background text-foreground rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent" placeholder="Any" />
              </div>
              <div>
                <label className="block text-xs text-muted-foreground mb-1">City</label>
                <select value={state.city || ''} onChange={e => setLocation({ country: state.country, region: state.region, city: e.target.value || undefined })} className="w-full border border-border bg-background text-foreground rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent">
                  <option value="">Any</option>
                  {(meta?.cities || []).map(c => <option key={c} value={c}>{c}</option>)}
                </select>
              </div>
            </div>
          </section>

          <div className="pt-4 border-t flex justify-between">
            <button
              className="text-sm text-muted-foreground underline"
              onClick={() => { setFaces([]); setTypes([]); setDateRange({ start: undefined, end: undefined }); setLocation({ country: undefined, region: undefined, city: undefined }); }}
            >
              Clear all
            </button>
            <button className="px-3 py-1.5 bg-primary text-primary-foreground rounded" onClick={onClose}>Done</button>
          </div>
        </div>
      </aside>
      {/* PIN dialog for verify/set */}
      <PinDialog
        open={pinOpen}
        mode={pinMode}
        onClose={() => { setPinOpen(false); pinResolverRef.current?.(false); pinResolverRef.current = null; }}
        onVerified={() => { setPinOpen(false); pinResolverRef.current?.(true); pinResolverRef.current = null; }}
      />
    </div>
  );
}
