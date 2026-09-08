'use server';

import { revalidatePath } from 'next/cache';

import { createDownlineUser, submitUnitRequest, toggleAgentUserStatus } from '@/lib/backend';
import type { UnitRequestType } from '@/lib/types';

type ActionResult =
  | { ok: true }
  | { ok: false; error: string };

/** Server Action: provisions a new USER account owned by the calling agent. */
export async function createDownline(input: {
  username: string;
  phone: string;
}): Promise<ActionResult> {
  const username = input.username.trim();
  const phone = input.phone.trim();
  if (!username || !phone) {
    return { ok: false, error: 'Username and phone are required' };
  }
  try {
    await createDownlineUser({ username, phone });
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : 'Failed to create user',
    };
  }
  revalidatePath('/agent/downline');
  return { ok: true };
}

type SendUnitResult =
  | { ok: true; request_id: number }
  | { ok: false; error: string };

/**
 * Server Action: forwards a deposit/withdrawal unit request for a downline
 * user to the Super Admin approval queue.
 */
export async function sendUnitRequest(input: {
  user_id: number;
  amount: number;
  type: UnitRequestType;
}): Promise<SendUnitResult> {
  if (input.user_id <= 0 || !Number.isFinite(input.amount) || input.amount <= 0) {
    return { ok: false, error: 'A positive unit amount is required' };
  }
  if (input.type !== 'DEPOSIT' && input.type !== 'WITHDRAW') {
    return { ok: false, error: 'Type must be DEPOSIT or WITHDRAW' };
  }
  try {
    const result = await submitUnitRequest(input);
    return { ok: true, request_id: result.request_id };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : 'Failed to submit request',
    };
  }
}

export type ToggleUserState =
  | { ok: true; user_id: number; is_active: boolean }
  | { ok: false; error: string };

/**
 * Server Action: suspends / activates one downline user account. The backend
 * re-validates ownership (parent_id must be the calling agent) inside the
 * request, so this cannot enable/disable users outside the agent's tree.
 */
export async function toggleUserStatus(
  userId: number,
  isActive: boolean,
): Promise<ToggleUserState> {
  try {
    const result = await toggleAgentUserStatus({
      user_id: userId,
      is_active: isActive,
    });
    return { ok: true, user_id: result.user_id, is_active: result.is_active };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : 'Failed to update status',
    };
  }
}