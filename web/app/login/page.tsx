'use client';

import { Loader2, Lock, Trophy } from 'lucide-react';
import { useState, type FormEvent } from 'react';

import type { LoginResponse } from '@/lib/types';

export default function LoginPage() {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password }),
      });
      const body: unknown = await res.json().catch(() => null);
      if (!res.ok || !body) {
        setError((body as { error?: string } | null)?.error ?? 'Login failed');
        return;
      }
      const role = (body as LoginResponse).role;
      window.location.href =
        role === 'SUPER_ADMIN' ? '/admin/fixtures' : '/agent/downline';
    } catch {
      setError('Could not reach the portal. Please try again.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center p-6">
      <div className="w-full max-w-sm">
        <div className="mb-8 flex flex-col items-center text-center">
          <span className="mb-4 flex h-14 w-14 items-center justify-center rounded-2xl bg-amber-500/15 text-amber-400">
            <Trophy className="h-7 w-7" />
          </span>
          <h1 className="text-xl font-bold tracking-wide text-slate-100">
            MOGOK MAUNG
          </h1>
          <p className="mt-1 text-sm text-slate-400">Management Portal Sign-in</p>
        </div>

        <form
          onSubmit={handleSubmit}
          className="space-y-4 rounded-xl border border-slate-800 bg-brand-panel p-6 shadow-xl"
        >
          <label className="block">
            <span className="mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-400">
              Username
            </span>
            <input
              type="text"
              autoComplete="username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              className="w-full rounded-lg border border-slate-700 bg-brand-navy px-4 py-2.5 text-sm text-slate-100 outline-none transition focus:border-brand-amber"
              placeholder="e.g. admin"
              required
            />
          </label>

          <label className="block">
            <span className="mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-400">
              Password
            </span>
            <input
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full rounded-lg border border-slate-700 bg-brand-navy px-4 py-2.5 text-sm text-slate-100 outline-none transition focus:border-brand-amber"
              placeholder="••••••••"
              required
            />
          </label>

          {error && (
            <p className="rounded-lg border border-rose-500/30 bg-rose-500/10 px-3 py-2 text-sm text-rose-300">
              {error}
            </p>
          )}

          <button
            type="submit"
            disabled={busy}
            className="flex w-full items-center justify-center gap-2 rounded-lg bg-brand-amber px-4 py-2.5 text-sm font-bold text-slate-900 transition hover:bg-amber-400 disabled:cursor-not-allowed disabled:opacity-60"
          >
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Lock className="h-4 w-4" />}
            {busy ? 'Signing in…' : 'Sign in'}
          </button>
        </form>
      </div>
    </div>
  );
}