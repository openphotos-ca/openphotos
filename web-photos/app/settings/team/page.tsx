'use client';

import Link from 'next/link';
import nextDynamic from 'next/dynamic';
import { useAuthStore } from '@/lib/stores/auth';
import { isDemoEmail } from '@/lib/demo';

const EEPage = nextDynamic(() => import('@ee/TeamPage'));

export default function TeamSettingsPage() {
  const user = useAuthStore((s) => s.user);
  const isDemoUser = isDemoEmail(user?.email);

  if (isDemoUser) {
    return (
      <div className="container mx-auto px-4 py-8">
        <div className="max-w-2xl mx-auto rounded-md border border-amber-500/40 bg-amber-500/10 px-4 py-4 text-sm text-amber-200">
          <p className="font-semibold">Demo account: users and groups are read-only.</p>
          <p className="mt-1">Admin configuration is disabled for the online demo account.</p>
          <Link className="mt-4 inline-block underline" href="/">
            Back to home
          </Link>
        </div>
      </div>
    );
  }

  return <EEPage />;
}
