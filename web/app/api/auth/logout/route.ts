import { NextResponse } from 'next/server';

export async function POST() {
  const response = NextResponse.json({ status: 'ok' });
  response.cookies.set('mm_session', '', { httpOnly: true, path: '/', maxAge: 0 });
  response.cookies.set('mm_role', '', { httpOnly: true, path: '/', maxAge: 0 });
  return response;
}