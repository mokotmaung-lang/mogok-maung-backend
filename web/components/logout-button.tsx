'use client';

import { LogOut } from 'lucide-react';
import { useState } from 'react';

export default function LogoutButton() {
  const [busy, setBusy] = useState(false);

  async function logout() {
    setBusy(true);
    try {
      await fetch('/api/auth/logout', { method: 'POST' });
    } finally {
      window.location.href = '/login';
    }
  }

  return (
    <button
      onClick={logout}
      disabled={busy}
      className="flex items-center gap-1.5 rounded-lg border border-slate-700 bg-slate-800 px-3 py-1.5 text-xs font-semibold text-slate-300 transition hover:bg-slate-700 hover:text-slate-100 disabled:opacity-60"
    >
      <LogOut className="h-3.5 w-3.5" />
      {busy ? 'Signing out…' : 'Sign out'}
    </button>
  );
}