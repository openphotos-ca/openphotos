"use client";
import dynamic from 'next/dynamic';
import { Suspense } from 'react';

const SharingPage: any = dynamic(() => import('@ee/SharingPage'));

export default function Page() {
  return (
    <Suspense fallback={<div className="p-6 text-muted-foreground">Loading…</div>}>
      <SharingPage />
    </Suspense>
  );
}

