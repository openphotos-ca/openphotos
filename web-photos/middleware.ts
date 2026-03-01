import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

export function middleware(request: NextRequest) {
  const token = request.cookies.get('auth-token')?.value;
  const isAuthPage = request.nextUrl.pathname.startsWith('/auth');
  const isApiRoute = request.nextUrl.pathname.startsWith('/api');
  const isPublicViewer = request.nextUrl.pathname.startsWith('/public');

  // Skip middleware for API routes (handled by Next.js rewrites to RUST server)
  if (isApiRoute) {
    return NextResponse.next();
  }

  // Allow unauthenticated access to public viewer
  if (isPublicViewer) {
    return NextResponse.next();
  }

  // If user is not authenticated and not on auth page, redirect to auth
  if (!token && !isAuthPage) {
    const authUrl = new URL('/auth', request.url);
    return NextResponse.redirect(authUrl);
  }

  // If user is authenticated and on auth page, redirect to home
  if (token && isAuthPage) {
    const homeUrl = new URL('/', request.url);
    return NextResponse.redirect(homeUrl);
  }

  return NextResponse.next();
}

export const config = {
  matcher: [
    /*
     * Match all request paths except for the ones starting with:
     * - _next/static (static files)
     * - _next/image (image optimization files)
     * - favicon.ico (favicon file)
     */
    '/((?!_next/static|_next/image|favicon.ico).*)',
  ],
};
