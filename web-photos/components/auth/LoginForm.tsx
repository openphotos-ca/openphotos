'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Eye, EyeOff, Mail, Lock, LogIn, Building2, ChevronRight } from 'lucide-react';

import { useAuthStore } from '@/lib/stores/auth';
import { authApi } from '@/lib/api/auth';
import { logger } from '@/lib/logger';

const emailSchema = z.object({
  email: z.string().email('Please enter a valid email address'),
});
const passwordSchema = z.object({ password: z.string().min(1, 'Password is required') });
type EmailFormData = z.infer<typeof emailSchema>;
type PasswordFormData = z.infer<typeof passwordSchema>;

interface LoginFormProps {
  onSwitchToRegister: () => void;
}

export function LoginForm({ onSwitchToRegister }: LoginFormProps) {
  const [showPassword, setShowPassword] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [oauthError, setOauthError] = useState<string | null>(null);
  const router = useRouter();
  const { login } = useAuthStore();
  const [step, setStep] = useState<'email' | 'org_password'>('email');
  const [email, setEmail] = useState('');
  const [orgs, setOrgs] = useState<{ organization_id: number; organization_name: string }[] | null>(null);
  const [orgId, setOrgId] = useState<number | null>(null);

  const {
    register,
    handleSubmit,
    formState: { errors },
    setError,
    setValue: setEmailFieldValue,
  } = useForm<EmailFormData>({
    resolver: zodResolver(emailSchema),
  });
  const passwordForm = useForm<PasswordFormData>({ resolver: zodResolver(passwordSchema) });
  const { setValue: setPasswordFieldValue } = passwordForm;

  useEffect(() => {
    if (typeof window === 'undefined') return;
    if (window.location.hostname.toLowerCase() !== 'demo.openphotos.ca') return;
    const demoEmail = 'demo@openphotos.ca';
    const demoPassword = 'demo';
    setEmail(demoEmail);
    setEmailFieldValue('email', demoEmail, { shouldValidate: true });
    setPasswordFieldValue('password', demoPassword, { shouldValidate: true });
  }, [setEmailFieldValue, setPasswordFieldValue]);

  const doLoginFinish = async (pwd: string) => {
    if (!orgId) {
      passwordForm.setError('password', { type: 'manual', message: 'Please select an organization' });
      return;
    }
    setIsLoading(true);
    try {
      const [{ apiClient }, response] = await Promise.all([
        import('@/lib/api/client'),
        authApi.loginFinish({ email, organization_id: orgId, password: pwd }),
      ]);
      login(response.token, response.user);
      apiClient.scheduleProactiveRefresh(response.expires_in);
      if (response.password_change_required) {
        try { localStorage.setItem('must-change-password', '1'); } catch {}
        router.push('/auth/change-password');
      } else {
        try { localStorage.removeItem('must-change-password'); } catch {}
        router.push('/');
      }
    } catch (error: any) {
      passwordForm.setError('password', { type: 'manual', message: error.message || 'Login failed' });
    } finally {
      setIsLoading(false);
    }
  };

  const onSubmitEmail = async (data: EmailFormData) => {
    setIsLoading(true);
    setEmail(data.email);
    try {
      const res = await authApi.loginStart({ email: data.email });
      const accounts = (res.accounts || []).map(a => ({ ...a, display_name: a.display_name || a.organization_name }));
      if (accounts.length === 0) {
        // Fallback to single-tenant login: proceed to password-only step
        setOrgs(null);
        setStep('org_password');
        setIsLoading(false);
        return;
      }
      setOrgs(accounts);
      const lastOrg = Number(localStorage.getItem(`last-org-for:${data.email}`) || '');
      if (accounts.length === 1) {
        setOrgId(accounts[0].organization_id);
      } else if (lastOrg && accounts.some(a => a.organization_id === lastOrg)) {
        setOrgId(lastOrg);
      } else {
        setOrgId(accounts[0].organization_id);
      }
      setStep('org_password');
    } catch (_error: any) {
      // Endpoint missing (OSS build) — fall back to single-step login
      setOrgs(null);
      setStep('org_password');
    } finally {
      setIsLoading(false);
    }
  };

  const handleGoogleLogin = async () => {
    try {
      setOauthError(null);
      const { url } = await authApi.getGoogleAuthUrl();
      window.location.href = url;
    } catch (error: any) {
      logger.error('Google login error:', error);
      setOauthError(error?.message || 'Google sign-in failed');
    }
  };

  const handleGitHubLogin = async () => {
    try {
      setOauthError(null);
      const { url } = await authApi.getGitHubAuthUrl();
      window.location.href = url;
    } catch (error: any) {
      logger.error('GitHub login error:', error);
      setOauthError(error?.message || 'GitHub sign-in failed');
    }
  };

  const enableOAuth =
    process.env.NEXT_PUBLIC_ENABLE_OAUTH === '1' ||
    process.env.NEXT_PUBLIC_ENABLE_OAUTH?.toLowerCase?.() === 'true';

  return (
    <div className="w-full max-w-md space-y-6">
      <div className="flex items-center justify-center gap-3">
        <img
          src="/app-icon.png"
          alt="OpenPhotos"
          className="w-10 h-10 rounded-xl"
          draggable={false}
        />
        <div className="text-left">
          <h1 className="text-3xl font-bold text-foreground">Welcome back</h1>
          <p className="mt-1 text-sm text-muted-foreground">Sign in to your photo library</p>
        </div>
      </div>

      {enableOAuth && oauthError ? (
        <div className="rounded-lg border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          {oauthError}
        </div>
      ) : null}

      {step === 'email' ? (
      <form onSubmit={handleSubmit(onSubmitEmail)} className="space-y-4">
        {errors.root && (
          <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-md text-sm">
            {errors.root.message}
          </div>
        )}

        <div>
          <label htmlFor="email" className="block text-sm font-medium text-foreground">
            Email address
          </label>
          <div className="mt-1 relative">
            <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
              <Mail className="h-5 w-5 text-gray-400" />
            </div>
            <input
              id="email"
              type="email"
              autoComplete="email"
              className="appearance-none block w-full pl-10 pr-3 py-2 border border-border bg-background text-foreground rounded-md placeholder:text-muted-foreground focus:outline-none focus:ring-primary focus:border-primary sm:text-sm"
              placeholder="Enter your email"
              {...register('email')}
            />
          </div>
          {errors.email && (
            <p className="mt-1 text-sm text-red-600">{errors.email.message}</p>
          )}
        </div>

        <button type="submit"
          disabled={isLoading}
          className="group relative w-full flex justify-center py-2 px-4 border border-transparent text-sm font-medium rounded-md text-primary-foreground bg-primary hover:bg-primary/90 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-primary disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isLoading ? (
            <div className="flex items-center">
              <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-white mr-2"></div>
              Checking…
            </div>
          ) : (
            <div className="flex items-center">
              <ChevronRight className="h-4 w-4 mr-2" />
              Continue
            </div>
          )}
        </button>
      </form>
      ) : (
      <form onSubmit={passwordForm.handleSubmit(async (d) => {
        if (email && orgId) localStorage.setItem(`last-org-for:${email}`, String(orgId));
        // If orgId not set (OSS), fallback to single-step login
        if (!orgId && (!orgs || orgs?.length === 0)) {
          try {
            setIsLoading(true);
            const [{ apiClient }, response] = await Promise.all([
              import('@/lib/api/client'),
              authApi.login({ email, password: d.password }),
            ]);
            login(response.token, response.user);
            apiClient.scheduleProactiveRefresh(response.expires_in);
            if (response.password_change_required) {
              try { localStorage.setItem('must-change-password', '1'); } catch {}
              router.push('/auth/change-password');
            } else {
              try { localStorage.removeItem('must-change-password'); } catch {}
              router.push('/');
            }
          } catch (err: any) {
            passwordForm.setError('password', { type: 'manual', message: err?.message || 'Login failed' });
          } finally { setIsLoading(false); }
          return;
        }
        await doLoginFinish(d.password);
      })} className="space-y-4">
        <div>
          <div className="text-sm text-muted-foreground mb-1">Signing in as</div>
          <div className="flex items-center gap-2 text-foreground">
            <Mail className="h-4 w-4" /> <span className="font-medium">{email}</span>
          </div>
        </div>
      {orgs && orgs.length > 1 && (
          <div>
            <label className="block text-sm font-medium text-foreground">Organization</label>
            <div className="mt-1 relative">
              <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                <Building2 className="h-5 w-5 text-gray-400" />
              </div>
              <select
                className="appearance-none block w-full pl-10 pr-3 py-2 border border-border bg-background text-foreground rounded-md focus:outline-none focus:ring-primary focus:border-primary sm:text-sm"
                value={orgId ?? ''}
                onChange={(e) => setOrgId(Number(e.target.value))}
              >
                {orgs.map(o => (
                  <option key={o.organization_id} value={o.organization_id}>{(o as any).display_name || o.organization_name}</option>
                ))}
              </select>
            </div>
          </div>
        )}
        <div>
          <label htmlFor="password" className="block text-sm font-medium text-foreground">Password</label>
          <div className="mt-1 relative">
            <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
              <Lock className="h-5 w-5 text-gray-400" />
            </div>
            <input id="password" type={showPassword ? 'text' : 'password'} autoComplete="current-password" className="appearance-none block w-full pl-10 pr-10 py-2 border border-border bg-background text-foreground rounded-md placeholder:text-muted-foreground focus:outline-none focus:ring-primary focus:border-primary sm:text-sm" placeholder="Enter your password" {...passwordForm.register('password')} />
            <button type="button" className="absolute inset-y-0 right-0 pr-3 flex items-center" onClick={() => setShowPassword(!showPassword)}>
              {showPassword ? <EyeOff className="h-5 w-5 text-gray-400 hover:text-gray-500" /> : <Eye className="h-5 w-5 text-gray-400 hover:text-gray-500" />}
            </button>
          </div>
          {passwordForm.formState.errors.password && (<p className="mt-1 text-sm text-red-600">{passwordForm.formState.errors.password.message}</p>)}
        </div>
        <div className="flex gap-2">
          <button type="button" onClick={() => setStep('email')} className="flex-1 py-2 px-4 border border-border rounded-md bg-card text-sm">Back</button>
          <button type="submit" disabled={isLoading} className="flex-1 py-2 px-4 border border-transparent text-sm font-medium rounded-md text-primary-foreground bg-primary hover:bg-primary/90 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-primary disabled:opacity-50 disabled:cursor-not-allowed">
            {isLoading ? 'Signing in…' : 'Sign in'}
          </button>
        </div>
      </form>
      )}

      {enableOAuth ? (
      <div className="mt-6">
        <div className="relative">
          <div className="absolute inset-0 flex items-center">
            <div className="w-full border-t border-gray-300" />
          </div>
          <div className="relative flex justify-center text-sm">
            <span className="px-2 bg-background text-muted-foreground">Or continue with</span>
          </div>
        </div>

        <div className="mt-6 grid grid-cols-2 gap-3">
          <button
            type="button"
            onClick={handleGoogleLogin}
            className="w-full inline-flex justify-center py-2 px-4 border border-border rounded-md shadow-sm bg-card text-sm font-medium text-foreground hover:bg-muted"
          >
            <svg className="w-5 h-5" viewBox="0 0 24 24">
              <path
                fill="currentColor"
                d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
              />
              <path
                fill="currentColor"
                d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
              />
              <path
                fill="currentColor"
                d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
              />
              <path
                fill="currentColor"
                d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
              />
            </svg>
            <span className="ml-2">Google</span>
          </button>

          <button
            type="button"
            onClick={handleGitHubLogin}
            className="w-full inline-flex justify-center py-2 px-4 border border-border rounded-md shadow-sm bg-card text-sm font-medium text-foreground hover:bg-muted"
          >
            <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
              <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
            </svg>
            <span className="ml-2">GitHub</span>
          </button>
        </div>
      </div>
      ) : null}

      <div className="text-center">
        <button
          type="button"
          onClick={() => {
            logger.info('Sign up button clicked');
            onSwitchToRegister();
          }}
          className="text-sm text-primary hover:text-primary/80"
        >
          Don't have an account? Sign up
        </button>
      </div>
    </div>
  );
}
