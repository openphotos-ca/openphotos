'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';

import { LoginForm } from '@/components/auth/LoginForm';
import { RegisterForm } from '@/components/auth/RegisterForm';
import { useAuthStore } from '@/lib/stores/auth';
import { logger } from '@/lib/logger';

export default function AuthPage() {
  const [isLogin, setIsLogin] = useState(true);
  const router = useRouter();
  const { isAuthenticated } = useAuthStore();

  // Debug state changes
  logger.debug('AuthPage render - isLogin:', isLogin);

  useEffect(() => {
    if (isAuthenticated) {
      try {
        const must = typeof window !== 'undefined' && localStorage.getItem('must-change-password') === '1';
        router.replace(must ? '/auth/change-password' : '/');
      } catch {
        router.replace('/');
      }
    }
  }, [isAuthenticated, router]);

  if (isAuthenticated) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gradient-to-br from-blue-50 via-white to-purple-50 dark:from-gray-900 dark:via-gray-950 dark:to-black flex">
      {/* Left side - Branding */}
      <div className="hidden lg:flex lg:flex-1 lg:flex-col lg:justify-center lg:px-8">
        <div className="mx-auto w-full max-w-sm">
          <div className="text-center">
            <h1 className="text-4xl font-bold text-foreground mb-4">OpenPhotos</h1>
            <p className="text-xl text-muted-foreground mb-8">
              Organize, search, and discover your photos with AI-powered intelligence
            </p>
            
            <div className="space-y-4 text-left">
              <div className="flex items-center space-x-3">
                <div className="flex-shrink-0 w-8 h-8 bg-green-100 rounded-full flex items-center justify-center">
                  <svg className="w-5 h-5 text-green-600" fill="currentColor" viewBox="0 0 20 20">
                    <path fillRule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clipRule="evenodd" />
                  </svg>
                </div>
                <span className="text-foreground/80">AI-powered semantic search</span>
              </div>
              
              <div className="flex items-center space-x-3">
                <div className="flex-shrink-0 w-8 h-8 bg-green-100 rounded-full flex items-center justify-center">
                  <svg className="w-5 h-5 text-green-600" fill="currentColor" viewBox="0 0 20 20">
                    <path fillRule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clipRule="evenodd" />
                  </svg>
                </div>
                <span className="text-foreground/80">Automatic face recognition</span>
              </div>
              
              <div className="flex items-center space-x-3">
                <div className="flex-shrink-0 w-8 h-8 bg-green-100 rounded-full flex items-center justify-center">
                  <svg className="w-5 h-5 text-green-600" fill="currentColor" viewBox="0 0 20 20">
                    <path fillRule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clipRule="evenodd" />
                  </svg>
                </div>
                <span className="text-foreground/80">Smart albums and collections</span>
              </div>
              
              <div className="flex items-center space-x-3">
                <div className="flex-shrink-0 w-8 h-8 bg-green-100 rounded-full flex items-center justify-center">
                  <svg className="w-5 h-5 text-green-600" fill="currentColor" viewBox="0 0 20 20">
                    <path fillRule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clipRule="evenodd" />
                  </svg>
                </div>
                <span className="text-foreground/80">Privacy-focused and self-hosted</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Right side - Auth forms */}
      <div className="flex-1 flex flex-col justify-center py-12 px-4 sm:px-6 lg:px-8">
        <div className="mx-auto w-full max-w-md">
          <div className="lg:hidden text-center mb-8">
            <h1 className="text-2xl font-bold text-foreground">OpenPhotos</h1>
          </div>

          {isLogin ? (
            <LoginForm onSwitchToRegister={() => {
              logger.info('Switching to register form');
              setIsLogin(false);
            }} />
          ) : (
            <RegisterForm onSwitchToLogin={() => {
              logger.info('Switching to login form');
              setIsLogin(true);
            }} />
          )}
        </div>
      </div>
    </div>
  );
}
