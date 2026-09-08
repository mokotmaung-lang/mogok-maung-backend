'use client';

import { Loader2, Search, Send, TrendingUp, UserPlus, Users, Wallet } from 'lucide-react';
import { useRouter } from 'next/navigation';
import { useMemo, useState } from 'react';

import { formatDate, formatKyat } from '@/lib/format';
import type { Downline } from '@/lib/types';

import { toggleUserStatus } from '../actions';
import CreateUserModal from './create-user-modal';
import UnitRequestPanel from './unit-request-panel';

/** Agent commission margin (config-driven; super-admin negotiable). */
const AGENT_MARGIN_RATE = 5.0;

interface DownlineTableProps {
  initialDownlines: Downline[];
}

export default function DownlineTable({ initialDownlines }: DownlineTableProps) {
  const router = useRouter();
  const [downlines, setDownlines] = useState<Downline[]>(initialDownlines);
  const [search, setSearch] = useState('');
  const [selected, setSelected] = useState<Downline | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [togglingId, setTogglingId] = useState<number | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (q === '') return downlines;
    return downlines.filter(
      (d) =>
        d.username.toLowerCase().includes(q) || d.name.toLowerCase().includes(q),
    );
  }, [downlines, search]);

  const totalUnits = useMemo(
    () => downlines.reduce((sum, d) => sum + d.current_balance, 0),
    [downlines],
  );

  async function handleToggle(user: Downline) {
    setTogglingId(user.id);
    setActionError(null);
    const result = await toggleUserStatus(user.id, !user.is_active);
    setTogglingId(null);
    if (!result.ok) {
      setActionError(result.error);
      return;
    }
    setDownlines((prev) =>
      prev.map((d) =>
        d.id === result.user_id ? { ...d, is_active: result.is_active } : d,
      ),
    );
  }

  return (
    <div className="space-y-6">
      {/* Metrics Bar */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div className="flex items-center justify-between rounded-xl border border-slate-800 bg-brand-panel p-5">
          <div>
            <p className="text-xs font-medium uppercase text-slate-400">
              Downline Users
            </p>
            <h3 className="mt-1 text-2xl font-bold text-slate-100">
              {downlines.length} Users
            </h3>
          </div>
          <div className="rounded-lg border border-blue-500/20 bg-blue-500/10 p-3 text-blue-400">
            <Users className="h-6 w-6" />
          </div>
        </div>

        <div className="flex items-center justify-between rounded-xl border border-slate-800 bg-brand-panel p-5">
          <div>
            <p className="text-xs font-medium uppercase text-slate-400">
              Total User Units
            </p>
            <h3 className="mt-1 text-2xl font-bold text-brand-amber">
              {formatKyat(totalUnits)} ฿
            </h3>
          </div>
          <div className="rounded-lg border border-amber-500/20 bg-amber-500/10 p-3 text-amber-400">
            <Wallet className="h-6 w-6" />
          </div>
        </div>

        <div className="flex items-center justify-between rounded-xl border border-slate-800 bg-brand-panel p-5">
          <div>
            <p className="text-xs font-medium uppercase text-slate-400">
              Agent Margin Rate
            </p>
            <h3 className="mt-1 text-2xl font-bold text-emerald-400">
              {AGENT_MARGIN_RATE.toFixed(1)} %
            </h3>
          </div>
          <div className="rounded-lg border border-emerald-500/20 bg-emerald-500/10 p-3 text-emerald-400">
            <TrendingUp className="h-6 w-6" />
          </div>
        </div>
      </div>

      {/* Toolbar */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="relative flex-1 sm:max-w-sm">
          <Search className="absolute left-3 top-3 h-4 w-4 text-slate-400" />
          <input
            type="text"
            placeholder="Search username or name…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-full rounded-lg border border-slate-700 bg-brand-panel py-2.5 pl-10 pr-4 text-sm text-slate-100 outline-none transition focus:border-brand-amber"
          />
        </div>
        <button
          onClick={() => setShowCreate(true)}
          className="inline-flex items-center justify-center gap-2 rounded-lg bg-brand-amber px-4 py-2.5 text-sm font-bold text-slate-900 shadow-lg shadow-amber-500/10 transition hover:bg-amber-400"
        >
          <UserPlus className="h-4 w-4" />
          Create User Account
        </button>
      </div>

      {actionError && (
          <p className="rounded-lg border border-rose-500/30 bg-rose-500/10 px-3 py-2 text-sm text-rose-300">
            {actionError}
          </p>
        )}

        {/* Table & Request Panel */}
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <div className="overflow-hidden rounded-xl border border-slate-800 bg-brand-panel shadow-xl lg:col-span-2">
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm text-slate-300">
              <thead className="border-b border-slate-800 bg-brand-navy text-xs font-semibold uppercase tracking-wide text-slate-400">
                <tr>
                  <th className="p-4">User</th>
                  <th className="p-4">Phone</th>
                  <th className="p-4 text-right">Unit Balance</th>
                  <th className="p-4 text-center">Active Bets</th>
                  <th className="p-4 text-right">Status</th>
                  <th className="p-4 text-right">Action</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-800">
                {visible.length === 0 && (
                  <tr>
                    <td colSpan={6} className="p-8 text-center text-slate-500">
                      <Users className="mx-auto mb-2 h-6 w-6 text-slate-600" />
                      No downline users yet. Use “Create User Account” to
                      provision the first account.
                    </td>
                  </tr>
                )}
                {visible.map((user) => (
                  <tr key={user.id} className="transition hover:bg-slate-800/50">
                    <td className="p-4">
                      <div className="font-bold text-slate-100">{user.username}</div>
                      <div className="text-xs text-slate-500">{user.name}</div>
                    </td>
                    <td className="p-4 font-mono text-xs text-slate-400">
                      {user.phone || '—'}
                    </td>
                    <td className="p-4 text-right">
                      <div className="font-bold text-brand-amber">
                        {formatKyat(user.current_balance)} ฿
                      </div>
                      <div className="text-xs text-slate-500">
                        hold {formatKyat(user.hold_balance)} ฿
                      </div>
                    </td>
                    <td className="p-4 text-center">
                      {user.active_bets > 0 ? (
                        <span className="rounded-full border border-blue-500/20 bg-blue-500/10 px-2.5 py-1 text-xs font-semibold text-blue-400">
                          {user.active_bets}
                        </span>
                      ) : (
                        <span className="text-xs text-slate-500">0</span>
                      )}
                    </td>
                    <td className="p-4 text-right">
                      {user.is_active ? (
                        <span className="rounded-full bg-emerald-500/15 px-2.5 py-1 text-xs font-semibold text-emerald-400">
                          ACTIVE
                        </span>
                      ) : (
                        <span className="rounded-full bg-rose-500/15 px-2.5 py-1 text-xs font-semibold text-rose-400">
                          SUSPENDED
                        </span>
                      )}
                    </td>
                    <td className="p-4 text-right">
                      <div className="flex items-center justify-end gap-2">
                        <button
                          onClick={() => {
                            setSelected(user);
                            setSearch('');
                          }}
                          className="inline-flex items-center gap-1.5 rounded-lg border border-blue-500/30 bg-blue-600/20 px-3 py-1.5 text-xs font-medium text-blue-400 transition hover:bg-blue-600/30"
                        >
                          <Send className="h-3.5 w-3.5" />
                          Point Request
                        </button>
                        <button
                          onClick={() => handleToggle(user)}
                          disabled={togglingId === user.id}
                          className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition disabled:opacity-60 ${
                            user.is_active
                              ? 'border border-rose-500/40 text-rose-400 hover:bg-rose-500/10'
                              : 'border border-emerald-500/40 text-emerald-400 hover:bg-emerald-500/10'
                          }`}
                        >
                          {togglingId === user.id ? (
                            <Loader2 className="h-3.5 w-3.5 animate-spin" />
                          ) : user.is_active ? (
                            'Suspend'
                          ) : (
                            'Activate'
                          )}
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="border-t border-slate-800 px-4 py-2 text-xs text-slate-500">
            Created: {visible.length === 0 ? '—' : formatDate(visible[0]!.created_at)} ·{' '}
            {visible.length} shown
          </div>
        </div>

        {selected ? (
          <UnitRequestPanel user={selected} onDeselect={() => setSelected(null)} />
        ) : (
          <div className="h-fit rounded-xl border border-dashed border-slate-800 bg-brand-panel/50 p-5">
            <div className="py-8 text-center text-sm text-slate-500">
              <Send className="mx-auto mb-2 h-6 w-6 text-slate-600" />
              Select a User from the table to initiate a Unit Request.
            </div>
          </div>
        )}
      </div>

      {showCreate && (
        <CreateUserModal
          onCreated={() => {
            setShowCreate(false);
            router.refresh();
          }}
          onClose={() => setShowCreate(false)}
        />
      )}
    </div>
  );
}