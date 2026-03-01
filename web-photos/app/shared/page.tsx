"use client";
import dynamic from 'next/dynamic';
import { Suspense } from 'react';
import { useSearchParams } from 'next/navigation';

const SharedWithMe: any = dynamic(() => import('@ee/SharedWithMePage'));
const ShareViewer: any = dynamic(() => import('@ee/ShareViewer'));

export default function Page() {
  const sp = useSearchParams();
  const sid = sp.get('id') || '';
  return (
    <Suspense fallback={<div className="p-6 text-muted-foreground">Loading…</div>}>
      {sid ? <ShareViewer shareId={sid} /> : <SharedWithMe />}
    </Suspense>
  );
}
