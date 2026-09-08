'use server';

import { allocateUnits, listAgents, toggleAgent } from '@/lib/backend';
import type { AllocateActionType } from '@/lib/types';

export type AllocateActionState =
  | { ok: true; agent_user_id: number; agent_current_balance: number; request_id: number }
  | { ok: false; error: string };

/** Server action: Super Admin allocates units to an agent (row-locked on the backend). */
export async function allocateAgentUnits(input: {
  agent_user_id: number;
  amount: number;
  action_type: AllocateActionType;
  note?: string;
}): Promise<AllocateActionState> {
  if (!Number.isFinite(input.amount) || input.amount <= 0) {
    return { ok: false, error: 'Enter a positive unit amount.' };
  }
  try {
    const result = await allocateUnits({
      agent_user_id: input.agent_user_id,
      amount: input.amount,
      action_type: input.action_type,
      note: input.note ?? 'Admin managed allocation',
    });
    return {
      ok: true,
      agent_user_id: result.agent_user_id,
      agent_current_balance: result.agent_current_balance,
      request_id: result.request_id,
    };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Allocation failed.',
    };
  }
}

/** Server action: fresh agent list for the allocation dashboard. */
export async function fetchAgents() {
  try {
    return { ok: true as const, agents: await listAgents() };
  } catch (error) {
    return {
      ok: false as const,
      error: error instanceof Error ? error.message : 'Could not load agents.',
    };
  }
}

export type ToggleAgentState =
  | { ok: true; agent_id: number; status: 'ACTIVE' | 'SUSPENDED' }
  | { ok: false; error: string };

/** Server action: suspend / activate an agent account (Super Admin). */
export async function toggleAgentStatus(
  agentId: number,
  isActive: boolean,
): Promise<ToggleAgentState> {
  try {
    const result = await toggleAgent({ agent_id: agentId, is_active: isActive });
    return { ok: true, agent_id: result.agent_id, status: result.status };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Could not update agent status.',
    };
  }
}