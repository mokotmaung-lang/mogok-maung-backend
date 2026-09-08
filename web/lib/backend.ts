import { cookies } from 'next/headers';

import type {
  AdminAgent,
  AgentUserSummaryPage,
  AllocateInput,
  AllocateResult,
  Downline,
  Fixture,
  OddsInput,
  UnitRequestResult,
  UnitRequestType,
} from './types';

const BACKEND_URL = process.env.BACKEND_URL ?? 'http://localhost:8080';

export class BackendError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = 'BackendError';
  }
}

/**
 * Server-side API client. Intended for Server Components and Server Actions
 * only: it reads the JWT from the httpOnly session cookie and forwards it to
 * the Go backend as a Bearer token, sidestepping browser CORS entirely.
 */
async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const token = cookies().get('mm_session')?.value;
  if (!token) {
    throw new BackendError(401, 'Not authenticated');
  }

  const res = await fetch(`${BACKEND_URL}${path}`, {
    ...init,
    cache: 'no-store',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
      ...(init?.headers ?? {}),
    },
  });

  const body: unknown = await res.json().catch(() => null);
  if (!res.ok) {
    const message =
      (body as { error?: string } | null)?.error ?? `Backend returned ${res.status}`;
    throw new BackendError(res.status, message);
  }
  return body as T;
}

export async function listFixtures(): Promise<Fixture[]> {
  const data = await request<{ fixtures: Fixture[] }>('/api/v1/admin/fixtures');
  return data.fixtures;
}

export async function toggleFixture(id: number, isEnabled: boolean): Promise<void> {
  await request('/api/v1/admin/fixtures/toggle', {
    method: 'POST',
    body: JSON.stringify({ fixture_id: id, is_enabled: isEnabled }),
  });
}

export async function updateFixtureOdds(input: OddsInput): Promise<void> {
  await request('/api/v1/admin/fixtures/odds', {
    method: 'POST',
    body: JSON.stringify(input),
  });
}

export async function listDownlines(): Promise<Downline[]> {
  const data = await request<{ downlines: Downline[] }>('/api/v1/agent/downlines');
  return data.downlines;
}

/**
 * Paginated, searchable downline summary for the Agent User Management table
 * (GET /api/v1/agent/users/summary). `page` is 1-indexed, `limit` capped at 100.
 */
export async function listAgentUserSummary(input?: {
  page?: number;
  limit?: number;
  search?: string;
}): Promise<AgentUserSummaryPage> {
  const params = new URLSearchParams();
  if (input?.page) params.set('page', String(input.page));
  if (input?.limit) params.set('limit', String(input.limit));
  if (input?.search?.trim()) params.set('search', input.search.trim());
  const qs = params.toString();
  return request<AgentUserSummaryPage>(`/api/v1/agent/users/summary${qs ? `?${qs}` : ''}`);
}

/** Agent suspends / activates one of its own downline users. */
export async function toggleAgentUserStatus(input: {
  user_id: number;
  is_active: boolean;
}): Promise<{ user_id: number; is_active: boolean }> {
  const data = await request<{ data: { user_id: number; is_active: boolean } }>(
    '/api/v1/agent/users/toggle',
    { method: 'POST', body: JSON.stringify(input) },
  );
  return data.data;
}

export async function createDownlineUser(input: {
  username: string;
  phone: string;
}): Promise<void> {
  await request('/api/v1/agent/users/create', {
    method: 'POST',
    body: JSON.stringify(input),
  });
}

/** Forwards a downline deposit/withdraw request token to the Super Admin. */
export async function submitUnitRequest(input: {
  user_id: number;
  amount: number;
  type: UnitRequestType;
}): Promise<UnitRequestResult> {
  return request<UnitRequestResult>('/api/v1/agent/points/request', {
    method: 'POST',
    body: JSON.stringify(input),
  });
}

/** Lists every AGENT-role account for the Super Admin allocation dashboard. */
export async function listAgents(): Promise<AdminAgent[]> {
  const data = await request<{ agents: AdminAgent[] }>('/api/v1/admin/agents');
  return data.agents;
}

/** Super Admin toggles an agent account between ACTIVE and SUSPENDED. */
export async function toggleAgent(input: {
  agent_id: number;
  is_active: boolean;
}): Promise<{ agent_id: number; status: 'ACTIVE' | 'SUSPENDED' }> {
  const data = await request<{ data: { agent_id: number; status: 'ACTIVE' | 'SUSPENDED' } }>(
    '/api/v1/admin/agents/toggle',
    { method: 'POST', body: JSON.stringify(input) },
  );
  return data.data;
}

/**
 * Super Admin direct unit allocation (deposit/withdraw) to an agent account.
 * Backed by the pessimistic row-locked endpoint POST /api/v1/admin/units/allocate.
 */
export async function allocateUnits(input: AllocateInput): Promise<AllocateResult> {
  const data = await request<{ data: AllocateResult }>('/api/v1/admin/units/allocate', {
    method: 'POST',
    body: JSON.stringify(input),
  });
  return data.data;
}