'use client';

import { Loader2, Save } from 'lucide-react';
import { useState, type ReactNode } from 'react';

import Modal from '@/components/modal';
import type { Fixture } from '@/lib/types';

import { saveFixtureOdds } from '../actions';

interface OddsEditorModalProps {
  fixture: Fixture;
  onSaved: (updated: Fixture) => void;
  onClose: () => void;
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: ReactNode;
}) {
  return (
    <label className="block">
      <span className="mb-1.5 flex items-baseline justify-between text-xs font-semibold text-slate-400">
        <span>{label}</span>
        {hint && <span className="font-normal text-slate-500">{hint}</span>}
      </span>
      {children}
    </label>
  );
}

const inputClass =
  'w-full rounded-lg border border-slate-700 bg-brand-navy px-3.5 py-2.5 font-mono text-sm text-slate-100 outline-none transition focus:border-brand-amber';

function toNumber(value: string): number {
  return Number(value);
}

export default function OddsEditorModal({
  fixture,
  onSaved,
  onClose,
}: OddsEditorModalProps) {
  const [handicapSide, setHandicapSide] = useState<string>(fixture.handicap_side);
  const [handicap, setHandicap] = useState<string>(fixture.handicap);
  const [homeBodyPayout, setHomeBodyPayout] = useState<string>(
    String(fixture.home_body_payout),
  );
  const [awayBodyPayout, setAwayBodyPayout] = useState<string>(
    String(fixture.away_body_payout),
  );
  const [homeMaung, setHomeMaung] = useState<string>(
    String(fixture.maung_home_multiplier),
  );
  const [awayMaung, setAwayMaung] = useState<string>(
    String(fixture.maung_away_multiplier),
  );
  const [drawMaung, setDrawMaung] = useState<string>(
    String(fixture.maung_draw_multiplier),
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit() {
    if (busy) return;

    const values = {
      home_body_payout: toNumber(homeBodyPayout),
      away_body_payout: toNumber(awayBodyPayout),
      maung_home_multiplier: toNumber(homeMaung),
      maung_away_multiplier: toNumber(awayMaung),
      maung_draw_multiplier: toNumber(drawMaung),
    };

    if (handicap.trim() === '') {
      setError('Handicap is required (e.g. 1+25, -36, 0-50).');
      return;
    }
    for (const [key, value] of Object.entries(values)) {
      if (!Number.isFinite(value) || value < 0.5) {
        setError(`${key} must be a number >= 0.50.`);
        return;
      }
    }

    const updated: Fixture = {
      ...fixture,
      handicap_side: handicapSide,
      handicap: handicap.trim(),
      ...values,
    };

    setBusy(true);
    setError(null);
    const result = await saveFixtureOdds({
      fixture_id: fixture.id,
      handicap_side: handicapSide,
      handicap: handicap.trim(),
      ...values,
    });
    if (!result.ok) {
      setError(result.error);
      setBusy(false);
      return;
    }
    onSaved(updated);
  }

  return (
    <Modal
      title={`Odds Editor — ${fixture.home_team} vs ${fixture.away_team}`}
      onClose={onClose}
      width="max-w-lg"
    >
      <div className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <Field label="Handicap Side">
            <select
              value={handicapSide}
              onChange={(e) => setHandicapSide(e.target.value)}
              className={inputClass}
            >
              <option value="HOME">Home</option>
              <option value="AWAY">Away</option>
            </select>
          </Field>
          <Field label="Myanmar Handicap" hint="e.g. 1+25">
            <input
              type="text"
              value={handicap}
              onChange={(e) => setHandicap(e.target.value)}
              className={inputClass}
            />
          </Field>
        </div>

        <div className="grid grid-cols-2 gap-4">
          <Field label="Body Payout · Home">
            <input
              type="number"
              step="0.05"
              min="0.5"
              value={homeBodyPayout}
              onChange={(e) => setHomeBodyPayout(e.target.value)}
              className={inputClass}
            />
          </Field>
          <Field label="Body Payout · Away">
            <input
              type="number"
              step="0.05"
              min="0.5"
              value={awayBodyPayout}
              onChange={(e) => setAwayBodyPayout(e.target.value)}
              className={inputClass}
            />
          </Field>
        </div>

        <div className="grid grid-cols-3 gap-4">
          <Field label="Maung Home">
            <input
              type="number"
              step="0.05"
              min="0.5"
              value={homeMaung}
              onChange={(e) => setHomeMaung(e.target.value)}
              className={inputClass}
            />
          </Field>
          <Field label="Maung Away">
            <input
              type="number"
              step="0.05"
              min="0.5"
              value={awayMaung}
              onChange={(e) => setAwayMaung(e.target.value)}
              className={inputClass}
            />
          </Field>
          <Field label="Maung Draw">
            <input
              type="number"
              step="0.05"
              min="0.5"
              value={drawMaung}
              onChange={(e) => setDrawMaung(e.target.value)}
              className={inputClass}
            />
          </Field>
        </div>

        {error && (
          <p className="rounded-lg border border-rose-500/30 bg-rose-500/10 px-3 py-2 text-sm text-rose-300">
            {error}
          </p>
        )}

        <div className="flex justify-end gap-2 pt-1">
          <button
            onClick={onClose}
            className="rounded-lg border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-300 transition hover:bg-slate-800"
          >
            Cancel
          </button>
          <button
            onClick={handleSubmit}
            disabled={busy}
            className="inline-flex items-center gap-2 rounded-lg bg-brand-amber px-4 py-2 text-sm font-bold text-slate-900 transition hover:bg-amber-400 disabled:opacity-60"
          >
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}
            {busy ? 'Saving…' : 'Save Odds'}
          </button>
        </div>
      </div>
    </Modal>
  );
}