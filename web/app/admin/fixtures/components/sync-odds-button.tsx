'use client';

import { Loader2, RefreshCw } from 'lucide-react';
import { useRouter } from 'next/navigation';
import { useState } from 'react';

import { syncFixtureOdds } from '../actions';

/** Header action: pulls the latest odds/leagues from the feed pipeline. */
export default function SyncOddsButton() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);

  async function sync() {
    if (busy) return;
    setBusy(true);
    try {
      await syncFixtureOdds();
      router.refresh();
    } finally {
      setBusy(false);
    }
  }

  return (
    <button
      onClick={sync}
      disabled={busy}
      className="inline-flex items-center gap-2 rounded-lg border border-slate-700 bg-slate-800 px-4 py-2 text-sm font-semibold text-slate-200 transition hover:bg-slate-700 hover:text-slate-100 disabled:opacity-60"
    >
      <RefreshCw className={busy ? 'h-4 w-4 animate-spin' : 'h-4 w-4'} />
      {busy ? 'Syncing…' : 'Sync API Odds'}
    </button>
  );
}