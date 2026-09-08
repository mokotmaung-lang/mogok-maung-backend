import { Trophy } from 'lucide-react';

import LogoutButton from './logout-button';

interface ShellProps {
  title: string;
  subtitle: string;
  roleLabel: string;
  actions?: React.ReactNode;
  children: React.ReactNode;
}

/**
 * Shared portal frame: top navigation bar with the brand, the active role
 * chip and a sign-out button. Used by both dashboard modules.
 */
export default function Shell({
  title,
  subtitle,
  roleLabel,
  actions,
  children,
}: ShellProps) {
  return (
    <div className="min-h-screen bg-brand-navy text-slate-100">
      <header className="sticky top-0 z-20 border-b border-slate-800 bg-brand-navy/90 backdrop-blur">
        <div className="mx-auto flex max-w-7xl items-center justify-between px-6 py-4">
          <div className="flex items-center gap-3">
            <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-amber-500/15 text-amber-400">
              <Trophy className="h-5 w-5" />
            </span>
            <div>
              <p className="text-sm font-bold tracking-wide">MOGOK MAUNG</p>
              <p className="text-xs text-slate-400">Management Portal</p>
            </div>
          </div>
          <div className="flex items-center gap-3">
            {actions}
            <span className="hidden rounded-full border border-slate-700 bg-slate-800 px-3 py-1 text-xs font-semibold text-amber-400 sm:inline-block">
              {roleLabel}
            </span>
            <LogoutButton />
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-7xl px-6 py-8">
        <div className="mb-6">
          <h1 className="text-2xl font-bold text-brand-amber">{title}</h1>
          <p className="mt-1 text-sm text-slate-400">{subtitle}</p>
        </div>
        {children}
      </main>
    </div>
  );
}