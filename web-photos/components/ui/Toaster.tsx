'use client';

import React from 'react';
import { useToastsState } from '@/hooks/use-toast';

export function Toaster() {
  const { items, remove } = useToastsState();
  React.useEffect(() => {
    if (items.length > 0) {
      console.log('[Toaster] Rendering toasts:', items.length, items);
    }
  }, [items]);
  return (
    <div className="pointer-events-none fixed bottom-6 left-1/2 -translate-x-1/2 flex flex-col gap-2" style={{ zIndex: 2147483647 }}>
      {items.slice(0,1).map(t => (
        <div
          key={t.id}
          className={`pointer-events-auto max-w-md w-[92vw] sm:w-96 rounded-md shadow-lg ring-1 ring-black/5 px-3 py-2 text-sm animate-toast-in ${variantClass(t.variant)}`}
          role="status"
          aria-live="polite"
        >
          <div className="flex items-start gap-2 justify-center">
            <div className="flex-1 min-w-0 text-center">
              <div className="font-medium truncate">{t.title}</div>
              {t.description ? <div className="text-gray-300/90 text-xs break-words">{t.description}</div> : null}
            </div>
            <button className="text-white/80 hover:text-white text-xs" onClick={() => remove(t.id)} aria-label="Close notification">×</button>
          </div>
        </div>
      ))}
      <style jsx global>{`
        @keyframes toast-in {
          0% { opacity: 0; transform: translate(8px, -6px); }
          100% { opacity: 1; transform: translate(0, 0); }
        }
        .animate-toast-in { animation: toast-in 180ms ease-out; }
      `}</style>
    </div>
  );
}

function variantClass(v?: string) {
  switch (v) {
    case 'destructive':
      return 'bg-red-600 text-white';
    case 'success':
      return 'bg-green-600 text-white';
    default:
      return 'bg-gray-800 text-white';
  }
}

export default Toaster;
