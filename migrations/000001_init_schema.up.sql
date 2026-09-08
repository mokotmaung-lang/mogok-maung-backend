-- ============================================================================
-- Mogok Maung - Phase 1 single source of truth schema
-- Myanmar Football Betting System (Body/Maung with Double-Entry Ledger)
-- ============================================================================

-- 1. ENUMS & TYPES DEFINITION
CREATE TYPE user_role AS ENUM ('ADMIN', 'AGENT', 'USER');
CREATE TYPE trx_type AS ENUM ('DEPOSIT', 'WITHDRAW', 'BET_HOLD', 'BET_WIN', 'BET_LOSE', 'BET_REFUND');
CREATE TYPE request_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED');
CREATE TYPE match_status AS ENUM ('OPEN', 'CLOSED', 'FINISHED');
CREATE TYPE bet_type AS ENUM ('BODY', 'MAUNG');

-- 2. USERS TABLE (Hierarchical: Admin -> Agent -> User)
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    name VARCHAR(100) NOT NULL,
    role user_role NOT NULL,
    parent_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
    current_balance NUMERIC(15, 2) DEFAULT 0.00 CHECK (current_balance >= 0),
    hold_balance NUMERIC(15, 2) DEFAULT 0.00 CHECK (hold_balance >= 0),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_users_hierarchy ON users(role, parent_id);
CREATE INDEX idx_users_username ON users(username);

-- 3. MATCHES TABLE (Myanmar Odds System)
CREATE TABLE matches (
    id BIGSERIAL PRIMARY KEY,
    home_team VARCHAR(100) NOT NULL,
    away_team VARCHAR(100) NOT NULL,
    match_time TIMESTAMP WITH TIME ZONE NOT NULL,
    handicap_team VARCHAR(10) NOT NULL,
    body_odds_type VARCHAR(50) NOT NULL,
    home_body_payout NUMERIC(4,2) NOT NULL,
    away_body_payout NUMERIC(4,2) NOT NULL,
    maung_home_multiplier NUMERIC(4,2) NOT NULL,
    maung_away_multiplier NUMERIC(4,2) NOT NULL,
    maung_draw_multiplier NUMERIC(4,2) NOT NULL,
    status match_status DEFAULT 'OPEN',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_matches_status ON matches(status);

-- 4. UNIT TRANSACTION REQUESTS TABLE
CREATE TABLE unit_requests (
    id BIGSERIAL PRIMARY KEY,
    requester_id BIGINT NOT NULL REFERENCES users(id),
    approver_id BIGINT REFERENCES users(id),
    amount NUMERIC(15, 2) NOT NULL CHECK (amount > 0),
    type trx_type NOT NULL,
    status request_status DEFAULT 'PENDING',
    payment_info JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_unit_requests_pending ON unit_requests(status, requester_id) WHERE status = 'PENDING';

-- 5. UNIT TRANSACTION LEDGER TABLE (Immutable Audit Trail)
CREATE TABLE unit_ledger (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    request_id BIGINT REFERENCES unit_requests(id),
    bet_id BIGINT,
    type trx_type NOT NULL,
    amount_change NUMERIC(15, 2) NOT NULL,
    balance_before NUMERIC(15, 2) NOT NULL,
    balance_after NUMERIC(15, 2) NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_ledger_user_time ON unit_ledger(user_id, created_at DESC);