'use client';

import { Loader2, UserPlus } from 'lucide-react';
import { useState } from 'react';

import Modal from '@/components/modal';

import { createDownline } from '../actions';

interface CreateUserModalProps {
  onCreated: () => void;
  onClose: () => void;
}

export default function CreateUserModal({
  onCreated,
  onClose,
}: CreateUserModalProps) {
  const [username, setUsername] = useState('');
  const [phone, setPhone] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit() {
    if (busy) return;
    setBusy(true);
    setError(null);

    const result = await createDownline({ username, phone });
    if (!result.ok) {
      setError(result.error);
      setBusy(false);
      return;
    }
    onCreated();
  }

  return (
    <Modal title="Provision New Downline User" onClose={onClose}>
      <div className="space-y-4">
        <label className="block">
          <span className="mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-400">
            Username
          </span>
          <input
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            autoFocus
            className="w-full rounded-lg border border-slate-700 bg-brand-navy px-3.5 py-2.5 text-sm text-slate-100 outline-none transition focus:border-brand-amber"
            placeholder="e.g. mg_min"
            maxLength={50}
            required
          />
        </label>

        <label className="block">
          <span className="mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-400">
            Phone
          </span>
          <input
            type="text"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            className="w-full rounded-lg border border-slate-700 bg-brand-navy px-3.5 py-2.5 text-sm text-slate-100 outline-none transition focus:border-brand-amber"
            placeholder="e.g. 09 123 456789"
          />
        </label>

        <p className="rounded-lg border border-amber-500/20 bg-amber-500/10 px-3 py-2 text-xs text-amber-300/90">
          Initial password is <span className="font-mono font-bold">Default@123</span>.
          The user must change it on first login before betting.
        </p>

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
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <UserPlus className="h-4 w-4" />}
            {busy ? 'Creating…' : 'Create User'}
          </button>
        </div>
      </div>
    </Modal>
  );
}