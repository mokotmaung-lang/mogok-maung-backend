'use client';

import { Loader2, RefreshCw, Users } from 'lucide-react';
import { useState } from 'react';

import { formatMoney } from '@/lib/format';
import type { AdminAgent } from '@/lib/types';

import { fetchAgents, toggleAgentStatus } from '../actions';
import AllocationPanel from './allocation-panel';

interface AgentsManagerProps {
  initialAgents: AdminAgent[];
}

/**
 * Agent allocation dashboard: agent overview table (live balances, active
 * downline count, ACTIVE/SUSPENDED status with an in-row toggle) plus the
 * allocation side panel. A successful allocation echoes the new balance into
 * the table; a status toggle keeps the two views in sync.
 */
export default function AgentsManager({ initialAgents }: AgentsManagerProps) {
  const [agents, setAgents] = useState<AdminAgent[]>(initialAgents);
  const [selected, setSelected] = useState<AdminAgent | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const [togglingId, setTogglingId] = useState<number | null>(null);

  async function handleRefresh() {
    setRefreshing(true);
    setRefreshError(null);
    const result = await fetchAgents();
    setRefreshing(false);
    if (!result.ok) {
      setRefreshError(result.error);
      return;
    }
    setAgents(result.agents);
    if (selected) {
      const next = result.agents.find((a) => a.id === selected.id);
      setSelected(next ?? null);
    }
  }

  function handleBalanceUpdated(agentId: number, newBalance: number) {
    setAgents((prev) =>
      prev.map((a) => (a.id === agentId ? { ...a, current_balance: newBalance } : a)),
    );
    setSelected((prev) =>
      prev && prev.id === agentId ? { ...prev, current_balance: newBalance } : prev,
    );
  }

  async function handleToggle(agent: AdminAgent) {
    setTogglingId(agent.id);
    setRefreshError(null);
    const result = await toggleAgentStatus(agent.id, agent.status === 'SUSPENDED');
    setTogglingId(null);
    if (!result.ok) {
      setRefreshError(result.error);
      return;
    }
    const nextStatus = result.status;
    setAgents((prev) =>
      prev.map((a) => (a.id === agent.id ? { ...a, status: nextStatus } : a)),
    );
    setSelected((prev) =>
      prev && prev.id === agent.id ? { ...prev, status: nextStatus } : prev,
    );
  }

  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_360px]">
      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="flex items-center gap-2 text-sm font-bold text-slate-200">
            <Users className="h-4 w-4 text-amber-400" />
            Agents
          </h2>
          <button
            onClick={handleRefresh}
            disabled={refreshing}
            className="flex items-center gap-2 rounded-lg border border-slate-700 bg-brand-panel px-3 py-1.5 text-xs font-semibold text-slate-300 transition hover:text-slate-100 disabled:opacity-60"
          >
            {refreshing ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RefreshCw className="h-3.5 w-3.5" />}
            Refresh
          </button>
        </div>

        {refreshError && (
          <p className="rounded-lg border border-rose-500/30 bg-rose-500/10 px-3 py-2 text-sm text-rose-300">
            {refreshError}
          </p>
        )}

        <div className="overflow-x-auto rounded-xl border border-slate-800">
          <table className="w-full min-w-[720px] text-left text-sm">
            <thead className="border-b border-slate-800 bg-brand-panel text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-4 py-3 font-semibold">Agent</th>
                <th className="px-4 py-3 text-right font-semibold">Balance</th>
                <th className="px-4 py-3 text-right font-semibold">Hold</th>
                <th className="px-4 py-3 text-right font-semibold">Active Users</th>
                <th className="px-4 py-3 text-center font-semibold">Status</th>
                <th className="px-4 py-3 text-right font-semibold">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-800">
              {agents.length === 0 && (
                <tr>
                  <td colSpan={6} className="px-4 py-8 text-center text-slate-500">
                    No agents provisioned yet.
                  </td>
                </tr>
              )}
              {agents.map((agent) => (
                <tr key={agent.id} className="bg-brand-navy/60 transition hover:bg-brand-panel">
                  <td className="px-4 py-3">
                    <p className="font-semibold text-slate-100">{agent.name}</p>
                    <p className="font-mono text-xs text-slate-500">@{agent.username}</p>
                  </td>
                  <td className="px-4 py-3 text-right font-mono text-emerald-400">
                    {formatMoney(agent.current_balance)}
                  </td>
                  <td className="px-4 py-3 text-right font-mono text-amber-400/80">
                    {formatMoney(agent.hold_balance)}
                  </td>
                  <td className="px-4 py-3 text-right text-slate-300">
                    {agent.active_users_count} users
                  </td>
                  <td className="px-4 py-3 text-center">
                    <span
                      className={`inline-block rounded-full px-2.5 py-0.5 text-xs font-bold ${
                        agent.status === 'ACTIVE'
                          ? 'bg-emerald-500/15 text-emerald-400'
                          : 'bg-rose-500/15 text-rose-400'
                      }`}
                    >
                      {agent.status === 'ACTIVE' ? 'ACTIVE' : 'SUSPENDED'}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <div className="flex items-center justify-end gap-2">
                      <button
                        onClick={() => {
                          setSelected(agent);
                        }}
                        className="rounded-lg border border-brand-amber bg-brand-amber/10 px-3 py-1.5 text-xs font-semibold text-brand-amber transition hover:bg-brand-amber/20"
                      >
                        {selected?.id === agent.id ? 'Selected' : 'Allocate'}
                      </button>
                      <button
                        onClick={() => handleToggle(agent)}
                        disabled={togglingId === agent.id}
                        className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition disabled:opacity-60 ${
                          agent.status === 'ACTIVE'
                            ? 'border border-rose-500/40 text-rose-400 hover:bg-rose-500/10'
                            : 'border border-emerald-500/40 text-emerald-400 hover:bg-emerald-500/10'
                        }`}
                      >
                        {togglingId === agent.id ? (
                          <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        ) : agent.status === 'ACTIVE' ? (
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
      </div>

      {selected ? (
        <AllocationPanel
          key={selected.id}
          agent={selected}
          onDeselect={() => setSelected(null)}
          onBalanceUpdated={handleBalanceUpdated}
        />
      ) : (
        <div className="flex h-fit min-h-40 items-center justify-center rounded-xl border border-dashed border-slate-800 text-center text-sm text-slate-600">
          Select an agent to allocate units.
        </div>
      )}
    </div>
  );
}