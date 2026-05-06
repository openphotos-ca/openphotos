'use client';

import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { usePathname } from 'next/navigation';
import { semanticMessages, sourceMessages, supportedLocales, type Locale, type LocaleMode, type MessageKey } from './generated';

export type { Locale, LocaleMode, MessageKey } from './generated';

interface I18nContextValue {
  locale: Locale;
  localeMode: LocaleMode;
  setLocaleMode: (mode: LocaleMode) => void;
  t: (key: MessageKey, params?: Record<string, string | number>) => string;
  translateSource: (source: string) => string;
  formatSource: (source: string, ...args: Array<string | number>) => string;
}

const I18nContext = createContext<I18nContextValue | null>(null);
const storageKey = 'i18n.localeMode';
const originalText = new WeakMap<Text, string>();

function translateTextNode(node: Text, locale: Locale) {
  const current = node.nodeValue ?? '';
  const source = originalText.get(node) ?? current;
  if (!originalText.has(node)) {
    if (!sourceMessages.en[current.trim()]) return;
    originalText.set(node, source);
  }
  if (!source.trim()) return;
  const leading = source.match(/^\s*/)?.[0] ?? '';
  const trailing = source.match(/\s*$/)?.[0] ?? '';
  const trimmed = source.trim();
  const translated = locale === 'en' ? trimmed : sourceMessages[locale][trimmed];
  if (translated && translated !== current.trim()) {
    node.nodeValue = `${leading}${translated}${trailing}`;
  } else if (locale === 'en') {
    node.nodeValue = source;
  }
}

function translateElementAttributes(el: Element, locale: Locale) {
  if (!(el instanceof HTMLElement)) return;
  for (const attr of ['placeholder', 'title', 'aria-label', 'alt', 'content']) {
    const current = el.getAttribute(attr);
    if (!current) continue;
    const dataKey = `i18nSource${attr.replace(/(^|-)([a-z])/g, (_, _dash, c) => c.toUpperCase())}`;
    const source = el.dataset[dataKey] || current;
    if (!el.dataset[dataKey] && !sourceMessages.en[source]) continue;
    el.dataset[dataKey] = source;
    const translated = locale === 'en' ? source : sourceMessages[locale][source];
    if (translated && translated !== current) el.setAttribute(attr, translated);
  }
}

function translateDom(root: ParentNode, locale: Locale) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
  let node: Node | null = walker.currentNode;
  while (node) {
    if (node.nodeType === Node.TEXT_NODE) {
      const parent = (node as Text).parentElement;
      if (parent && ['SCRIPT', 'STYLE', 'TEXTAREA', 'CODE', 'PRE'].includes(parent.tagName)) {
        node = walker.nextNode();
        continue;
      }
      translateTextNode(node as Text, locale);
    } else if (node.nodeType === Node.ELEMENT_NODE) {
      translateElementAttributes(node as Element, locale);
    }
    node = walker.nextNode();
  }
}

function isLocale(value: string | null): value is Locale {
  return !!value && (supportedLocales as string[]).includes(value);
}

function isLocaleMode(value: string | null): value is LocaleMode {
  return value === 'system' || isLocale(value);
}

function localeFromTag(raw: string): Locale | null {
  const tag = String(raw || '').toLowerCase();
  if (!tag) return null;
  if (tag === 'en' || tag.startsWith('en-')) return 'en';
  if (tag === 'fr' || tag.startsWith('fr-')) return 'fr';
  if (tag === 'es' || tag.startsWith('es-')) return 'es';
  if (tag.startsWith('zh')) {
    if (tag.includes('hant') || tag.includes('tw') || tag.includes('hk') || tag.includes('mo')) return 'en';
    return 'zh-Hans';
  }
  return null;
}

function resolveSystemLocale(): Locale {
  if (typeof navigator === 'undefined') return 'en';
  const languages = navigator.languages?.length ? navigator.languages : [navigator.language];
  for (const raw of languages) {
    const locale = localeFromTag(raw || '');
    if (locale) return locale;
  }
  return 'en';
}

export function intlLocaleFor(locale: Locale): string {
  switch (locale) {
    case 'zh-Hans': return 'zh-CN';
    case 'fr': return 'fr-FR';
    case 'es': return 'es-ES';
    default: return 'en-US';
  }
}

function interpolate(message: string, params?: Record<string, string | number>): string {
  if (!params) return message;
  return message.replace(/\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, key) =>
    Object.prototype.hasOwnProperty.call(params, key) ? String(params[key]) : `{${key}}`,
  );
}

function formatPrintf(message: string, args: Array<string | number>): string {
  let index = 0;
  return message.replace(/%[@sdif]/g, (token) => {
    if (index >= args.length) return token;
    return String(args[index++]);
  });
}

export function I18nProvider({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const [localeMode, setLocaleModeState] = useState<LocaleMode>('system');
  const [systemLocale, setSystemLocale] = useState<Locale>('en');

  useEffect(() => {
    try {
      const stored = localStorage.getItem(storageKey);
      if (isLocaleMode(stored)) setLocaleModeState(stored);
    } catch {}
    setSystemLocale(resolveSystemLocale());
  }, []);

  useEffect(() => {
    if (typeof window === 'undefined') return;
    const handler = () => setSystemLocale(resolveSystemLocale());
    window.addEventListener('languagechange', handler);
    return () => window.removeEventListener('languagechange', handler);
  }, []);

  const locale = localeMode === 'system' ? systemLocale : localeMode;

  const setLocaleMode = useCallback((mode: LocaleMode) => {
    setLocaleModeState(mode);
    try { localStorage.setItem(storageKey, mode); } catch {}
  }, []);

  const translateSource = useCallback((source: string) => {
    return locale === 'en' ? source : sourceMessages[locale][source] || source;
  }, [locale]);

  const formatSource = useCallback((source: string, ...args: Array<string | number>) => {
    return formatPrintf(translateSource(source), args);
  }, [translateSource]);

  const t = useCallback((key: MessageKey, params?: Record<string, string | number>) => {
    const message = semanticMessages[locale][key] || semanticMessages.en[key] || key;
    return interpolate(message, params);
  }, [locale]);

  useEffect(() => {
    try { document.documentElement.lang = locale; } catch {}
    const translate = () => {
      try { translateDom(document.body, locale); } catch {}
    };
    const raf = window.requestAnimationFrame(translate);
    const timers = [
      window.setTimeout(translate, 100),
      window.setTimeout(translate, 500),
      window.setTimeout(translate, 1500),
    ];
    return () => {
      window.cancelAnimationFrame(raf);
      timers.forEach(timer => window.clearTimeout(timer));
    };
  }, [locale, pathname]);

  useEffect(() => {
    let timer: number | null = null;
    const translate = () => {
      try { translateDom(document.body, locale); } catch {}
    };
    const scheduleTranslate = () => {
      if (timer != null) window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        timer = null;
        translate();
        window.setTimeout(translate, 50);
      }, 0);
    };
    const events = ['click', 'pointerup', 'keydown', 'focusin'];
    events.forEach(event => document.addEventListener(event, scheduleTranslate, true));
    return () => {
      if (timer != null) window.clearTimeout(timer);
      events.forEach(event => document.removeEventListener(event, scheduleTranslate, true));
    };
  }, [locale]);

  useEffect(() => {
    const originalAlert = window.alert;
    const originalConfirm = window.confirm;
    window.alert = (message?: any) => originalAlert(translateSource(String(message ?? '')));
    window.confirm = (message?: string) => originalConfirm(translateSource(String(message ?? '')));
    return () => {
      window.alert = originalAlert;
      window.confirm = originalConfirm;
    };
  }, [translateSource]);

  const value = useMemo<I18nContextValue>(() => ({
    locale,
    localeMode,
    setLocaleMode,
    t,
    translateSource,
    formatSource,
  }), [locale, localeMode, setLocaleMode, t, translateSource, formatSource]);

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n() {
  const context = useContext(I18nContext);
  if (!context) throw new Error('useI18n must be used inside I18nProvider');
  return context;
}
