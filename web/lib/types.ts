export type UserRole = 'USER' | 'AGENT' | 'ADMIN' | 'SUPER_ADMIN';

export interface LoginResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  role: UserRole;
  must_change_password: boolean;
}

export type FixtureStatus = 'OPEN' | 'CLOSED' | 'FINISHED';

/** Control-plane view of a match served by the Go backend. */
export interface Fixture {
  id: number;
  home_team: string;
  away_team: string;
  league_name: string;
  match_time: string;
  handicap_side: 'HOME' | 'AWAY' | string;
  handicap: string;
  home_body_payout: number;
  away_body_payout: number;
  maung_home_multiplier: number;
  maung_away_multiplier: number;
  maung_draw_multiplier: number;
  status: FixtureStatus | string;
}

/** Payload for overwriting the Myanmar odds profile of a fixture. */
export interface OddsInput {
  fixture_id: number;
  handicap_side: string;
  handicap: string;
  home_body_payout: number;
  away_body_payout: number;
  maung_home_multiplier: number;
  maung_away_multiplier: number;
  maung_draw_multiplier: number;
}

/** Downline user row served by GET /api/v1/agent/downlines. */
export interface Downline {
  id: number;
  username: string;
  name: string;
  phone: string;
  current_balance: number;
  hold_balance: number;
  is_active: boolean;
  active_bets: number;
  created_at: string;
}

/** Downline summary row served by GET /api/v1/agent/users/summary. */
export interface AgentUserSummary {
  user_id: number;
  name: string;
  username: string;
  current_balance: number;
  hold_balance: number;
  is_active: boolean;
  created_at: string;
}

export interface SummaryPagination {
  current_page: number;
  total_pages: number;
  total_records: number;
}

export interface AgentUserSummaryPage {
  data: AgentUserSummary[];
  pagination: SummaryPagination;
}

export type UnitRequestType = 'DEPOSIT' | 'WITHDRAW';

export interface UnitRequestResult {
  request_id: number;
}

/** AGENT-role user as served by GET /api/v1/admin/agents. */
export interface AdminAgent {
  id: number;
  username: string;
  name: string;
  current_balance: number;
  hold_balance: number;
  active_users_count: number;
  status: 'ACTIVE' | 'SUSPENDED';
  created_at: string;
}

export type AllocateActionType = 'DEPOSIT' | 'WITHDRAW';

export interface AllocateInput {
  agent_user_id: number;
  amount: number;
  action_type: AllocateActionType;
  note?: string;
}

export interface AllocateResult {
  agent_user_id: number;
  agent_current_balance: number;
  request_id: number;
  status: string;
}