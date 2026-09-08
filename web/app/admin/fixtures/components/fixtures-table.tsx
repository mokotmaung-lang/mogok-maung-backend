'use client';

import {
  CheckCircle2,
  Edit3,
  Filter,
  Loader2,
  Search,
  SwitchCamera,
  XCircle,
} from 'lucide-react';
import { useMemo, useState } from 'react';

import { formatDateTime, formatMoney } from '@/lib/format';
import type { Fixture } from '@/lib/types';

import { setFixtureEnabled } from '../actions';
import OddsEditorModal from './odds-editor-modal';

interface FixturesTableProps {
  initialFixtures: Fixture[];
}

export default function FixturesTable({ initialFixtures }: FixturesTableProps) {
  const [fixtures, setFixtures] = useState<Fixture[]>(initialFixtures);
  const [search, setSearch] = useState('');
  const [league, setLeague] = useState<string>('ALL');
  const [busyIds, setBusyIds] = useState<ReadonlySet<number>>(new Set());
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<Fixture | null>(null);

  const leagues = useMemo(
    () => Array.from(new Set(fixtures.map((f) => f.league_name))).sort(),
    [fixtures],
  );

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return fixtures.filter((f) => {
      const inLeague = league === 'ALL' || f.league_name === league;
      const inSearch =
        q === '' ||
        f.home_team.toLowerCase().includes(q) ||
        f.away_team.toLowerCase().includes(q);
      return inLeague && inSearch;
    });
  }, [fixtures, search, league]);

  const isEnabled = (f: Fixture) => f.status === 'OPEN';

  async function handleToggle(fixture: Fixture) {
    const targetEnabled = !isEnabled(fixture);
    setError(null);

    // Optimistic update; rolled back on failure.
    setFixtures((prev) =>
      prev.map((f) =>
        f.id === fixture.id
          ? { ...f, status: targetEnabled ? 'OPEN' : 'CLOSED' }
          : f,
      ),
    );
    setBusyIds((prev) => {
      const next = new Set(prev);
      next.add(fixture.id);
      return next;
    });

    const result = await setFixtureEnabled(fixture.id, targetEnabled);
    if (!result.ok) {
      setFixtures((prev) =>
        prev.map((f) => (f.id === fixture.id ? { ...f, status: fixture.status } : f)),
      );
      setError(result.error);
    }

    setBusyIds((prev) => {
      const next = new Set(prev);
      next.delete(fixture.id);
      return next;
    });
  }

  function handleOddsSaved(updated: Fixture) {
    setFixtures((prev) => prev.map((f) => (f.id === updated.id ? updated : f)));
    setEditing(null);
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-col gap-4 sm:flex-row">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-3 h-4 w-4 text-slate-400" />
          <input
            type="text"
            placeholder="Search teams…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-full rounded-lg border border-slate-700 bg-brand-panel py-2.5 pl-10 pr-4 text-sm text-slate-100 outline-none transition focus:border-brand-amber"
          />
        </div>
        <div className="flex items-center gap-2">
          <Filter className="h-4 w-4 text-slate-400" />
          <select
            value={league}
            onChange={(e) => setLeague(e.target.value)}
            className="rounded-lg border border-slate-700 bg-brand-panel px-4 py-2.5 text-sm text-slate-100 outline-none transition focus:border-brand-amber"
          >
            <option value="ALL">All Leagues</option>
            {leagues.map((name) => (
              <option key={name} value={name}>
                {name}
              </option>
            ))}
          </select>
        </div>
      </div>

      {error && (
        <p className="rounded-lg border border-rose-500/30 bg-rose-500/10 px-4 py-2.5 text-sm text-rose-300">
          {error}
        </p>
      )}

      <div className="overflow-hidden rounded-xl border border-slate-800 bg-brand-panel shadow-xl">
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm text-slate-300">
            <thead className="border-b border-slate-800 bg-brand-navy text-xs font-semibold uppercase tracking-wide text-slate-400">
              <tr>
                <th className="p-4">Match / League</th>
                <th className="p-4">Time</th>
                <th className="p-4">Myanmar Handicap</th>
                <th className="p-4">Payout (Home/Away)</th>
                <th className="p-4">Maung</th>
                <th className="p-4 text-center">Status</th>
                <th className="p-4 text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-800">
              {visible.length === 0 && (
                <tr>
                  <td colSpan={7} className="p-8 text-center text-slate-500">
                    No fixtures match the current filters.
                  </td>
                </tr>
              )}
              {visible.map((fixture) => {
                const enabled = isEnabled(fixture);
                const busy = busyIds.has(fixture.id);
                return (
                  <tr key={fixture.id} className="transition hover:bg-slate-800/50">
                    <td className="p-4">
                      <div className="font-bold text-slate-100">
                        {fixture.home_team} vs {fixture.away_team}
                      </div>
                      <div className="text-xs text-amber-400/80">
                        {fixture.league_name}
                      </div>
                    </td>
                    <td className="p-4 text-xs text-slate-400">
                      {formatDateTime(fixture.match_time)}
                    </td>
                    <td className="p-4">
                      <span className="rounded border border-slate-700 bg-slate-800 px-2.5 py-1 font-mono text-xs font-bold text-amber-300">
                        {fixture.handicap_side === 'HOME' ? `${fixture.handicap}` : `-${fixture.handicap}`}
                      </span>
                    </td>
                    <td className="p-4 font-mono text-xs">
                      <span className="text-slate-500">H</span>{' '}
                      <span className="text-emerald-400">{formatMoney(fixture.home_body_payout)}</span>
                      {' | '}
                      <span className="text-slate-500">A</span>{' '}
                      <span className="text-emerald-400">{formatMoney(fixture.away_body_payout)}</span>
                    </td>
                    <td className="p-4 font-mono text-xs text-slate-400">
                      {formatMoney(fixture.maung_home_multiplier)} /{' '}
                      {formatMoney(fixture.maung_away_multiplier)} /{' '}
                      {formatMoney(fixture.maung_draw_multiplier)}
                    </td>
                    <td className="p-4 text-center">
                      {enabled ? (
                        <span className="inline-flex items-center gap-1 rounded-full border border-emerald-500/20 bg-emerald-500/10 px-2.5 py-1 text-xs text-emerald-400">
                          <CheckCircle2 className="h-3 w-3" /> Active
                        </span>
                      ) : (
                        <span className="inline-flex items-center gap-1 rounded-full border border-rose-500/20 bg-rose-500/10 px-2.5 py-1 text-xs text-rose-400">
                          <XCircle className="h-3 w-3" /> Disabled
                        </span>
                      )}
                    </td>
                    <td className="p-4">
                      <div className="flex items-center justify-end gap-2">
                        <button
                          onClick={() => setEditing(fixture)}
                          className="inline-flex items-center gap-1.5 rounded-lg border border-slate-700 bg-slate-800 px-3 py-1.5 text-xs font-semibold text-slate-300 transition hover:bg-slate-700 hover:text-slate-100"
                        >
                          <Edit3 className="h-3.5 w-3.5" />
                          Edit
                        </button>
                        <button
                          onClick={() => handleToggle(fixture)}
                          disabled={busy || fixture.status === 'FINISHED'}
                          className={`inline-flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-xs font-semibold transition disabled:cursor-not-allowed disabled:opacity-50 ${
                            enabled
                              ? 'border-rose-500/30 bg-rose-600/20 text-rose-300 hover:bg-rose-600/30'
                              : 'border-emerald-500/30 bg-emerald-600/20 text-emerald-300 hover:bg-emerald-600/30'
                          }`}
                        >
                          {busy ? (
                            <Loader2 className="h-3.5 w-3.5 animate-spin" />
                          ) : (
                            <SwitchCamera className="h-3.5 w-3.5" />
                          )}
                          {busy ? 'Saving' : enabled ? 'Disable' : 'Enable'}
                        </button>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {editing && (
        <OddsEditorModal
          fixture={editing}
          onSaved={handleOddsSaved}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}