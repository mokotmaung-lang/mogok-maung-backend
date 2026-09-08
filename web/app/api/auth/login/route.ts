import { NextRequest, NextResponse } from 'next/server';

import type { LoginResponse } from '@/lib/types';

const BACKEND_URL = process.env.BACKEND_URL ?? 'http://localhost:8080';

interface LoginBody {
  username: string;
  password: string;
}

/**
 * Proxy for POST /api/v1/auth/login. Exchanges credentials against the Go
 * backend and stores the returned JWT in an httpOnly cookie so the browser
 * never touches the raw token.
 */
export async function POST(req: NextRequest) {
  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return NextResponse.json({ error: 'invalid JSON body' }, { status: 400 });
  }

  const { username, password } = payload as Partial<LoginBody>;
  if (typeof username !== 'string' || typeof password !== 'string') {
    return NextResponse.json(
      { error: 'username and password are required' },
      { status: 400 },
    );
  }

  const res = await fetch(`${BACKEND_URL}/api/v1/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password }) as string,
    cache: 'no-store',
  });

  const body: unknown = await res.json().catch(() => null);
  if (!res.ok) {
    return NextResponse.json(
      (body as { error?: string } | null) ?? { error: 'login failed' },
      { status: res.status },
    );
  }

  const login = body as Partial<LoginResponse>;
  if (typeof login.access_token !== 'string' || typeof login.role !== 'string') {
    return NextResponse.json(
      { error: 'malformed response from backend' },
      { status: 502 },
    );
  }

  const maxAge = Number(login.expires_in ?? 86400);
  const secure = process.env.NODE_ENV === 'production';
  const response = NextResponse.json(login);
  response.cookies.set('mm_session', login.access_token, {
    httpOnly: true,
    secure,
    sameSite: 'lax',
    path: '/',
    maxAge,
  });
  response.cookies.set('mm_role', login.role, {
    httpOnly: true,
    secure,
    sameSite: 'lax',
    path: '/',
    maxAge,
  });
  return response;
}