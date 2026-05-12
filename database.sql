-- =============================================================================
-- AMS2 Career Companion — Database Schema (PostgreSQL)
-- =============================================================================
-- Scope (v1):
--   * Player profile + economy ledger
--   * 47 AMS2 car classes (flat list) with suggested pricing per class
--   * Owned cars with per-slot wear/condition (engine, gearbox, clutch,
--     brakes, tires, suspension, bodywork)
--   * Wear from sessions, user-reported breakages, maintenance events
--   * Repair costs scaled by severity × car class
--
-- Source for class taxonomy: ams2cars.info (9 top-level categories,
-- de-duplicated; the `parent_category` column preserves the grouping
-- without needing a separate table).
--
-- Conventions:
--   * Money in BIGINT cents.
--   * TIMESTAMPTZ everywhere.
--   * If you re-run this file, drop the DB first or wrap in
--     DROP TABLE/TYPE IF EXISTS — a failed CREATE TYPE inside the
--     BEGIN..COMMIT will abort the whole transaction.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------

CREATE TYPE component_slot AS ENUM (
    'engine',
    'gearbox',
    'clutch',
    'brakes',
    'tires',
    'suspension',
    'bodywork'
);

CREATE TYPE transaction_kind AS ENUM (
    'car_purchase',
    'car_sale',
    'repair',
    'race_entry_fee',
    'prize_money',
    'sponsor_payout',
    'sponsor_bonus',
    'fine',
    'misc_income',
    'misc_expense'
);

CREATE TYPE session_kind AS ENUM (
    'practice',
    'qualifying',
    'race',
    'test_day',
    'free_run'
);

CREATE TYPE breakage_severity AS ENUM (
    'minor',
    'major',
    'terminal'
);

CREATE TYPE maintenance_kind AS ENUM (
    'repair',
    'rebuild',
    'tire_change',
    'setup_tune'
);


-- -----------------------------------------------------------------------------
-- Player
-- -----------------------------------------------------------------------------

CREATE TABLE player (
    id                 BIGSERIAL PRIMARY KEY,
    display_name       TEXT        NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    cash_balance_cents BIGINT      NOT NULL DEFAULT 0
);


-- -----------------------------------------------------------------------------
-- Car categories (= AMS2 in-game classes)
--
-- parent_category is a free-text label preserving the ams2cars.info top-level
-- grouping. Kept as text rather than a separate table for simplicity; if you
-- want a strict 2-level model later it's a clean migration.
-- -----------------------------------------------------------------------------

CREATE TABLE car_category (
    id                        BIGSERIAL PRIMARY KEY,
    code                      TEXT        NOT NULL UNIQUE,
    display_name              TEXT        NOT NULL,
    parent_category           TEXT        NOT NULL,
    suggested_price_min_cents BIGINT      NOT NULL CHECK (suggested_price_min_cents >= 0),
    suggested_price_max_cents BIGINT      NOT NULL CHECK (suggested_price_max_cents >= 0),
    repair_cost_multiplier    NUMERIC(4,2) NOT NULL DEFAULT 1.00
        CHECK (repair_cost_multiplier > 0),
    notes                     TEXT,
    CHECK (suggested_price_max_cents >= suggested_price_min_cents)
);

CREATE INDEX idx_car_category_parent ON car_category(parent_category);


-- -----------------------------------------------------------------------------
-- Car models (catalog of cars in AMS2; seeded by you over time)
-- -----------------------------------------------------------------------------

CREATE TABLE car_model (
    id                    BIGSERIAL PRIMARY KEY,
    manufacturer          TEXT        NOT NULL,
    model_name            TEXT        NOT NULL,
    year                  INTEGER,
    category_id           BIGINT      NOT NULL REFERENCES car_category(id) ON DELETE RESTRICT,
    suggested_price_cents BIGINT      CHECK (suggested_price_cents IS NULL OR suggested_price_cents >= 0),
    is_user_added         BOOLEAN     NOT NULL DEFAULT FALSE,
    created_by            BIGINT      REFERENCES player(id) ON DELETE SET NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (manufacturer, model_name, year)
);

CREATE INDEX idx_car_model_category ON car_model(category_id);


-- -----------------------------------------------------------------------------
-- Base repair cost per component slot
-- Final cost = base × severity_multiplier × category.repair_cost_multiplier
-- -----------------------------------------------------------------------------

CREATE TABLE component_repair_cost (
    slot                    component_slot PRIMARY KEY,
    base_repair_cost_cents  BIGINT NOT NULL CHECK (base_repair_cost_cents >= 0),
    base_rebuild_cost_cents BIGINT NOT NULL CHECK (base_rebuild_cost_cents >= 0),
    expected_life_km        INTEGER NOT NULL CHECK (expected_life_km > 0),
    notes                   TEXT
);


-- -----------------------------------------------------------------------------
-- Garage
-- -----------------------------------------------------------------------------

CREATE TABLE car_instance (
    id                    BIGSERIAL PRIMARY KEY,
    player_id             BIGINT      NOT NULL REFERENCES player(id) ON DELETE CASCADE,
    car_model_id          BIGINT      NOT NULL REFERENCES car_model(id) ON DELETE RESTRICT,
    nickname              TEXT,
    livery                TEXT,
    acquired_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    acquired_price_cents  BIGINT      NOT NULL CHECK (acquired_price_cents >= 0),
    total_mileage_km      NUMERIC(10,2) NOT NULL DEFAULT 0,
    total_hours           NUMERIC(8,2)  NOT NULL DEFAULT 0,
    is_sold               BOOLEAN     NOT NULL DEFAULT FALSE,
    sold_at               TIMESTAMPTZ,
    sold_price_cents      BIGINT
);

CREATE INDEX idx_car_instance_player ON car_instance(player_id);

CREATE TABLE car_component (
    id                BIGSERIAL PRIMARY KEY,
    car_instance_id   BIGINT         NOT NULL REFERENCES car_instance(id) ON DELETE CASCADE,
    slot              component_slot NOT NULL,
    condition_pct     NUMERIC(5,2)   NOT NULL DEFAULT 100
        CHECK (condition_pct BETWEEN 0 AND 100),
    mileage_km        NUMERIC(10,2)  NOT NULL DEFAULT 0,
    hours_used        NUMERIC(8,2)   NOT NULL DEFAULT 0,
    sessions_used     INTEGER        NOT NULL DEFAULT 0,
    last_rebuilt_at   TIMESTAMPTZ,
    UNIQUE (car_instance_id, slot)
);

CREATE INDEX idx_car_component_car ON car_component(car_instance_id);


-- -----------------------------------------------------------------------------
-- Tracks
-- -----------------------------------------------------------------------------

CREATE TABLE track (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT        NOT NULL,
    layout          TEXT,
    country         TEXT,
    length_km       NUMERIC(6,3),
    is_user_added   BOOLEAN     NOT NULL DEFAULT FALSE,
    created_by      BIGINT      REFERENCES player(id) ON DELETE SET NULL,
    UNIQUE (name, layout)
);


-- -----------------------------------------------------------------------------
-- Usage sessions
-- -----------------------------------------------------------------------------

CREATE TABLE usage_session (
    id                  BIGSERIAL PRIMARY KEY,
    player_id           BIGINT      NOT NULL REFERENCES player(id) ON DELETE CASCADE,
    car_instance_id     BIGINT      NOT NULL REFERENCES car_instance(id) ON DELETE CASCADE,
    track_id            BIGINT      REFERENCES track(id) ON DELETE SET NULL,
    kind                session_kind NOT NULL,
    started_at          TIMESTAMPTZ NOT NULL,
    ended_at            TIMESTAMPTZ,
    laps                INTEGER     NOT NULL DEFAULT 0 CHECK (laps >= 0),
    distance_km         NUMERIC(8,2) NOT NULL DEFAULT 0 CHECK (distance_km >= 0),
    duration_hours      NUMERIC(6,2) NOT NULL DEFAULT 0 CHECK (duration_hours >= 0),
    finishing_position  INTEGER,
    prize_cents         BIGINT,
    entry_fee_cents     BIGINT,
    notes               TEXT
);

CREATE INDEX idx_usage_session_car_time ON usage_session(car_instance_id, started_at DESC);
CREATE INDEX idx_usage_session_player   ON usage_session(player_id);


-- -----------------------------------------------------------------------------
-- Breakage events
-- -----------------------------------------------------------------------------

CREATE TABLE breakage_event (
    id                  BIGSERIAL PRIMARY KEY,
    player_id           BIGINT         NOT NULL REFERENCES player(id) ON DELETE CASCADE,
    car_instance_id     BIGINT         NOT NULL REFERENCES car_instance(id) ON DELETE CASCADE,
    car_component_id    BIGINT         REFERENCES car_component(id) ON DELETE SET NULL,
    slot                component_slot NOT NULL,
    session_id          BIGINT         REFERENCES usage_session(id) ON DELETE SET NULL,
    occurred_at         TIMESTAMPTZ    NOT NULL DEFAULT now(),
    severity            breakage_severity NOT NULL,
    caused_dnf          BOOLEAN        NOT NULL DEFAULT FALSE,
    description         TEXT
);

CREATE INDEX idx_breakage_car_time ON breakage_event(car_instance_id, occurred_at DESC);


-- -----------------------------------------------------------------------------
-- Maintenance events
-- -----------------------------------------------------------------------------

CREATE TABLE maintenance_event (
    id                       BIGSERIAL PRIMARY KEY,
    player_id                BIGINT      NOT NULL REFERENCES player(id) ON DELETE CASCADE,
    car_instance_id          BIGINT      NOT NULL REFERENCES car_instance(id) ON DELETE CASCADE,
    car_component_id         BIGINT      REFERENCES car_component(id) ON DELETE SET NULL,
    slot                     component_slot,
    kind                     maintenance_kind NOT NULL,
    triggered_by_breakage_id BIGINT      REFERENCES breakage_event(id) ON DELETE SET NULL,
    performed_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    cost_cents               BIGINT      NOT NULL DEFAULT 0 CHECK (cost_cents >= 0),
    restored_condition_pct   NUMERIC(5,2) CHECK (restored_condition_pct BETWEEN 0 AND 100),
    notes                    TEXT
);

CREATE INDEX idx_maintenance_car_time ON maintenance_event(car_instance_id, performed_at DESC);


-- -----------------------------------------------------------------------------
-- Economy ledger
-- -----------------------------------------------------------------------------

CREATE TABLE money_transaction (
    id                     BIGSERIAL PRIMARY KEY,
    player_id              BIGINT      NOT NULL REFERENCES player(id) ON DELETE CASCADE,
    occurred_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    kind                   transaction_kind NOT NULL,
    amount_cents           BIGINT      NOT NULL,
    description            TEXT,
    related_car_id         BIGINT      REFERENCES car_instance(id)       ON DELETE SET NULL,
    related_session_id     BIGINT      REFERENCES usage_session(id)      ON DELETE SET NULL,
    related_maintenance_id BIGINT      REFERENCES maintenance_event(id)  ON DELETE SET NULL
);

CREATE INDEX idx_money_transaction_player_time
    ON money_transaction(player_id, occurred_at DESC);
CREATE INDEX idx_money_transaction_kind ON money_transaction(kind);


-- -----------------------------------------------------------------------------
-- Sponsor stubs
-- -----------------------------------------------------------------------------

CREATE TABLE sponsor (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT        NOT NULL,
    is_user_added   BOOLEAN     NOT NULL DEFAULT FALSE,
    created_by      BIGINT      REFERENCES player(id) ON DELETE SET NULL
);

CREATE TABLE sponsor_contract (
    id                     BIGSERIAL PRIMARY KEY,
    player_id              BIGINT      NOT NULL REFERENCES player(id) ON DELETE CASCADE,
    sponsor_id             BIGINT      NOT NULL REFERENCES sponsor(id) ON DELETE RESTRICT,
    started_at             TIMESTAMPTZ NOT NULL,
    ended_at               TIMESTAMPTZ,
    base_payout_cents      BIGINT      NOT NULL DEFAULT 0 CHECK (base_payout_cents >= 0),
    bonus_per_win_cents    BIGINT      NOT NULL DEFAULT 0 CHECK (bonus_per_win_cents >= 0),
    bonus_per_podium_cents BIGINT      NOT NULL DEFAULT 0 CHECK (bonus_per_podium_cents >= 0),
    notes                  TEXT
);

CREATE INDEX idx_sponsor_contract_player ON sponsor_contract(player_id);


-- -----------------------------------------------------------------------------
-- Seed: base repair costs per component slot (USD cents)
-- -----------------------------------------------------------------------------

INSERT INTO component_repair_cost (slot, base_repair_cost_cents, base_rebuild_cost_cents, expected_life_km, notes) VALUES
    ('engine',     150000,  800000,  3000, 'Major rebuild = full engine swap'),
    ('gearbox',    120000,  600000,  4000, NULL),
    ('clutch',      40000,  150000,  2500, 'Wears fast with abuse'),
    ('brakes',      30000,  100000,  1500, 'Pads + discs together'),
    ('tires',       25000,   80000,   500, 'A set, not per corner'),
    ('suspension',  80000,  300000,  5000, NULL),
    ('bodywork',    50000,  250000, 99999, 'Pure contact damage, no natural wear');


-- -----------------------------------------------------------------------------
-- Seed: AMS2 car classes (47 total, grouped by ams2cars.info parent category)
-- Pricing in USD cents. Numbers are starting points — tune to taste.
-- -----------------------------------------------------------------------------

INSERT INTO car_category (code, display_name, parent_category, suggested_price_min_cents, suggested_price_max_cents, repair_cost_multiplier, notes) VALUES
    -- GT & Sports Cars
    ('gt1',                'FIA GT1',                         'GT & Sports Cars',  70000000, 120000000, 1.60, '1990s'),
    ('gte',                'GTE',                             'GT & Sports Cars',  55000000,  90000000, 1.40, 'Active'),
    ('gt3',                'GT3',                             'GT & Sports Cars',  40000000,  65000000, 1.30, 'Active'),
    ('gt_open',            'GT Open',                         'GT & Sports Cars',  30000000,  55000000, 1.20, '2010s, 2020s'),
    ('gt4',                'GT4 (Império Endurance)',         'GT & Sports Cars',  18000000,  30000000, 1.00, 'Active'),
    ('gt_classics',        'GT Classics',                     'GT & Sports Cars',  25000000,  60000000, 1.30, '1970s'),

    -- Prototypes
    ('lmdh',               'LMDh / GTP',                      'Prototypes',       120000000, 220000000, 2.10, 'Active hypercar prototypes'),
    ('cadillac_dpi',       'Cadillac DPi',                    'Prototypes',        60000000, 100000000, 1.70, 'Single car class'),
    ('group_c',            'Group C',                         'Prototypes',        80000000, 150000000, 1.80, '1980s'),

    -- Brazilian Series
    ('stock_car_brasil',   'Stock Car Brasil',                'Brazilian Series',  20000000,  40000000, 1.10, 'Active — major South American series'),
    ('imperio_endurance',  'Império Endurance',               'Brazilian Series',  18000000,  35000000, 1.00, 'Active endurance series'),
    ('f_inter',            'Formula Inter MG-15',             'Brazilian Series',  12000000,  25000000, 1.00, 'Active'),
    ('f_vee_brasil',       'Formula Vee Brasil',              'Brazilian Series',   3500000,   8000000, 0.70, 'Active'),
    ('br_classics',        'Brazilian Classics',              'Brazilian Series',   5000000,  12000000, 0.70, 'Active'),
    ('br_historics',       'Brazilian Historics',             'Brazilian Series',   8000000,  20000000, 0.80, '1980s, 1990s'),
    ('copa_truck',         'Copa Truck',                      'Brazilian Series',  15000000,  30000000, 1.00, 'Active — racing trucks'),
    ('f3_brasil',          'Formula 3 Brasil',                'Brazilian Series',  10000000,  20000000, 1.00, '2010s'),
    ('sprint_race',        'Sprint Race',                     'Brazilian Series',   6000000,  12000000, 0.80, 'Active'),
    ('copa_montana',       'Chevrolet Montana',               'Brazilian Series',   3500000,   7000000, 0.70, '2010s'),
    ('lancer_cup',         'Lancer Cup',                      'Brazilian Series',   4000000,   8000000, 0.70, '2010s'),

    -- Open-Wheelers
    ('f_modern',           'Modern Formula',                  'Open-Wheelers',    150000000, 280000000, 2.40, 'Active — F1-spec'),
    ('f_usa',              'Formula USA',                     'Open-Wheelers',     70000000, 130000000, 1.80, '1990s, 2000s — CART/IndyCar'),
    ('f_90s',              '90s Formula',                     'Open-Wheelers',    100000000, 180000000, 2.00, '1990s F1'),
    ('f_80s',              '80s Formula',                     'Open-Wheelers',     70000000, 140000000, 1.80, '1980s F1'),
    ('f_70s',              '70s Formula',                     'Open-Wheelers',     50000000, 100000000, 1.60, '1970s F1'),
    ('f_60s',              '60s Formula',                     'Open-Wheelers',     30000000,  70000000, 1.40, '1960s F1'),
    ('f_junior',           'Formula Junior',                  'Open-Wheelers',      8000000,  18000000, 0.90, 'Active'),
    ('f_trainers',         'Formula Trainers',                'Open-Wheelers',      8000000,  18000000, 0.90, 'Active'),

    -- Spec Racing
    ('carrera_cup',        'Carrera Cup',                     'Spec Racing',       25000000,  40000000, 1.10, 'Active — Porsche one-make'),
    ('ginetta_cups',       'Ginetta Cups',                    'Spec Racing',        8000000,  18000000, 0.80, 'Active'),
    ('m1_procar',          'BMW M1 Procar',                   'Spec Racing',       35000000,  60000000, 1.30, '1970s, 1980s'),

    -- Touring Cars
    ('gr_a_de',            'German Group A (DTM)',            'Touring Cars',      20000000,  40000000, 1.10, '1990s DTM'),
    ('vintage_tc',         'Vintage Touring Cars',            'Touring Cars',       6000000,  15000000, 0.70, '1960s, 1970s'),
    ('super_v8',           'Super V8 (Gen2 ZB)',              'Touring Cars',      18000000,  35000000, 1.00, 'Australian Supercar class'),
    ('mini_jcw',           'Mini Cooper JCW',                 'Touring Cars',       4500000,   8000000, 0.70, 'Active spec series'),

    -- Club Racing
    ('arc_camaro',         'Aussie Racing Camaro',            'Club Racing',        6000000,  12000000, 0.70, 'Active'),
    ('caterhams',          'Caterham Championships',          'Club Racing',        3500000,   8000000, 0.60, 'Active'),
    ('gt5',                'GT5',                             'Club Racing',        8000000,  18000000, 0.80, 'Active'),

    -- Road Cars
    ('tsi_cup',            'TSI Cup',                         'Road Cars',          2500000,   5000000, 0.50, 'Active — VW one-make'),
    ('hypercars',          'Hypercars',                       'Road Cars',         80000000, 180000000, 1.80, 'Road-legal hypercars'),
    ('supercars',          'Supercars',                       'Road Cars',         15000000,  40000000, 1.20, 'Road-legal supercars'),
    ('camaro_ss',          'Camaro SS',                       'Road Cars',          3500000,   6000000, 0.70, 'Single car'),

    -- Karting
    ('kart_125',           '125cc Kart',                      'Karting',             800000,   2000000, 0.40, NULL),
    ('kart_shifter',       '125cc Shifter Kart',              'Karting',            1200000,   2800000, 0.40, NULL),
    ('kart_race',          'GX390 Race Kart',                 'Karting',             600000,   1500000, 0.35, NULL),
    ('kart_rental',        'GX390 Rental Kart',               'Karting',             300000,    800000, 0.30, NULL),
    ('super_kart_250',     '250cc Super Kart',                'Karting',            2000000,   5000000, 0.50, NULL);


COMMIT;
