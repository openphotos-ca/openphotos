import './globals.css';
import React from 'react';
import type { Metadata } from 'next';
// import { Inter } from 'next/font/google';
import { Providers } from './providers';

// const inter = Inter({ subsets: ['latin'] });

export const metadata: Metadata = {
  title: 'OpenPhotos',
  description: 'A modern photo management interface with AI-powered search and face recognition',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <head>
        <script
          dangerouslySetInnerHTML={{ __html: `
            (function() {
              try {
                var d = document.documentElement;
                var theme = localStorage.getItem('theme') || 'system';
                var accent = localStorage.getItem('accent') || 'blue';
                d.setAttribute('data-accent', accent);
                var prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
                var isDark = theme === 'dark' || (theme === 'system' && prefersDark);
                if (isDark) d.classList.add('dark'); else d.classList.remove('dark');

                // Live-apply changes from other tabs/iframes (e.g., Settings overlay)
                window.addEventListener('storage', function(e) {
                  if (e.key === 'theme' || e.key === 'accent') {
                    try {
                      var t = localStorage.getItem('theme') || 'system';
                      var a = localStorage.getItem('accent') || 'blue';
                      d.setAttribute('data-accent', a);
                      var prefers = window.matchMedia('(prefers-color-scheme: dark)').matches;
                      var dark = t === 'dark' || (t === 'system' && prefers);
                      if (dark) d.classList.add('dark'); else d.classList.remove('dark');
                    } catch {}
                  }
                });
              } catch (e) {}
            })();
          ` }}
        />
      </head>
      <body className="font-sans">
        <Providers>
          <React.Suspense fallback={null}>
            {children}
          </React.Suspense>
        </Providers>
      </body>
    </html>
  );
}
