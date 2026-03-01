'use client';

import React from 'react';

type SafeBoundaryProps = { name?: string; fallback?: React.ReactNode; children?: React.ReactNode };

export default class SafeBoundary extends React.Component<SafeBoundaryProps, { hasError: boolean; message?: string }>
{
  constructor(props: { name?: string; fallback?: React.ReactNode }) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError(err: unknown) {
    return { hasError: true, message: err instanceof Error ? err.message : String(err) };
  }

  componentDidCatch(error: unknown, info: React.ErrorInfo) {
    try {
      // Helpful console output in production where errors are minified
      // eslint-disable-next-line no-console
      console.error('[SafeBoundary]', this.props.name || 'Unnamed', { error, info });
    } catch {}
  }

  render() {
    if (this.state.hasError) {
      return this.props.fallback ?? null;
    }
    return this.props.children as React.ReactElement;
  }
}
