'use client';

import {
  ArrowDownLeft,
  ArrowUpRight,
  CheckCircle2,
  Loader2,
  RefreshCw,
  Send,
} from 'lucide-react';
import { useState } from 'react';

import { formatMoney } from '@/lib/format';
import type { AdminAgent, AllocateActionType } from '@/lib/types';

import { allocateAgentUnits } from '../actions';

interface AllocationPanelProps {
  agent: AdminAgent;
  onDeselect: () => void;
  onBalanceUpdated: (agentId: number, newBalance: number) => void;
}

/**
 * Super Admin unit allocation panel (Agent Unit Allocation). Calls the
 * pessimistic row-locked backend endpoint POST /api/v1/admin/units/allocate
 * through the server action; the returned balance is immediately echoed back
 * into the dashboard table.
 */
export default function AllocationPanel({
  agent,
  onDeselect,
  onBalanceUpdated,
}: AllocationPanelProps) {
  const [type, setType] = useState<AllocateActionType>('DEPOSIT');
  const [amount, setAmount] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    if (busy) return;

    const value = Number(amount);
    if (!Number.isFinite(value) || value <= 0) {
      setError('Enter a positive unit amount.');
      return;
    }

    setBusy(true);
    setError(null);
    setSuccess(null);

    const result = await allocateAgentUnits({
      agent_user_id: agent.id,
      amount: value,
      action_type: type,
      note: 'Admin managed allocation',
    });
    setBusy(false);

    if (!result.ok) {
      setError(result.error);
      return;
    }

    onBalanceUpdated(result.agent_user_id, result.agent_current_balance);
    setSuccess(
      `Request #${result.request_id} ${type === 'DEPOSIT' ? 'deposited' : 'withdrawn'} — balance updated to ${formatMoney(result.agent_current_balance)}.`,
    );
    setAmount('');
  }

  return (
    <div className="h-fit space-y-4 rounded-xl border border-slate-800 bg-brand-panel p-5">
      <h3 className="flex items-center gap-2 border-b border-slate-800 pb-3 text-base font-bold text-slate-100">
        <Send className="h-4 w-4 text-amber-400" />
        Allocate Units to Agent
      </h3>

      <div className="flex items-center justify-between rounded-lg border border-slate-700 bg-brand-navy px-3 py-2">
        <div>
          <p className="font-mono text-sm font-semibold text-slate-100">
            {agent.username}
          </p>
          <p className="text-xs text-slate-500">
            Balance:{' '}
            <span className="font-mono text-emerald-400">
              {formatMoney(agent.current_balance)}
            </span>
          </p>
        </div>
        <button
          onClick={onDeselect}
          className="rounded-lg px-2 py-1 text-xs font-semibold text-slate-400 transition hover:bg-slate-800 hover:text-slate-200"
          aria-label={`Clear selection of ${agent.username}`}
        >
          Clear
        </button>
      </div>

      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <span className="mb-1.5 block text-xs font-semibold text-slate-400">
            Action
          </span>
          <div className="grid grid-cols-2 gap-2">
            <button
              type="button"
              onClick={() => {
                setType('DEPOSIT');
                setSuccess(null);
                setError(null);
              }}
              className={`flex items-center justify-center gap-1 rounded-lg border py-2 text-xs font-semibold transition ${
                type === 'DEPOSIT'
                  ? 'border-emerald-500 bg-emerald-600/20 text-emerald-400'
                  : 'border-slate-700 bg-slate-800 text-slate-400'
              }`}
            >
              <ArrowDownLeft className="h-3.5 w-3.5" />
              Deposit
            </button>
            <button
              type="button"
              onClick={() => {
                setType('WITHDRAW');
                setSuccess(null);
                setError(null);
              }}
              className={`flex items-center justify-center gap-1 rounded-lg border py-2 text-xs font-semibold transition ${
                type === 'WITHDRAW'
                  ? 'border-rose-500 bg-rose-600/20 text-rose-400'
                  : 'border-slate-700 bg-slate-800 text-slate-400'
              }`}
            >
              <ArrowUpRight className="h-3.5 w-3.5" />
              Withdraw
            </button>
          </div>
        </div>

        <label className="block">
          <span className="mb-1.5 block text-xs font-semibold text-slate-400">
            Unit Amount
          </span>
          <input
            type="number"
            min="1"
            step="1"
            placeholder="e.g. 10000"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            className="w-full rounded-lg border border-slate-700 bg-brand-navy px-3.5 py-2.5 font-mono text-sm text-slate-100 outline-none transition focus:border-brand-amber"
          />
        </label>

        {error && (
          <p className="rounded-lg border border-rose-500/30 bg-rose-500/10 px-3 py-2 text-sm text-rose-300">
            {error}
          </p>
        )}

        {success && (
          <p className="flex items-start gap-2 rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-3 py-2 text-sm text-emerald-300">
            <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" />
            {success}
          </p>
        )}

        <button
          type="submit"
          disabled={busy}
          className="flex w-full items-center justify-center gap-2 rounded-lg bg-emerald-600 px-4 py-2.5 text-sm font-semibold text-white shadow-lg shadow-emerald-600/20 transition hover:bg-emerald-500 disabled:opacity-60"
        >
          {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
          {busy ? 'Processing…' : `${type === 'DEPOSIT' ? 'Deposit' : 'Withdraw'} ${formatMoney(Number(amount) || 0)}`}
        </button>
      </form>
    </div>
  );
}