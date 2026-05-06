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
                var languageMode = localStorage.getItem('i18n.localeMode') || 'system';
                var languages = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || 'en'];
                var resolvedLanguage = 'en';
                var supportedLanguages = ['en', 'zh-Hans', 'fr', 'es'];
                function languageFromTag(raw) {
                  var tag = String(raw || '').toLowerCase();
                  if (!tag) return null;
                  if (tag === 'en' || tag.indexOf('en-') === 0) return 'en';
                  if (tag === 'fr' || tag.indexOf('fr-') === 0) return 'fr';
                  if (tag === 'es' || tag.indexOf('es-') === 0) return 'es';
                  if (tag.indexOf('zh') === 0) {
                    if (tag.indexOf('hant') >= 0 || tag.indexOf('tw') >= 0 || tag.indexOf('hk') >= 0 || tag.indexOf('mo') >= 0) return 'en';
                    return 'zh-Hans';
                  }
                  return null;
                }
                if (supportedLanguages.indexOf(languageMode) >= 0) {
                  resolvedLanguage = languageMode;
                } else {
                  for (var i = 0; i < languages.length; i++) {
                    var matchedLanguage = languageFromTag(languages[i]);
                    if (matchedLanguage) {
                      resolvedLanguage = matchedLanguage;
                      break;
                    }
                  }
                }
                d.lang = resolvedLanguage;
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
