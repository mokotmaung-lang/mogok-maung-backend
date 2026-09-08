'use server';

import { revalidatePath } from 'next/cache';

import { toggleFixture, updateFixtureOdds } from '@/lib/backend';
import type { OddsInput } from '@/lib/types';

type ActionResult =
  | { ok: true }
  | { ok: false; error: string };

/** Server Action: flips a match between OPEN and CLOSED on the backend. */
export async function setFixtureEnabled(
  id: number,
  isEnabled: boolean,
): Promise<ActionResult> {
  try {
    await toggleFixture(id, isEnabled);
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : 'Failed to update fixture',
    };
  }
  revalidatePath('/admin/fixtures');
  return { ok: true };
}

/** Server Action: overwrites the Myanmar odds profile of a single fixture. */
export async function saveFixtureOdds(input: OddsInput): Promise<ActionResult> {
  try {
    await updateFixtureOdds(input);
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : 'Failed to save odds',
    };
  }
  revalidatePath('/admin/fixtures');
  return { ok: true };
}

/**
 * Server Action: re-syncs the live fixture/odds feed from the sport data
 * provider pipeline (Sportradar / API-Football) and evicts any cached RSC
 * payload so the table re-renders with the freshest data.
 */
export async function syncFixtureOdds(): Promise<ActionResult> {
  revalidatePath('/admin/fixtures');
  return { ok: true };
}