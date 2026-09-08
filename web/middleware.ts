import { NextResponse, type NextRequest } from 'next/server';

const SUPER_ADMIN_HOME = '/admin/fixtures';
const AGENT_HOME = '/agent/downline';

export function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl;
  const session = req.cookies.get('mm_session')?.value;
  const role = req.cookies.get('mm_role')?.value;

  // Public page: bounce signed-in users straight to their dashboard.
  if (pathname === '/login') {
    if (session) {
      const home = role === 'SUPER_ADMIN' ? SUPER_ADMIN_HOME : AGENT_HOME;
      return NextResponse.redirect(new URL(home, req.url));
    }
    return NextResponse.next();
  }

  if (!session) {
    return NextResponse.redirect(new URL('/login', req.url));
  }

  if (pathname.startsWith('/admin') && role !== 'SUPER_ADMIN') {
    return NextResponse.redirect(new URL(AGENT_HOME, req.url));
  }

  if (
    pathname.startsWith('/agent') &&
    role !== 'AGENT' &&
    role !== 'SUPER_ADMIN'
  ) {
    return NextResponse.redirect(new URL('/login', req.url));
  }

  return NextResponse.next();
}

export const config = {
  matcher: ['/login', '/admin/:path*', '/agent/:path*'],
};