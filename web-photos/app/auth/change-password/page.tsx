"use client";

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { z } from 'zod';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { authApi } from '@/lib/api/auth';

const schema = z
  .object({
    new_password: z.string().min(6, 'New password must be at least 6 characters'),
    confirm: z.string(),
  })
  .refine((v) => v.new_password === v.confirm, {
    message: 'Passwords do not match',
    path: ['confirm'],
  });

type FormData = z.infer<typeof schema>;

export default function ChangePasswordPage() {
  const router = useRouter();
  const [isLoading, setIsLoading] = useState(false);
  const {
    register,
    handleSubmit,
    formState: { errors },
    setError,
  } = useForm<FormData>({ resolver: zodResolver(schema) });

  const onSubmit = async (data: FormData) => {
    setIsLoading(true);
    try {
      await authApi.changePassword({ new_password: data.new_password });
      try { localStorage.removeItem('must-change-password'); } catch {}
      // After password change, tokens are revoked. Redirect to login.
      router.push('/auth');
    } catch (e: any) {
      setError('confirm', { type: 'manual', message: e?.message || 'Failed to change password' });
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center px-4">
      <div className="w-full max-w-md space-y-6">
        <div className="text-center">
          <h1 className="text-2xl font-bold text-foreground">Update your password</h1>
          <p className="mt-2 text-sm text-muted-foreground">For security, please choose a new password.</p>
        </div>
        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-foreground">New password</label>
            <input type="password" className="mt-1 block w-full border border-border rounded-md bg-background px-3 py-2" {...register('new_password')} />
            {errors.new_password && <p className="mt-1 text-sm text-red-600">{errors.new_password.message}</p>}
          </div>
          <div>
            <label className="block text-sm font-medium text-foreground">Confirm new password</label>
            <input type="password" className="mt-1 block w-full border border-border rounded-md bg-background px-3 py-2" {...register('confirm')} />
            {errors.confirm && <p className="mt-1 text-sm text-red-600">{errors.confirm.message}</p>}
          </div>
          <button type="submit" disabled={isLoading} className="w-full py-2 px-4 rounded-md bg-primary text-primary-foreground">
            {isLoading ? 'Saving…' : 'Save password'}
          </button>
        </form>
      </div>
    </div>
  );
}
