-- 5. BETS TABLE
CREATE TABLE bets (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    bet_type bet_type NOT NULL,
    total_stake NUMERIC(15, 2) NOT NULL CHECK (total_stake > 0),
    hold_amount NUMERIC(15, 2) NOT NULL,
    status VARCHAR(20) DEFAULT 'PENDING',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_bets_user_id ON bets(user_id);
CREATE INDEX idx_bets_status ON bets(status);

-- 6. BET SELECTIONS TABLE
CREATE TABLE bet_selections (
    id BIGSERIAL PRIMARY KEY,
    bet_id BIGINT NOT NULL REFERENCES bets(id) ON DELETE CASCADE,
    match_id BIGINT NOT NULL REFERENCES matches(id),
    pick VARCHAR(10) NOT NULL,
    body_odds_type VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_bet_selections_bet_id ON bet_selections(bet_id);
CREATE INDEX idx_bet_selections_match_id ON bet_selections(match_id);