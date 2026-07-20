-- =========================================================
-- Loop-Ad PostgreSQL Schema Contract v1.11
-- Promotion scheduling, automatic loop execution, and existing execution contracts
-- Owner: loop-ad_data-source_contract
-- Domain: hotel / accommodation booking
--
-- Canonical hierarchy:
--   Campaign -> Promotion -> Segment -> Ad Experiment
--
-- Responsibility boundary:
--   - Dashboard owns ChatKit, natural-language SQL preview, custom segment save,
--     ad serving hot path DB lookup.
--   - Decision writes analysis/generation/ad_experiment/assignment/evaluation results.
--   - Data Source Contract owns this schema.sql.
--
-- Do not duplicate this schema in service repositories.
-- =========================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
DECLARE
    vector_extversion TEXT;
    vector_version_parts INT[];
BEGIN
    SELECT extversion
    INTO vector_extversion
    FROM pg_extension
    WHERE extname = 'vector';

    IF vector_extversion IS NULL THEN
        RAISE EXCEPTION 'pgvector extension is required';
    END IF;

    vector_version_parts := string_to_array(
        regexp_replace(vector_extversion, '[^0-9.].*$', ''),
        '.'
    )::INT[];

    IF vector_version_parts < ARRAY[0, 8, 0] THEN
        RAISE EXCEPTION
            'pgvector >= 0.8.0 is required, found %',
            vector_extversion;
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION is_valid_promotion_run_segment_scope(
    p_segment_scope_json JSONB,
    p_segment_scope_fingerprint TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
    scope_item JSONB;
    segment_id TEXT;
    canonical_scope_json JSONB;
    canonical_scope_serialized TEXT;
BEGIN
    IF jsonb_typeof(p_segment_scope_json) <> 'array'
       OR jsonb_array_length(p_segment_scope_json) = 0 THEN
        RETURN false;
    END IF;

    FOR scope_item IN
        SELECT value
        FROM jsonb_array_elements(p_segment_scope_json) AS scope_items(value)
    LOOP
        IF jsonb_typeof(scope_item) <> 'string' THEN
            RETURN false;
        END IF;

        segment_id := scope_item #>> '{}';
        IF btrim(segment_id) = ''
           OR segment_id <> btrim(segment_id)
           OR segment_id = 'seg_existing_all' THEN
            RETURN false;
        END IF;
    END LOOP;

    SELECT
        jsonb_agg(
            normalized.segment_id
            ORDER BY normalized.segment_id COLLATE "C"
        ),
        '[' || string_agg(
            to_json(normalized.segment_id)::text,
            ',' ORDER BY normalized.segment_id COLLATE "C"
        ) || ']'
    INTO canonical_scope_json, canonical_scope_serialized
    FROM (
        SELECT DISTINCT scope_values.value #>> '{}' AS segment_id
        FROM jsonb_array_elements(p_segment_scope_json) AS scope_values(value)
    ) AS normalized;

    RETURN p_segment_scope_json = canonical_scope_json
       AND p_segment_scope_fingerprint = encode(
            digest(
                convert_to(canonical_scope_serialized, 'UTF8'),
                'sha256'
            ),
            'hex'
       );
END
$$;

-- =========================================================
-- 0. Projects
-- =========================================================
CREATE TABLE IF NOT EXISTS projects (
    project_id VARCHAR(100) PRIMARY KEY,
    project_name VARCHAR(255) NOT NULL,
    domain VARCHAR(255) NOT NULL,
    write_key VARCHAR(255) NOT NULL UNIQUE,
    industry VARCHAR(100) NOT NULL DEFAULT 'hotel_booking',
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_projects_status
        CHECK (status IN ('active', 'inactive', 'archived'))
);

CREATE INDEX IF NOT EXISTS idx_projects_status
ON projects (status);

-- =========================================================
-- 0A. User Behavior Vector Search Generations
-- Frozen PostgreSQL search copies of ClickHouse behavior vectors.
-- =========================================================
CREATE TABLE IF NOT EXISTS user_behavior_vector_search_generations (
    vector_generation_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    vector_version VARCHAR(50) NOT NULL,
    manifest_hash VARCHAR(128) NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    source_revision_cutoff TIMESTAMPTZ NOT NULL,
    expected_user_count INT NOT NULL,
    synced_user_count INT NOT NULL DEFAULT 0,
    invalid_user_count INT NOT NULL DEFAULT 0,
    last_user_id VARCHAR(255),
    status VARCHAR(50) NOT NULL DEFAULT 'in_progress',
    is_active BOOLEAN NOT NULL DEFAULT false,
    failure_reason TEXT,
    activated_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_user_behavior_vector_search_generations_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT chk_user_behavior_vector_search_generations_expected_count
        CHECK (expected_user_count >= 0),

    CONSTRAINT chk_user_behavior_vector_search_generations_synced_count
        CHECK (synced_user_count >= 0),

    CONSTRAINT chk_user_behavior_vector_search_generations_invalid_count
        CHECK (invalid_user_count >= 0),

    CONSTRAINT chk_user_behavior_vector_search_generations_status
        CHECK (status IN ('in_progress', 'activated', 'superseded', 'failed'))
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_behavior_vector_search_generations_active
ON user_behavior_vector_search_generations (project_id, vector_version)
WHERE is_active = true;

CREATE TABLE IF NOT EXISTS user_behavior_vector_search (
    vector_generation_id VARCHAR(100) NOT NULL,
    project_id VARCHAR(100) NOT NULL,
    user_id VARCHAR(255) NOT NULL,
    vector_version VARCHAR(50) NOT NULL,
    vector_dim INT NOT NULL DEFAULT 64,
    embedding vector(64) NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    source_vector_row_id VARCHAR(100) NOT NULL,
    source_updated_at TIMESTAMPTZ NOT NULL,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_user_behavior_vector_search_generation
        FOREIGN KEY (vector_generation_id)
        REFERENCES user_behavior_vector_search_generations (vector_generation_id),

    CONSTRAINT fk_user_behavior_vector_search_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT chk_user_behavior_vector_search_dim
        CHECK (vector_dim = 64),

    CONSTRAINT uq_user_behavior_vector_search_generation_user
        UNIQUE (vector_generation_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_behavior_vector_search_embedding_hnsw
ON user_behavior_vector_search
USING hnsw (embedding vector_cosine_ops);

-- =========================================================
-- 1. Campaigns
-- =========================================================
CREATE TABLE IF NOT EXISTS campaigns (
    campaign_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,

    name VARCHAR(255) NOT NULL,
    objective TEXT,
    target_audience VARCHAR(100) NOT NULL DEFAULT 'existing_users',
    start_date DATE,
    end_date DATE,
    primary_metric VARCHAR(100),
    status VARCHAR(50) NOT NULL DEFAULT 'draft',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_campaigns_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT chk_campaigns_primary_metric
        CHECK (primary_metric IS NULL OR primary_metric IN (
            'inflow_rate',
            'booking_conversion_rate',
            'funnel_step_rate',
            'promotion_click_rate',
            'goal_achievement_rate'
        )),

    CONSTRAINT chk_campaigns_status
        CHECK (status IN ('draft', 'active', 'paused', 'completed', 'stopped')),

    CONSTRAINT chk_campaigns_schedule
        CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date)
);

CREATE INDEX IF NOT EXISTS idx_campaigns_project_id
ON campaigns (project_id);

CREATE INDEX IF NOT EXISTS idx_campaigns_status
ON campaigns (status);

-- =========================================================
-- 2. Promotions
-- =========================================================
CREATE TABLE IF NOT EXISTS promotions (
    promotion_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,

    channel VARCHAR(50) NOT NULL,
    marketing_theme VARCHAR(100) NOT NULL DEFAULT 'summer_sale',
    target_audience VARCHAR(100) NOT NULL DEFAULT 'existing_users',

    goal_metric VARCHAR(100) NOT NULL,
    goal_target_value NUMERIC(10, 6) NOT NULL,
    goal_basis VARCHAR(50) NOT NULL,
    min_sample_size INT NOT NULL DEFAULT 1000,
    max_loop_count INT NOT NULL DEFAULT 3,

    message_brief TEXT,
    offer_type VARCHAR(100),
    landing_url TEXT,
    landing_type VARCHAR(50),
    budget_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    status VARCHAR(50) NOT NULL DEFAULT 'draft',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Promotion automation columns are appended to preserve the physical
    -- column order across fresh and expanded databases.
    execution_mode VARCHAR(20) NOT NULL DEFAULT 'manual',
    scheduled_start_at TIMESTAMPTZ,
    scheduled_end_at TIMESTAMPTZ,
    loop_interval_unit VARCHAR(20) NOT NULL DEFAULT 'day',
    loop_interval_value INT NOT NULL DEFAULT 1,

    CONSTRAINT fk_promotions_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_promotions_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT chk_promotions_channel
        CHECK (channel IN ('email', 'sms', 'onsite_banner')),

    CONSTRAINT chk_promotions_goal_metric
        CHECK (goal_metric IN ('inflow_rate', 'booking_conversion_rate', 'funnel_step_rate')),

    CONSTRAINT chk_promotions_goal_basis
        CHECK (goal_basis IN ('promotion_average', 'all_segments')),

    CONSTRAINT chk_promotions_landing_type
        CHECK (landing_type IS NULL OR landing_type IN (
            'search_page',
            'hotel_detail_page',
            'booking_resume'
        )),

    CONSTRAINT chk_promotions_status
        CHECK (status IN (
            'draft',
            'analysis_ready',
            'content_ready',
            'approved',
            'running',
            'evaluating',
            'partial_goal_met',
            'goal_met',
            'goal_not_met',
            'stopped'
        )),

    CONSTRAINT chk_promotions_sample_size
        CHECK (min_sample_size >= 0),

    CONSTRAINT chk_promotions_max_loop_count
        CHECK (max_loop_count >= 1),

    CONSTRAINT chk_promotions_execution_mode
        CHECK (execution_mode IN ('manual', 'automatic')),

    CONSTRAINT chk_promotions_schedule
        CHECK (
            scheduled_start_at IS NULL
            OR scheduled_end_at IS NULL
            OR scheduled_end_at > scheduled_start_at
        ),

    CONSTRAINT chk_promotions_loop_interval_unit
        CHECK (loop_interval_unit IN ('hour', 'day')),

    CONSTRAINT chk_promotions_loop_interval_value
        CHECK (loop_interval_value >= 1),

    CONSTRAINT chk_promotions_goal_target_value
        CHECK (goal_target_value >= 0)
);

CREATE INDEX IF NOT EXISTS idx_promotions_project_id
ON promotions (project_id);

CREATE INDEX IF NOT EXISTS idx_promotions_campaign_id
ON promotions (campaign_id);

CREATE INDEX IF NOT EXISTS idx_promotions_status
ON promotions (status);

CREATE INDEX IF NOT EXISTS idx_promotions_channel
ON promotions (channel);

CREATE OR REPLACE FUNCTION loopad_campaign_start_at(p_start_date DATE)
RETURNS TIMESTAMPTZ
LANGUAGE SQL
STABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
    SELECT p_start_date::timestamp AT TIME ZONE 'Asia/Seoul'
$$;

CREATE OR REPLACE FUNCTION loopad_campaign_end_at(p_end_date DATE)
RETURNS TIMESTAMPTZ
LANGUAGE SQL
STABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
    SELECT (p_end_date + 1)::timestamp AT TIME ZONE 'Asia/Seoul'
$$;

CREATE OR REPLACE FUNCTION enforce_promotion_campaign_schedule()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    campaign_start_at TIMESTAMPTZ;
    campaign_end_at TIMESTAMPTZ;
BEGIN
    SELECT
        loopad_campaign_start_at(c.start_date),
        loopad_campaign_end_at(c.end_date)
    INTO campaign_start_at, campaign_end_at
    FROM campaigns c
    WHERE c.project_id = NEW.project_id
      AND c.campaign_id = NEW.campaign_id;

    IF NOT FOUND THEN
        RAISE foreign_key_violation
            USING MESSAGE = 'promotion project and campaign must reference the same campaign';
    END IF;

    IF campaign_start_at IS NOT NULL
       AND NEW.scheduled_start_at IS NOT NULL
       AND NEW.scheduled_start_at < campaign_start_at THEN
        RAISE check_violation
            USING MESSAGE = 'promotion start must be within the campaign schedule',
                  CONSTRAINT = 'chk_promotions_campaign_schedule';
    END IF;

    IF campaign_end_at IS NOT NULL
       AND NEW.scheduled_start_at IS NOT NULL
       AND NEW.scheduled_start_at >= campaign_end_at THEN
        RAISE check_violation
            USING MESSAGE = 'promotion start must be before the campaign end',
                  CONSTRAINT = 'chk_promotions_campaign_schedule';
    END IF;

    IF campaign_start_at IS NOT NULL
       AND NEW.scheduled_end_at IS NOT NULL
       AND NEW.scheduled_end_at <= campaign_start_at THEN
        RAISE check_violation
            USING MESSAGE = 'promotion end must be after the campaign start',
                  CONSTRAINT = 'chk_promotions_campaign_schedule';
    END IF;

    IF campaign_end_at IS NOT NULL
       AND NEW.scheduled_end_at IS NOT NULL
       AND NEW.scheduled_end_at > campaign_end_at THEN
        RAISE check_violation
            USING MESSAGE = 'promotion end must be within the campaign schedule',
                  CONSTRAINT = 'chk_promotions_campaign_schedule';
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION enforce_campaign_promotion_schedules()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    conflicting_promotion_id VARCHAR(100);
    campaign_start_at TIMESTAMPTZ := loopad_campaign_start_at(NEW.start_date);
    campaign_end_at TIMESTAMPTZ := loopad_campaign_end_at(NEW.end_date);
BEGIN
    IF NEW.start_date IS NOT DISTINCT FROM OLD.start_date
       AND NEW.end_date IS NOT DISTINCT FROM OLD.end_date THEN
        RETURN NEW;
    END IF;

    SELECT p.promotion_id
    INTO conflicting_promotion_id
    FROM promotions p
    WHERE p.project_id = NEW.project_id
      AND p.campaign_id = NEW.campaign_id
      AND p.status <> 'stopped'
      AND (
          (
              campaign_start_at IS NOT NULL
              AND p.scheduled_start_at IS NOT NULL
              AND p.scheduled_start_at < campaign_start_at
          )
          OR (
              campaign_end_at IS NOT NULL
              AND p.scheduled_start_at IS NOT NULL
              AND p.scheduled_start_at >= campaign_end_at
          )
          OR (
              campaign_start_at IS NOT NULL
              AND p.scheduled_end_at IS NOT NULL
              AND p.scheduled_end_at <= campaign_start_at
          )
          OR (
              campaign_end_at IS NOT NULL
              AND p.scheduled_end_at IS NOT NULL
              AND p.scheduled_end_at > campaign_end_at
          )
      )
    ORDER BY p.promotion_id
    LIMIT 1;

    IF conflicting_promotion_id IS NOT NULL THEN
        RAISE check_violation
            USING MESSAGE = format(
                      'campaign schedule conflicts with promotion %s',
                      conflicting_promotion_id
                  ),
                  CONSTRAINT = 'chk_campaigns_promotion_schedules';
    END IF;

    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_promotions_campaign_schedule ON promotions;
CREATE TRIGGER trg_promotions_campaign_schedule
BEFORE INSERT OR UPDATE OF project_id, campaign_id, scheduled_start_at, scheduled_end_at
ON promotions
FOR EACH ROW
EXECUTE FUNCTION enforce_promotion_campaign_schedule();

DROP TRIGGER IF EXISTS trg_campaigns_promotion_schedules ON campaigns;
CREATE TRIGGER trg_campaigns_promotion_schedules
BEFORE UPDATE OF start_date, end_date
ON campaigns
FOR EACH ROW
EXECUTE FUNCTION enforce_campaign_promotion_schedules();

-- =========================================================
-- 3. Segment Query Previews
-- Dashboard-owned natural language -> SQL preview results.
-- =========================================================
CREATE TABLE IF NOT EXISTS segment_query_previews (
    query_preview_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,

    created_by VARCHAR(100),
    natural_language_query TEXT NOT NULL,
    generated_sql TEXT NOT NULL,
    query_params_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    base_time_from TIMESTAMPTZ,
    base_time_to TIMESTAMPTZ,

    sample_size INT NOT NULL DEFAULT 0,
    total_eligible_user_count INT NOT NULL DEFAULT 0,
    sample_ratio NUMERIC(10, 6) NOT NULL DEFAULT 0,
    sample_size_status VARCHAR(50) NOT NULL,

    result_columns_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    result_preview_json JSONB NOT NULL DEFAULT '[]'::jsonb,

    status VARCHAR(50) NOT NULL DEFAULT 'previewed',
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_query_previews_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT chk_segment_query_preview_status
        CHECK (status IN ('previewed', 'saved', 'rejected', 'failed')),

    CONSTRAINT chk_segment_query_preview_sample_status
        CHECK (sample_size_status IN ('valid', 'too_small', 'too_large', 'failed')),

    CONSTRAINT chk_segment_query_preview_sample_size
        CHECK (sample_size >= 0),

    CONSTRAINT chk_segment_query_preview_total
        CHECK (total_eligible_user_count >= 0),

    CONSTRAINT chk_segment_query_preview_ratio
        CHECK (sample_ratio >= 0)
);

CREATE INDEX IF NOT EXISTS idx_segment_query_previews_project_id
ON segment_query_previews (project_id);

CREATE INDEX IF NOT EXISTS idx_segment_query_previews_created_at
ON segment_query_previews (created_at);

CREATE INDEX IF NOT EXISTS idx_segment_query_previews_sample_status
ON segment_query_previews (sample_size_status);

-- =========================================================
-- 4. Segment Definitions
-- Dashboard saves custom segments here. Decision reads this table.
-- =========================================================
CREATE TABLE IF NOT EXISTS segment_definitions (
    segment_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100),
    campaign_id VARCHAR(100),
    promotion_id VARCHAR(100),

    segment_name VARCHAR(255) NOT NULL,
    source VARCHAR(50) NOT NULL,
    query_preview_id VARCHAR(100),

    natural_language_query TEXT,
    generated_sql TEXT,
    rule_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    profile_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    sample_size INT NOT NULL DEFAULT 0,
    total_eligible_user_count INT NOT NULL DEFAULT 0,
    sample_ratio NUMERIC(10, 6) NOT NULL DEFAULT 0,

    status VARCHAR(50) NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_definitions_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_segment_definitions_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_segment_definitions_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_segment_definitions_query_preview
        FOREIGN KEY (query_preview_id) REFERENCES segment_query_previews (query_preview_id),

    CONSTRAINT chk_segment_definitions_source
        CHECK (source IN ('ai_suggested', 'custom_chatkit', 'manual_rule', 'system_default')),

    CONSTRAINT chk_segment_definitions_status
        CHECK (status IN ('active', 'archived')),

    CONSTRAINT chk_segment_definitions_sample_size
        CHECK (sample_size >= 0),

    CONSTRAINT chk_segment_definitions_total
        CHECK (total_eligible_user_count >= 0),

    CONSTRAINT chk_segment_definitions_ratio
        CHECK (sample_ratio >= 0),

    CONSTRAINT chk_segment_definitions_scope
        CHECK (
            promotion_id IS NULL
            OR campaign_id IS NOT NULL
        ),

    CONSTRAINT chk_segment_definitions_project_scope
        CHECK (
            (
                segment_id = 'seg_existing_all'
                AND project_id IS NULL
                AND campaign_id IS NULL
                AND promotion_id IS NULL
                AND query_preview_id IS NULL
                AND source = 'system_default'
            )
            OR (
                segment_id <> 'seg_existing_all'
                AND project_id IS NOT NULL
            )
        )
);

-- The fallback segment is a global system identity shared by every project.
-- Keep ordinary segments project-scoped while allowing this one FK target to
-- survive project deletion and fresh databases without fixture data.
INSERT INTO segment_definitions (
    segment_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_name,
    source,
    query_preview_id,
    natural_language_query,
    generated_sql,
    rule_json,
    profile_json,
    sample_size,
    total_eligible_user_count,
    sample_ratio,
    status
)
VALUES (
    'seg_existing_all',
    NULL,
    NULL,
    NULL,
    'All existing users',
    'system_default',
    NULL,
    NULL,
    NULL,
    '{"type": "all_existing_users"}'::jsonb,
    '{"description": "Global fallback for all existing users."}'::jsonb,
    0,
    0,
    0,
    'active'
)
ON CONFLICT (segment_id) DO UPDATE SET
    project_id = NULL,
    campaign_id = NULL,
    promotion_id = NULL,
    segment_name = EXCLUDED.segment_name,
    source = EXCLUDED.source,
    query_preview_id = NULL,
    natural_language_query = NULL,
    generated_sql = NULL,
    rule_json = EXCLUDED.rule_json,
    profile_json = EXCLUDED.profile_json,
    sample_size = EXCLUDED.sample_size,
    total_eligible_user_count = EXCLUDED.total_eligible_user_count,
    sample_ratio = EXCLUDED.sample_ratio,
    status = EXCLUDED.status,
    updated_at = now();

CREATE INDEX IF NOT EXISTS idx_segment_definitions_project_id
ON segment_definitions (project_id);

CREATE INDEX IF NOT EXISTS idx_segment_definitions_campaign_id
ON segment_definitions (campaign_id);

CREATE INDEX IF NOT EXISTS idx_segment_definitions_promotion_id
ON segment_definitions (promotion_id);

CREATE INDEX IF NOT EXISTS idx_segment_definitions_source
ON segment_definitions (source);

CREATE INDEX IF NOT EXISTS idx_segment_definitions_status
ON segment_definitions (status);

CREATE INDEX IF NOT EXISTS idx_segment_definitions_query_preview_id
ON segment_definitions (query_preview_id);

-- =========================================================
-- 5. Funnel Definitions / Steps
-- Dashboard-owned funnel setup.
-- =========================================================
CREATE TABLE IF NOT EXISTS funnel_definitions (
    funnel_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100),
    promotion_id VARCHAR(100),

    funnel_name VARCHAR(255) NOT NULL,
    domain_type VARCHAR(100) NOT NULL DEFAULT 'hotel_booking',
    channel VARCHAR(50),
    landing_type VARCHAR(50),
    status VARCHAR(50) NOT NULL DEFAULT 'active',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_funnel_definitions_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_funnel_definitions_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_funnel_definitions_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT chk_funnel_definitions_channel
        CHECK (channel IS NULL OR channel IN ('email', 'sms', 'onsite_banner')),

    CONSTRAINT chk_funnel_definitions_landing_type
        CHECK (landing_type IS NULL OR landing_type IN (
            'search_page',
            'hotel_detail_page',
            'booking_resume'
        )),

    CONSTRAINT chk_funnel_definitions_status
        CHECK (status IN ('active', 'archived'))
);

CREATE INDEX IF NOT EXISTS idx_funnel_definitions_project_id
ON funnel_definitions (project_id);

CREATE INDEX IF NOT EXISTS idx_funnel_definitions_campaign_id
ON funnel_definitions (campaign_id);

CREATE INDEX IF NOT EXISTS idx_funnel_definitions_promotion_id
ON funnel_definitions (promotion_id);

CREATE TABLE IF NOT EXISTS funnel_steps (
    id BIGSERIAL PRIMARY KEY,
    funnel_id VARCHAR(100) NOT NULL,
    step_order INT NOT NULL,
    step_name VARCHAR(255) NOT NULL,
    event_name VARCHAR(100) NOT NULL,
    condition_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_funnel_steps_funnel
        FOREIGN KEY (funnel_id) REFERENCES funnel_definitions (funnel_id),

    CONSTRAINT chk_funnel_steps_order
        CHECK (step_order >= 1),

    CONSTRAINT chk_funnel_steps_event_name
        CHECK (event_name IN (
            'page_view',
            'promotion_impression',
            'promotion_click',
            'campaign_redirect_click',
            'campaign_landing',
            'hotel_search',
            'hotel_click',
            'hotel_detail_view',
            'booking_start',
            'booking_complete',
            'booking_cancel'
        )),

    CONSTRAINT uq_funnel_steps_order
        UNIQUE (funnel_id, step_order)
);

CREATE INDEX IF NOT EXISTS idx_funnel_steps_funnel_id
ON funnel_steps (funnel_id);

CREATE INDEX IF NOT EXISTS idx_funnel_steps_event_name
ON funnel_steps (event_name);

-- =========================================================
-- 6. ChatKit persistence
-- Dashboard-owned ChatKit session/action storage.
-- =========================================================
CREATE TABLE IF NOT EXISTS ai_chat_sessions (
    chat_session_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    user_id VARCHAR(100),
    chatkit_thread_id VARCHAR(255),
    context_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_ai_chat_sessions_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT chk_ai_chat_sessions_status
        CHECK (status IN ('active', 'closed', 'failed'))
);

CREATE INDEX IF NOT EXISTS idx_ai_chat_sessions_project_id
ON ai_chat_sessions (project_id);

CREATE INDEX IF NOT EXISTS idx_ai_chat_sessions_thread_id
ON ai_chat_sessions (chatkit_thread_id);

CREATE TABLE IF NOT EXISTS ai_chat_messages (
    id BIGSERIAL PRIMARY KEY,
    chat_session_id VARCHAR(100) NOT NULL,
    role VARCHAR(50) NOT NULL,
    content TEXT NOT NULL,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_ai_chat_messages_session
        FOREIGN KEY (chat_session_id) REFERENCES ai_chat_sessions (chat_session_id),

    CONSTRAINT chk_ai_chat_messages_role
        CHECK (role IN ('system', 'user', 'assistant', 'tool'))
);

CREATE INDEX IF NOT EXISTS idx_ai_chat_messages_session_id
ON ai_chat_messages (chat_session_id);

CREATE INDEX IF NOT EXISTS idx_ai_chat_messages_created_at
ON ai_chat_messages (created_at);

CREATE TABLE IF NOT EXISTS ai_action_runs (
    action_run_id VARCHAR(100) PRIMARY KEY,
    chat_session_id VARCHAR(100),
    project_id VARCHAR(100) NOT NULL,
    action_type VARCHAR(100) NOT NULL,
    input_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    output_json JSONB,
    requires_confirmation BOOLEAN NOT NULL DEFAULT false,
    confirmed_at TIMESTAMPTZ,
    status VARCHAR(50) NOT NULL DEFAULT 'requested',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_ai_action_runs_session
        FOREIGN KEY (chat_session_id) REFERENCES ai_chat_sessions (chat_session_id),

    CONSTRAINT fk_ai_action_runs_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT chk_ai_action_runs_type
        CHECK (action_type IN (
            'query_segment',
            'create_segment_definition',
            'explain_segment_result',
            'generate_content_for_segment',
            'start_next_loop',
            'explain_experiment_result',
            'create_funnel_definition'
        )),

    CONSTRAINT chk_ai_action_runs_status
        CHECK (status IN ('requested', 'waiting_confirmation', 'confirmed', 'running', 'completed', 'failed', 'cancelled'))
);

CREATE INDEX IF NOT EXISTS idx_ai_action_runs_project_id
ON ai_action_runs (project_id);

CREATE INDEX IF NOT EXISTS idx_ai_action_runs_session_id
ON ai_action_runs (chat_session_id);

CREATE INDEX IF NOT EXISTS idx_ai_action_runs_status
ON ai_action_runs (status);

-- =========================================================
-- 7. Promotion Analyses
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_analyses (
    analysis_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,

    focus_segment_ids_json JSONB,
    operator_instruction TEXT,
    input_snapshot_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    profile_summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    output_json JSONB,

    status VARCHAR(50) NOT NULL DEFAULT 'requested',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_promotion_analyses_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_promotion_analyses_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_promotion_analyses_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT chk_promotion_analyses_status
        CHECK (status IN ('requested', 'running', 'completed', 'failed')),

    CONSTRAINT uq_promotion_analyses_promotion_identity
        UNIQUE (analysis_id, promotion_id)
);

CREATE INDEX IF NOT EXISTS idx_promotion_analyses_project_id
ON promotion_analyses (project_id);

CREATE INDEX IF NOT EXISTS idx_promotion_analyses_campaign_id
ON promotion_analyses (campaign_id);

CREATE INDEX IF NOT EXISTS idx_promotion_analyses_promotion_id
ON promotion_analyses (promotion_id);

CREATE INDEX IF NOT EXISTS idx_promotion_analyses_status
ON promotion_analyses (status);

-- =========================================================
-- 8. Promotion Segment Suggestions
-- AI-proposed segment candidates for a specific promotion analysis.
-- These are proposals, not final confirmed target segments.
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_segment_suggestions (
    suggestion_id VARCHAR(100) PRIMARY KEY,

    analysis_id VARCHAR(100) NOT NULL,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,

    suggested_rank INT NOT NULL,
    suggestion_source VARCHAR(50) NOT NULL DEFAULT 'ai_generated',
    status VARCHAR(50) NOT NULL DEFAULT 'suggested',

    score_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    reason_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_at TIMESTAMPTZ,
    audience_snapshot_id VARCHAR(100),

    CONSTRAINT fk_promotion_segment_suggestions_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT fk_promotion_segment_suggestions_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_promotion_segment_suggestions_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_promotion_segment_suggestions_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_promotion_segment_suggestions_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT chk_promotion_segment_suggestions_source
        CHECK (suggestion_source IN ('ai_generated', 'ai_ranked_existing')),

    CONSTRAINT chk_promotion_segment_suggestions_status
        CHECK (status IN ('suggested', 'accepted', 'dismissed', 'confirmed')),

    CONSTRAINT chk_promotion_segment_suggestions_rank
        CHECK (suggested_rank >= 1),

    CONSTRAINT uq_promotion_segment_suggestions_analysis_segment
        UNIQUE (analysis_id, segment_id)
);

CREATE INDEX IF NOT EXISTS idx_promotion_segment_suggestions_analysis_id
ON promotion_segment_suggestions (analysis_id);

CREATE INDEX IF NOT EXISTS idx_promotion_segment_suggestions_promotion_id
ON promotion_segment_suggestions (promotion_id);

CREATE INDEX IF NOT EXISTS idx_promotion_segment_suggestions_status
ON promotion_segment_suggestions (status);

-- =========================================================
-- 9. Generation Runs
-- =========================================================
CREATE TABLE IF NOT EXISTS generation_runs (
    generation_id VARCHAR(100) PRIMARY KEY,
    analysis_id VARCHAR(100) NOT NULL,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,

    content_option_count INT NOT NULL DEFAULT 3,
    operator_instruction TEXT,
    input_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    output_json JSONB,
    generation_report_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    status VARCHAR(50) NOT NULL DEFAULT 'requested',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Generation v1 columns are appended to preserve the legacy physical
    -- column order across fresh and expanded databases.
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    retry_count INT NOT NULL DEFAULT 0,
    next_retry_at TIMESTAMPTZ,
    last_error_code VARCHAR(100),
    last_error_message TEXT,
    worker_id VARCHAR(200),
    lease_token UUID,
    heartbeat_at TIMESTAMPTZ,
    lease_expires_at TIMESTAMPTZ,
    idempotency_key VARCHAR(200),
    request_fingerprint CHAR(64),

    CONSTRAINT fk_generation_runs_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT fk_generation_runs_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_generation_runs_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_generation_runs_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT chk_generation_runs_status
        CHECK (status IN ('requested', 'running', 'completed', 'failed')),

    CONSTRAINT chk_generation_runs_option_count
        CHECK (content_option_count >= 1),

    CONSTRAINT chk_generation_runs_retry_count
        CHECK (retry_count >= 0),

    CONSTRAINT chk_generation_runs_fingerprint
        CHECK (
            request_fingerprint IS NULL
            OR request_fingerprint ~ '^[0-9a-f]{64}$'
        ),

    CONSTRAINT chk_generation_runs_idempotency_fingerprint
        CHECK (
            idempotency_key IS NULL
            OR request_fingerprint IS NOT NULL
        ),

    CONSTRAINT chk_generation_runs_running_lease
        CHECK (
            status <> 'running'
            OR (
                started_at IS NOT NULL
                AND worker_id IS NOT NULL
                AND lease_token IS NOT NULL
                AND heartbeat_at IS NOT NULL
                AND lease_expires_at IS NOT NULL
            )
        ),

    CONSTRAINT chk_generation_runs_terminal_times
        CHECK (
            status NOT IN ('completed', 'failed')
            OR (started_at IS NOT NULL AND finished_at IS NOT NULL)
        ),

    CONSTRAINT chk_generation_runs_nonterminal_finished_at
        CHECK (
            status IN ('completed', 'failed')
            OR finished_at IS NULL
        ),

    CONSTRAINT chk_generation_runs_inactive_lease_cleared
        CHECK (
            status = 'running'
            OR (
                worker_id IS NULL
                AND lease_token IS NULL
                AND heartbeat_at IS NULL
                AND lease_expires_at IS NULL
            )
        ),

    CONSTRAINT chk_generation_runs_retry_schedule
        CHECK (
            next_retry_at IS NULL
            OR status = 'requested'
        )
);

CREATE INDEX IF NOT EXISTS idx_generation_runs_analysis_id
ON generation_runs (analysis_id);

CREATE INDEX IF NOT EXISTS idx_generation_runs_promotion_id
ON generation_runs (promotion_id);

CREATE INDEX IF NOT EXISTS idx_generation_runs_status
ON generation_runs (status);

CREATE UNIQUE INDEX IF NOT EXISTS uq_generation_runs_project_idempotency
ON generation_runs (project_id, idempotency_key)
WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_generation_runs_claimable
ON generation_runs (
    COALESCE(next_retry_at, created_at),
    created_at,
    generation_id
)
WHERE status = 'requested';

CREATE INDEX IF NOT EXISTS idx_generation_runs_expired_lease
ON generation_runs (lease_expires_at)
WHERE status = 'running';

-- =========================================================
-- 10. Content Candidates
-- Segment-specific generated ad content candidates.
-- =========================================================
CREATE TABLE IF NOT EXISTS content_candidates (
    content_id VARCHAR(100) PRIMARY KEY,
    content_option_id VARCHAR(100) NOT NULL,

    generation_id VARCHAR(100) NOT NULL,
    analysis_id VARCHAR(100) NOT NULL,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,

    channel VARCHAR(50) NOT NULL,

    -- email
    subject TEXT,
    preheader TEXT,

    -- email / onsite_banner common
    title TEXT,
    body TEXT,
    cta TEXT,

    -- sms
    message TEXT,

    -- email / onsite_banner image
    image_prompt TEXT,
    image_url TEXT,

    landing_url TEXT,
    generation_prompt TEXT,
    reason_summary TEXT,
    data_evidence_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    message_strategy TEXT,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    status VARCHAR(50) NOT NULL DEFAULT 'draft',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Generation v1 columns are appended to preserve the legacy physical
    -- column order across fresh and expanded databases.
    creative_format VARCHAR(50),
    image_generation_status VARCHAR(50),
    artifact_status VARCHAR(50),
    artifact_storage_key TEXT,
    artifact_public_url TEXT,
    artifact_sha256 CHAR(64),
    artifact_content_type VARCHAR(100),
    artifact_error_code VARCHAR(100),
    artifact_published_at TIMESTAMPTZ,

    CONSTRAINT fk_content_candidates_generation
        FOREIGN KEY (generation_id) REFERENCES generation_runs (generation_id),

    CONSTRAINT fk_content_candidates_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT fk_content_candidates_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_content_candidates_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_content_candidates_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_content_candidates_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT chk_content_candidates_channel
        CHECK (channel IN ('email', 'sms', 'onsite_banner')),

    CONSTRAINT chk_content_candidates_status
        CHECK (status IN ('draft', 'approved', 'rejected', 'active', 'archived')),

    CONSTRAINT chk_content_candidates_creative_format
        CHECK (
            creative_format IS NULL
            OR creative_format IN ('email_html', 'banner_html', 'sms_text')
        ),

    CONSTRAINT chk_content_candidates_channel_format
        CHECK (
            creative_format IS NULL
            OR (channel = 'email' AND creative_format = 'email_html')
            OR (channel = 'onsite_banner' AND creative_format = 'banner_html')
            OR (channel = 'sms' AND creative_format = 'sms_text')
        ),

    CONSTRAINT chk_content_candidates_image_generation_status
        CHECK (
            image_generation_status IS NULL
            OR image_generation_status IN (
                'not_required', 'pending', 'running', 'completed', 'failed'
            )
        ),

    CONSTRAINT chk_content_candidates_artifact_status
        CHECK (
            artifact_status IS NULL
            OR artifact_status IN ('not_required', 'pending', 'published', 'failed')
        ),

    CONSTRAINT chk_content_candidates_channel_lifecycle
        CHECK (
            creative_format IS NULL
            OR image_generation_status IS NULL
            OR artifact_status IS NULL
            OR (
                creative_format = 'sms_text'
                AND image_generation_status = 'not_required'
                AND artifact_status = 'not_required'
            )
            OR (
                creative_format IN ('email_html', 'banner_html')
                AND image_generation_status IN (
                    'pending', 'running', 'completed', 'failed'
                )
                AND artifact_status IN ('pending', 'published', 'failed')
            )
        ),

    CONSTRAINT chk_content_candidates_artifact_sha256
        CHECK (
            artifact_sha256 IS NULL
            OR artifact_sha256 ~ '^[0-9a-f]{64}$'
        ),

    CONSTRAINT chk_content_candidates_completed_image
        CHECK (
            image_generation_status IS DISTINCT FROM 'completed'
            OR image_url IS NOT NULL
        ),

    CONSTRAINT chk_content_candidates_published_artifact
        CHECK (
            artifact_status IS DISTINCT FROM 'published'
            OR (
                artifact_storage_key IS NOT NULL
                AND artifact_public_url IS NOT NULL
                AND artifact_sha256 IS NOT NULL
                AND artifact_content_type IS NOT NULL
                AND artifact_published_at IS NOT NULL
            )
        ),

    CONSTRAINT chk_content_candidates_artifact_error
        CHECK (
            artifact_status IS DISTINCT FROM 'failed'
            OR artifact_error_code IS NOT NULL
        ),

    CONSTRAINT uq_content_candidates_option
        UNIQUE (generation_id, segment_id, content_option_id)
);

CREATE INDEX IF NOT EXISTS idx_content_candidates_generation_id
ON content_candidates (generation_id);

CREATE INDEX IF NOT EXISTS idx_content_candidates_promotion_id
ON content_candidates (promotion_id);

CREATE INDEX IF NOT EXISTS idx_content_candidates_segment_id
ON content_candidates (segment_id);

CREATE INDEX IF NOT EXISTS idx_content_candidates_status
ON content_candidates (status);

CREATE UNIQUE INDEX IF NOT EXISTS uq_content_candidates_one_approved_per_segment
ON content_candidates (generation_id, segment_id)
WHERE status IN ('approved', 'active');

CREATE INDEX IF NOT EXISTS idx_content_candidates_artifact_status
ON content_candidates (generation_id, artifact_status);

-- =========================================================
-- 10A. Generation RAG Retrieval Documents
-- Logical ownership boundary for Generation v1. The shared application role
-- remains unchanged; every retrieval must still hard-filter project_id.
-- =========================================================
CREATE SCHEMA IF NOT EXISTS generation_rag;

CREATE TABLE IF NOT EXISTS generation_rag.retrieval_documents (
    document_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    context_version VARCHAR(100) NOT NULL,

    source_kind VARCHAR(50) NOT NULL,
    source_id VARCHAR(200) NOT NULL,
    source_version VARCHAR(100) NOT NULL,
    chunk_index INT NOT NULL DEFAULT 0,

    s3_key TEXT,
    document_text TEXT NOT NULL DEFAULT '',
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    embedding vector(1024),
    embedding_model VARCHAR(100) NOT NULL,
    embedding_version VARCHAR(100) NOT NULL,
    content_sha256 CHAR(64) NOT NULL,

    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    last_error_code VARCHAR(100),
    last_error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_generation_rag_project
        FOREIGN KEY (project_id) REFERENCES public.projects (project_id),

    CONSTRAINT chk_generation_rag_source_kind
        CHECK (source_kind IN (
            'brand_asset', 'brand_guide', 'historical_creative'
        )),

    CONSTRAINT chk_generation_rag_chunk_index
        CHECK (chunk_index >= 0),

    CONSTRAINT chk_generation_rag_status
        CHECK (status IN ('pending', 'active', 'failed', 'archived')),

    CONSTRAINT chk_generation_rag_active_embedding
        CHECK (status <> 'active' OR embedding IS NOT NULL),

    CONSTRAINT chk_generation_rag_content_sha256
        CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),

    CONSTRAINT uq_generation_rag_source_context_chunk_embedding
        UNIQUE (
            project_id,
            context_version,
            source_kind,
            source_id,
            source_version,
            chunk_index,
            embedding_model,
            embedding_version
        )
);

CREATE INDEX IF NOT EXISTS idx_generation_rag_retrieval_filter
ON generation_rag.retrieval_documents (
    project_id,
    context_version,
    source_kind,
    status,
    embedding_model,
    embedding_version
);

CREATE INDEX IF NOT EXISTS idx_generation_rag_source
ON generation_rag.retrieval_documents (
    project_id,
    source_kind,
    source_id,
    source_version
);

-- =========================================================
-- 11. Promotion Runs
-- Promotion loop grouping. Actual experiments are ad_experiments.
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_runs (
    promotion_run_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    analysis_id VARCHAR(100) NOT NULL,
    generation_id VARCHAR(100) NOT NULL,

    loop_count INT NOT NULL DEFAULT 1,
    status VARCHAR(50) NOT NULL DEFAULT 'planned',
    goal_snapshot_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    segment_scope_json JSONB NOT NULL,
    segment_scope_fingerprint VARCHAR(64) NOT NULL,

    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_promotion_runs_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_promotion_runs_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_promotion_runs_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_promotion_runs_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT fk_promotion_runs_generation
        FOREIGN KEY (generation_id) REFERENCES generation_runs (generation_id),

    CONSTRAINT chk_promotion_runs_status
        CHECK (status IN (
            'planned',
            'approved',
            'running',
            'evaluating',
            'partial_goal_met',
            'goal_met',
            'goal_not_met',
            'insufficient_data',
            'stopped'
        )),

    CONSTRAINT chk_promotion_runs_loop_count
        CHECK (loop_count >= 1),

    CONSTRAINT chk_promotion_runs_segment_scope
        CHECK (is_valid_promotion_run_segment_scope(
            segment_scope_json,
            segment_scope_fingerprint
        )),

    CONSTRAINT uq_promotion_runs_segment_scope
        UNIQUE (
            project_id,
            promotion_id,
            analysis_id,
            generation_id,
            segment_scope_fingerprint,
            loop_count
        )
);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_project_id
ON promotion_runs (project_id);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_campaign_id
ON promotion_runs (campaign_id);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_promotion_id
ON promotion_runs (promotion_id);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_promotion_loop
ON promotion_runs (promotion_id, loop_count);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_status
ON promotion_runs (status);

-- =========================================================
-- 12. Segment Vectors
-- 64-dimensional segment representative vectors managed by Decision logic,
-- DDL managed by Data Source Contract.
-- =========================================================
CREATE TABLE IF NOT EXISTS segment_vectors (
    segment_vector_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100),
    promotion_run_id VARCHAR(100),
    analysis_id VARCHAR(100),

    vector_dim INT NOT NULL DEFAULT 64,
    vector_values JSONB NOT NULL,
    embedding vector(64) NOT NULL,
    vector_version VARCHAR(50) NOT NULL DEFAULT 'v1',
    source VARCHAR(50) NOT NULL DEFAULT 'decision_analysis',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_vectors_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_segment_vectors_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_segment_vectors_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_segment_vectors_promotion_run
        FOREIGN KEY (promotion_run_id) REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_segment_vectors_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT chk_segment_vectors_dim
        CHECK (vector_dim = 64),

    CONSTRAINT chk_segment_vectors_source
        CHECK (source IN (
            'decision_analysis',
            'fixture',
            'manual',
            'batch_profile',
            'behavior_query'
        ))
);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_project_id
ON segment_vectors (project_id);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_segment_id
ON segment_vectors (segment_id);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_promotion_id
ON segment_vectors (promotion_id);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_promotion_run_id
ON segment_vectors (promotion_run_id);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_embedding_hnsw
ON segment_vectors USING hnsw (embedding vector_cosine_ops);

-- =========================================================
-- 12A. Segment Audience Allocation Plans
-- One immutable confirmation action containing one to three segments.
-- =========================================================
CREATE OR REPLACE FUNCTION is_valid_selected_segment_ids_json(
    p_selected_segment_ids_json JSONB
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
    item JSONB;
    segment_id_value TEXT;
    seen_segment_ids TEXT[] := ARRAY[]::TEXT[];
    canonical_segment_ids JSONB;
BEGIN
    IF jsonb_typeof(p_selected_segment_ids_json) <> 'array'
       OR jsonb_array_length(p_selected_segment_ids_json) NOT BETWEEN 1 AND 3 THEN
        RETURN false;
    END IF;

    FOR item IN
        SELECT value
        FROM jsonb_array_elements(p_selected_segment_ids_json) AS items(value)
    LOOP
        IF jsonb_typeof(item) <> 'string' THEN
            RETURN false;
        END IF;

        segment_id_value := item #>> '{}';
        IF btrim(segment_id_value) = ''
           OR segment_id_value <> btrim(segment_id_value)
           OR segment_id_value = ANY(seen_segment_ids) THEN
            RETURN false;
        END IF;

        seen_segment_ids := array_append(seen_segment_ids, segment_id_value);
    END LOOP;

    SELECT jsonb_agg(to_jsonb(value) ORDER BY value COLLATE "C")
    INTO canonical_segment_ids
    FROM unnest(seen_segment_ids) AS values(value);

    RETURN p_selected_segment_ids_json = canonical_segment_ids;
END
$$;

CREATE TABLE IF NOT EXISTS segment_audience_allocation_plans (
    allocation_plan_id UUID PRIMARY KEY,
    promotion_id VARCHAR(100) NOT NULL,
    candidate_batch_analysis_id VARCHAR(100) NOT NULL,
    target_analysis_id VARCHAR(100) NOT NULL,
    selection_fingerprint VARCHAR(128) NOT NULL,
    selected_segment_ids_json JSONB NOT NULL,
    exclusion_revision BIGINT NOT NULL,
    allocation_policy_version VARCHAR(100) NOT NULL,
    allocation_policy_hash VARCHAR(128) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'finalized',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_at TIMESTAMPTZ,
    released_at TIMESTAMPTZ,

    CONSTRAINT fk_segment_audience_allocation_plans_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_segment_audience_allocation_plans_candidate_analysis
        FOREIGN KEY (candidate_batch_analysis_id, promotion_id)
        REFERENCES promotion_analyses (analysis_id, promotion_id),

    CONSTRAINT fk_segment_audience_allocation_plans_target_analysis
        FOREIGN KEY (target_analysis_id, promotion_id)
        REFERENCES promotion_analyses (analysis_id, promotion_id),

    CONSTRAINT chk_segment_audience_allocation_plans_status
        CHECK (status IN ('finalized', 'locked', 'released')),

    CONSTRAINT chk_segment_audience_allocation_plans_identifiers
        CHECK (
            btrim(selection_fingerprint) <> ''
            AND exclusion_revision >= 1
            AND btrim(allocation_policy_version) <> ''
            AND btrim(allocation_policy_hash) <> ''
        ),

    CONSTRAINT chk_segment_audience_allocation_plans_selected_segments
        CHECK (is_valid_selected_segment_ids_json(selected_segment_ids_json)),

    CONSTRAINT chk_segment_audience_allocation_plans_lifecycle
        CHECK (
            (
                status = 'finalized'
                AND locked_at IS NULL
                AND released_at IS NULL
            )
            OR (
                status = 'locked'
                AND locked_at IS NOT NULL
                AND released_at IS NULL
            )
            OR (
                status = 'released'
                AND locked_at IS NULL
                AND released_at IS NOT NULL
            )
        ),

    CONSTRAINT uq_segment_audience_allocation_plans_selection
        UNIQUE (candidate_batch_analysis_id, selection_fingerprint),

    CONSTRAINT uq_segment_audience_allocation_plans_target_identity
        UNIQUE (
            allocation_plan_id,
            target_analysis_id,
            promotion_id
        ),

    CONSTRAINT uq_segment_audience_allocation_plans_status
        UNIQUE (allocation_plan_id, status)
);

CREATE INDEX IF NOT EXISTS idx_segment_audience_allocation_plans_promotion
ON segment_audience_allocation_plans (promotion_id, created_at);

-- =========================================================
-- 12B. Segment Audience Snapshots
-- Source and final audience outputs. Members live only in
-- segment_audience_members.
-- =========================================================
CREATE TABLE IF NOT EXISTS segment_audience_snapshots (
    snapshot_id VARCHAR(100) PRIMARY KEY,
    suggestion_id VARCHAR(100),
    analysis_id VARCHAR(100) NOT NULL,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    segment_vector_id VARCHAR(100) NOT NULL,
    vector_generation_id VARCHAR(100) NOT NULL,

    schema_version VARCHAR(50) NOT NULL,
    vector_version VARCHAR(50) NOT NULL,
    manifest_hash VARCHAR(128) NOT NULL,
    audience_resolution_contract VARCHAR(100) NOT NULL,
    segment_audience_spec_hash VARCHAR(128) NOT NULL,
    query_vector_hash VARCHAR(128) NOT NULL,
    query_compiler_version VARCHAR(100) NOT NULL,
    query_compiler_hash VARCHAR(128) NOT NULL,
    matcher_version VARCHAR(100) NOT NULL,
    search_policy_version VARCHAR(100) NOT NULL,
    calibration_version VARCHAR(100) NOT NULL,
    calibration_hash VARCHAR(128) NOT NULL,
    score_threshold NUMERIC(10, 6) NOT NULL,

    source_cutoff TIMESTAMPTZ NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    eligible_user_count INT NOT NULL,
    behavior_match_count INT NOT NULL,
    final_user_count INT NOT NULL,
    min_sample_size INT NOT NULL,

    audience_status VARCHAR(50) NOT NULL,
    selection_method VARCHAR(50) NOT NULL,
    estimated_recall NUMERIC(10, 6) NOT NULL,
    recall_lower_bound NUMERIC(10, 6) NOT NULL,
    recall_target NUMERIC(10, 6) NOT NULL,
    input_fingerprint VARCHAR(128) NOT NULL,
    meets_min_sample_size BOOLEAN NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'completed',
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    snapshot_kind VARCHAR(50) NOT NULL DEFAULT 'source',
    source_snapshot_id VARCHAR(100),
    allocation_plan_id UUID,

    CONSTRAINT fk_segment_audience_snapshots_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT fk_segment_audience_snapshots_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_segment_audience_snapshots_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_segment_audience_snapshots_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_segment_audience_snapshots_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_segment_audience_snapshots_segment_vector
        FOREIGN KEY (segment_vector_id) REFERENCES segment_vectors (segment_vector_id),

    CONSTRAINT fk_segment_audience_snapshots_vector_generation
        FOREIGN KEY (vector_generation_id)
        REFERENCES user_behavior_vector_search_generations (vector_generation_id),

    CONSTRAINT fk_segment_audience_snapshots_source_identity
        FOREIGN KEY (
            source_snapshot_id,
            project_id,
            campaign_id,
            promotion_id,
            segment_id
        )
        REFERENCES segment_audience_snapshots (
            snapshot_id,
            project_id,
            campaign_id,
            promotion_id,
            segment_id
        ),

    CONSTRAINT fk_segment_audience_snapshots_allocation_plan_identity
        FOREIGN KEY (
            allocation_plan_id,
            analysis_id,
            promotion_id
        )
        REFERENCES segment_audience_allocation_plans (
            allocation_plan_id,
            target_analysis_id,
            promotion_id
        ),

    CONSTRAINT chk_segment_audience_snapshots_eligible_count
        CHECK (eligible_user_count >= 0),

    CONSTRAINT chk_segment_audience_snapshots_behavior_match_count
        CHECK (
            behavior_match_count >= 0
            AND behavior_match_count <= eligible_user_count
        ),

    CONSTRAINT chk_segment_audience_snapshots_final_count
        CHECK (
            final_user_count >= 0
            AND final_user_count <= behavior_match_count
        ),

    CONSTRAINT chk_segment_audience_snapshots_min_sample_size
        CHECK (min_sample_size >= 0),

    CONSTRAINT chk_segment_audience_snapshots_audience_status
        CHECK (audience_status IN (
            'no_eligible_audience',
            'insufficient_sample',
            'targetable'
        )),

    CONSTRAINT chk_segment_audience_snapshots_selection_method
        CHECK (selection_method IN ('exact', 'transition', 'ann', 'exact_fallback')),

    CONSTRAINT chk_segment_audience_snapshots_status
        CHECK (status = 'completed'),

    CONSTRAINT chk_segment_audience_snapshots_kind
        CHECK (snapshot_kind IN ('source', 'final')),

    CONSTRAINT chk_segment_audience_snapshots_allocation_identity
        CHECK (
            (
                snapshot_kind = 'source'
                AND source_snapshot_id IS NULL
                AND allocation_plan_id IS NULL
            )
            OR (
                snapshot_kind = 'final'
                AND source_snapshot_id IS NOT NULL
                AND source_snapshot_id <> snapshot_id
                AND allocation_plan_id IS NOT NULL
            )
        ),

    CONSTRAINT uq_segment_audience_snapshots_identity
        UNIQUE (
            snapshot_id,
            project_id,
            campaign_id,
            promotion_id,
            segment_id
        ),

    CONSTRAINT uq_segment_audience_snapshots_target_binding
        UNIQUE (
            snapshot_id,
            analysis_id,
            promotion_id,
            segment_id,
            allocation_plan_id
        ),

    CONSTRAINT uq_segment_audience_snapshots_plan_segment
        UNIQUE (allocation_plan_id, segment_id)
);

CREATE TABLE IF NOT EXISTS segment_audience_members (
    snapshot_id VARCHAR(100) NOT NULL,
    user_id VARCHAR(255) NOT NULL,
    behavior_fit_score NUMERIC(10, 6),
    retrieval_source VARCHAR(50) NOT NULL,
    retrieval_rank INT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_audience_members_snapshot
        FOREIGN KEY (snapshot_id) REFERENCES segment_audience_snapshots (snapshot_id),

    CONSTRAINT chk_segment_audience_members_score
        CHECK (
            behavior_fit_score IS NULL
            OR (behavior_fit_score >= -1 AND behavior_fit_score <= 1)
        ),

    CONSTRAINT chk_segment_audience_members_retrieval_source
        CHECK (retrieval_source IN ('exact', 'ann')),

    CONSTRAINT chk_segment_audience_members_retrieval_rank
        CHECK (retrieval_rank IS NULL OR retrieval_rank >= 1),

    CONSTRAINT uq_segment_audience_members_snapshot_user
        UNIQUE (snapshot_id, user_id)
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_segment_suggestions'::regclass
          AND conname = 'fk_promotion_segment_suggestions_audience_snapshot'
    ) THEN
        ALTER TABLE promotion_segment_suggestions
            ADD CONSTRAINT fk_promotion_segment_suggestions_audience_snapshot
            FOREIGN KEY (audience_snapshot_id)
            REFERENCES segment_audience_snapshots (snapshot_id);
    END IF;
END
$$;

-- =========================================================
-- 13. Promotion Target Segments
-- Final segments confirmed by the dashboard user for a promotion analysis.
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_target_segments (
    id BIGSERIAL PRIMARY KEY,
    analysis_id VARCHAR(100) NOT NULL,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,

    segment_id VARCHAR(100) NOT NULL,
    segment_name VARCHAR(255) NOT NULL,
    segment_vector_id VARCHAR(100),
    suggestion_id VARCHAR(100),

    rule_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    profile_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    content_brief_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    data_evidence_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    estimated_size INT NOT NULL DEFAULT 0,
    priority VARCHAR(50),
    status VARCHAR(50) NOT NULL DEFAULT 'planned',
    confirmed_by VARCHAR(100),
    confirmed_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    audience_snapshot_id VARCHAR(100),
    allocation_plan_id UUID,
    audience_reservation_state VARCHAR(50),

    CONSTRAINT fk_promotion_target_segments_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT fk_promotion_target_segments_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_promotion_target_segments_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_promotion_target_segments_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_promotion_target_segments_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_promotion_target_segments_vector
        FOREIGN KEY (segment_vector_id) REFERENCES segment_vectors (segment_vector_id),

    CONSTRAINT fk_promotion_target_segments_suggestion
        FOREIGN KEY (suggestion_id)
        REFERENCES promotion_segment_suggestions (suggestion_id),

    CONSTRAINT fk_promotion_target_segments_audience_snapshot
        FOREIGN KEY (audience_snapshot_id)
        REFERENCES segment_audience_snapshots (snapshot_id),

    CONSTRAINT fk_promotion_target_segments_allocation_plan_identity
        FOREIGN KEY (allocation_plan_id, analysis_id, promotion_id)
        REFERENCES segment_audience_allocation_plans (
            allocation_plan_id,
            target_analysis_id,
            promotion_id
        ),

    CONSTRAINT fk_promotion_target_segments_final_snapshot_identity
        FOREIGN KEY (
            audience_snapshot_id,
            analysis_id,
            promotion_id,
            segment_id,
            allocation_plan_id
        )
        REFERENCES segment_audience_snapshots (
            snapshot_id,
            analysis_id,
            promotion_id,
            segment_id,
            allocation_plan_id
        ),

    CONSTRAINT chk_promotion_target_segments_estimated_size
        CHECK (estimated_size >= 0),

    CONSTRAINT chk_promotion_target_segments_priority
        CHECK (priority IS NULL OR priority IN ('low', 'medium', 'high')),

    CONSTRAINT chk_promotion_target_segments_status
        CHECK (status IN (
            'planned',
            'content_ready',
            'approved',
            'running',
            'goal_met',
            'goal_not_met',
            'insufficient_data',
            'stopped'
        )),

    CONSTRAINT chk_promotion_target_segments_reservation_state
        CHECK (
            audience_reservation_state IS NULL
            OR audience_reservation_state IN ('reserved', 'consumed', 'released')
        ),

    CONSTRAINT chk_promotion_target_segments_audience_binding
        CHECK (
            (
                audience_snapshot_id IS NULL
                AND allocation_plan_id IS NULL
                AND audience_reservation_state IS NULL
            )
            OR (
                audience_snapshot_id IS NOT NULL
                AND allocation_plan_id IS NOT NULL
                AND audience_reservation_state IS NOT NULL
            )
        ),

    CONSTRAINT uq_promotion_target_segments_analysis_segment
        UNIQUE (analysis_id, segment_id),

    CONSTRAINT uq_promotion_target_segments_audience_binding
        UNIQUE (
            analysis_id,
            segment_id,
            allocation_plan_id,
            audience_snapshot_id
        )
);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_analysis_id
ON promotion_target_segments (analysis_id);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_promotion_id
ON promotion_target_segments (promotion_id);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_segment_id
ON promotion_target_segments (segment_id);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_suggestion_id
ON promotion_target_segments (suggestion_id);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_allocation_plan_id
ON promotion_target_segments (allocation_plan_id);

-- =========================================================
-- 13A. Promotion Audience Exclusion State
-- PostgreSQL is authoritative. A promotion row is locked and advanced once
-- per confirmation, run binding, or whole-plan release transaction.
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_audience_exclusion_state (
    promotion_id VARCHAR(100) PRIMARY KEY,
    revision BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_promotion_audience_exclusion_state_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT chk_promotion_audience_exclusion_state_revision
        CHECK (revision >= 0)
);

CREATE OR REPLACE FUNCTION advance_promotion_audience_exclusion_revision(
    p_promotion_id VARCHAR(100)
)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    next_revision BIGINT;
BEGIN
    INSERT INTO promotion_audience_exclusion_state (
        promotion_id,
        revision
    ) VALUES (
        p_promotion_id,
        0
    )
    ON CONFLICT (promotion_id) DO NOTHING;

    PERFORM 1
    FROM promotion_audience_exclusion_state
    WHERE promotion_id = p_promotion_id
    FOR UPDATE;

    UPDATE promotion_audience_exclusion_state
    SET revision = revision + 1,
        updated_at = now()
    WHERE promotion_id = p_promotion_id
    RETURNING revision INTO next_revision;

    RETURN next_revision;
END
$$;

CREATE TABLE IF NOT EXISTS promotion_audience_exclusion_members (
    project_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    user_id VARCHAR(255) NOT NULL,
    target_analysis_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    allocation_plan_id UUID NOT NULL,
    final_snapshot_id VARCHAR(100) NOT NULL,
    state VARCHAR(50) NOT NULL,
    revision BIGINT NOT NULL,
    reserved_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    released_at TIMESTAMPTZ,

    CONSTRAINT pk_promotion_audience_exclusion_members
        PRIMARY KEY (project_id, promotion_id, user_id),

    CONSTRAINT fk_promotion_audience_exclusion_members_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_promotion_audience_exclusion_members_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_promotion_audience_exclusion_members_target_binding
        FOREIGN KEY (
            target_analysis_id,
            segment_id,
            allocation_plan_id,
            final_snapshot_id
        )
        REFERENCES promotion_target_segments (
            analysis_id,
            segment_id,
            allocation_plan_id,
            audience_snapshot_id
        ),

    CONSTRAINT chk_promotion_audience_exclusion_members_state
        CHECK (state IN ('reserved', 'consumed', 'released')),

    CONSTRAINT chk_promotion_audience_exclusion_members_revision
        CHECK (revision >= 1),

    CONSTRAINT chk_promotion_audience_exclusion_members_timestamps
        CHECK (
            (
                state = 'reserved'
                AND consumed_at IS NULL
                AND released_at IS NULL
            )
            OR (
                state = 'consumed'
                AND consumed_at IS NOT NULL
                AND released_at IS NULL
            )
            OR (
                state = 'released'
                AND consumed_at IS NULL
                AND released_at IS NOT NULL
            )
        )
);

CREATE INDEX IF NOT EXISTS idx_promotion_audience_exclusion_members_active
ON promotion_audience_exclusion_members (
    project_id,
    promotion_id,
    state,
    user_id
);

CREATE INDEX IF NOT EXISTS idx_promotion_audience_exclusion_members_plan_segment
ON promotion_audience_exclusion_members (
    allocation_plan_id,
    segment_id,
    state
);

CREATE INDEX IF NOT EXISTS idx_promotion_audience_exclusion_members_final_snapshot
ON promotion_audience_exclusion_members (final_snapshot_id);

-- =========================================================
-- 13B. Promotion Run Target Bindings
-- Every binding in a run shares the run row's analysis and generation.
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_run_target_bindings (
    promotion_run_id VARCHAR(100) NOT NULL,
    target_analysis_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    allocation_plan_id UUID NOT NULL,
    final_snapshot_id VARCHAR(100) NOT NULL,
    bound_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_promotion_run_target_bindings
        PRIMARY KEY (promotion_run_id, segment_id),

    CONSTRAINT uq_promotion_run_target_bindings_target
        UNIQUE (target_analysis_id, segment_id),

    CONSTRAINT fk_promotion_run_target_bindings_run
        FOREIGN KEY (promotion_run_id)
        REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_promotion_run_target_bindings_plan
        FOREIGN KEY (allocation_plan_id)
        REFERENCES segment_audience_allocation_plans (allocation_plan_id),

    CONSTRAINT fk_promotion_run_target_bindings_final_snapshot
        FOREIGN KEY (final_snapshot_id)
        REFERENCES segment_audience_snapshots (snapshot_id),

    CONSTRAINT fk_promotion_run_target_bindings_target_binding
        FOREIGN KEY (
            target_analysis_id,
            segment_id,
            allocation_plan_id,
            final_snapshot_id
        )
        REFERENCES promotion_target_segments (
            analysis_id,
            segment_id,
            allocation_plan_id,
            audience_snapshot_id
        )
);

CREATE INDEX IF NOT EXISTS idx_promotion_run_target_bindings_plan
ON promotion_run_target_bindings (allocation_plan_id);

-- =========================================================
-- 13C. Lean Allocation Lifecycle Validation
-- =========================================================
CREATE OR REPLACE FUNCTION enforce_segment_audience_allocation_plan_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'segment audience allocation plans are immutable'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'finalized' THEN
            RAISE EXCEPTION 'new allocation plan must start finalized'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    IF ROW(
        OLD.allocation_plan_id,
        OLD.promotion_id,
        OLD.candidate_batch_analysis_id,
        OLD.target_analysis_id,
        OLD.selection_fingerprint,
        OLD.selected_segment_ids_json,
        OLD.exclusion_revision,
        OLD.allocation_policy_version,
        OLD.allocation_policy_hash,
        OLD.created_at
    ) IS DISTINCT FROM ROW(
        NEW.allocation_plan_id,
        NEW.promotion_id,
        NEW.candidate_batch_analysis_id,
        NEW.target_analysis_id,
        NEW.selection_fingerprint,
        NEW.selected_segment_ids_json,
        NEW.exclusion_revision,
        NEW.allocation_policy_version,
        NEW.allocation_policy_hash,
        NEW.created_at
    ) THEN
        RAISE EXCEPTION 'allocation plan identity is immutable'
            USING ERRCODE = '55000';
    END IF;

    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'finalized'
       AND NEW.status IN ('locked', 'released') THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'invalid allocation plan transition: % -> %',
        OLD.status, NEW.status
        USING ERRCODE = '55000';
END
$$;

CREATE TRIGGER trg_segment_audience_allocation_plan_lifecycle
BEFORE INSERT OR UPDATE OR DELETE
ON segment_audience_allocation_plans
FOR EACH ROW EXECUTE FUNCTION enforce_segment_audience_allocation_plan_lifecycle();

CREATE OR REPLACE FUNCTION enforce_promotion_target_audience_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.allocation_plan_id IS NOT NULL THEN
            RAISE EXCEPTION 'V2 promotion targets are retained after release'
                USING ERRCODE = '55000';
        END IF;
        RETURN OLD;
    END IF;

    IF TG_OP = 'INSERT' OR OLD.allocation_plan_id IS NULL THEN
        IF NEW.allocation_plan_id IS NULL
           OR NEW.audience_reservation_state = 'reserved' THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'new V2 target must start reserved'
            USING ERRCODE = '55000';
    END IF;

    IF ROW(
        OLD.audience_snapshot_id,
        OLD.allocation_plan_id
    ) IS DISTINCT FROM ROW(
        NEW.audience_snapshot_id,
        NEW.allocation_plan_id
    ) THEN
        RAISE EXCEPTION 'V2 target audience binding is immutable'
            USING ERRCODE = '55000';
    END IF;

    IF OLD.audience_reservation_state = NEW.audience_reservation_state THEN
        RETURN NEW;
    END IF;

    IF OLD.audience_reservation_state = 'reserved'
       AND NEW.audience_reservation_state IN ('consumed', 'released') THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'invalid target reservation transition: % -> %',
        OLD.audience_reservation_state,
        NEW.audience_reservation_state
        USING ERRCODE = '55000';
END
$$;

CREATE TRIGGER trg_promotion_target_audience_lifecycle
BEFORE INSERT OR UPDATE OR DELETE
ON promotion_target_segments
FOR EACH ROW EXECUTE FUNCTION enforce_promotion_target_audience_lifecycle();

CREATE OR REPLACE FUNCTION enforce_promotion_audience_exclusion_member_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_revision BIGINT;
    target_project_id VARCHAR(100);
    target_promotion_id VARCHAR(100);
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'promotion audience exclusion members are retained'
            USING ERRCODE = '55000';
    END IF;

    SELECT revision
    INTO current_revision
    FROM promotion_audience_exclusion_state
    WHERE promotion_id = NEW.promotion_id;

    IF current_revision IS NULL OR NEW.revision <> current_revision THEN
        RAISE EXCEPTION
            'member revision % must equal current promotion revision %',
            NEW.revision, current_revision
            USING ERRCODE = '23514';
    END IF;

    SELECT project_id, promotion_id
    INTO target_project_id, target_promotion_id
    FROM promotion_target_segments
    WHERE analysis_id = NEW.target_analysis_id
      AND segment_id = NEW.segment_id;

    IF ROW(NEW.project_id, NEW.promotion_id)
       IS DISTINCT FROM ROW(target_project_id, target_promotion_id) THEN
        RAISE EXCEPTION 'exclusion member target scope mismatch'
            USING ERRCODE = '23514';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.state <> 'reserved' THEN
            RAISE EXCEPTION 'new exclusion member must start reserved'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    IF ROW(OLD.project_id, OLD.promotion_id, OLD.user_id)
       IS DISTINCT FROM ROW(NEW.project_id, NEW.promotion_id, NEW.user_id) THEN
        RAISE EXCEPTION 'exclusion member identity is immutable'
            USING ERRCODE = '55000';
    END IF;

    IF NEW.revision <= OLD.revision THEN
        RAISE EXCEPTION 'exclusion member revision must increase'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.state = 'reserved'
       AND NEW.state IN ('consumed', 'released') THEN
        IF ROW(
            OLD.target_analysis_id,
            OLD.segment_id,
            OLD.allocation_plan_id,
            OLD.final_snapshot_id,
            OLD.reserved_at
        ) IS DISTINCT FROM ROW(
            NEW.target_analysis_id,
            NEW.segment_id,
            NEW.allocation_plan_id,
            NEW.final_snapshot_id,
            NEW.reserved_at
        ) THEN
            RAISE EXCEPTION 'active reservation binding is immutable'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    IF OLD.state = 'released' AND NEW.state = 'reserved' THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'invalid exclusion transition: % -> %',
        OLD.state, NEW.state
        USING ERRCODE = '55000';
END
$$;

CREATE TRIGGER trg_promotion_audience_exclusion_member_lifecycle
BEFORE INSERT OR UPDATE OR DELETE
ON promotion_audience_exclusion_members
FOR EACH ROW EXECUTE FUNCTION enforce_promotion_audience_exclusion_member_lifecycle();

CREATE OR REPLACE FUNCTION prevent_final_audience_member_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_snapshot_id VARCHAR(100);
BEGIN
    affected_snapshot_id := CASE
        WHEN TG_OP = 'DELETE' THEN OLD.snapshot_id
        ELSE NEW.snapshot_id
    END;

    IF EXISTS (
        SELECT 1
        FROM promotion_target_segments
        WHERE audience_snapshot_id = affected_snapshot_id
          AND allocation_plan_id IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'final audience members are immutable after target binding'
            USING ERRCODE = '55000';
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$$;

CREATE TRIGGER trg_final_audience_member_mutation
BEFORE INSERT OR UPDATE OR DELETE
ON segment_audience_members
FOR EACH ROW EXECUTE FUNCTION prevent_final_audience_member_mutation();

CREATE OR REPLACE FUNCTION assert_final_audience_snapshot(
    p_snapshot_id VARCHAR(100)
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    snapshot_row segment_audience_snapshots%ROWTYPE;
    source_kind VARCHAR(50);
    actual_member_count BIGINT;
BEGIN
    SELECT *
    INTO snapshot_row
    FROM segment_audience_snapshots
    WHERE snapshot_id = p_snapshot_id;

    IF NOT FOUND OR snapshot_row.snapshot_kind <> 'final' THEN
        RETURN;
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(snapshot_row.allocation_plan_id::text, 0)
    );

    SELECT snapshot_kind
    INTO source_kind
    FROM segment_audience_snapshots
    WHERE snapshot_id = snapshot_row.source_snapshot_id;

    IF source_kind <> 'source' THEN
        RAISE EXCEPTION 'final snapshot source must be a source snapshot'
            USING ERRCODE = '23514';
    END IF;

    SELECT count(*)
    INTO actual_member_count
    FROM segment_audience_members
    WHERE snapshot_id = snapshot_row.snapshot_id;

    IF actual_member_count <> snapshot_row.final_user_count THEN
        RAISE EXCEPTION
            'final snapshot member count mismatch: expected %, found %',
            snapshot_row.final_user_count, actual_member_count
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT member.user_id
        FROM segment_audience_snapshots AS snapshot
        JOIN segment_audience_members AS member
          ON member.snapshot_id = snapshot.snapshot_id
        WHERE snapshot.allocation_plan_id = snapshot_row.allocation_plan_id
          AND snapshot.snapshot_kind = 'final'
        GROUP BY member.user_id
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'final snapshots in one plan may not overlap'
            USING ERRCODE = '23505';
    END IF;

    RETURN;
END
$$;

CREATE OR REPLACE FUNCTION validate_final_audience_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_TABLE_NAME = 'segment_audience_members' THEN
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
            PERFORM assert_final_audience_snapshot(OLD.snapshot_id);
        END IF;
        IF TG_OP IN ('INSERT', 'UPDATE')
           AND (TG_OP = 'INSERT' OR NEW.snapshot_id <> OLD.snapshot_id) THEN
            PERFORM assert_final_audience_snapshot(NEW.snapshot_id);
        END IF;
    ELSE
        PERFORM assert_final_audience_snapshot(NEW.snapshot_id);
    END IF;

    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER trg_validate_final_audience_snapshot
AFTER INSERT OR UPDATE
ON segment_audience_snapshots
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_final_audience_snapshot();

CREATE CONSTRAINT TRIGGER trg_validate_final_audience_member
AFTER INSERT OR UPDATE OR DELETE
ON segment_audience_members
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_final_audience_snapshot();

CREATE OR REPLACE FUNCTION assert_segment_audience_allocation_plan(
    p_allocation_plan_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    plan_row segment_audience_allocation_plans%ROWTYPE;
    stored_segment_ids JSONB;
BEGIN
    SELECT *
    INTO plan_row
    FROM segment_audience_allocation_plans
    WHERE allocation_plan_id = p_allocation_plan_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT jsonb_agg(to_jsonb(segment_id) ORDER BY segment_id COLLATE "C")
    INTO stored_segment_ids
    FROM promotion_target_segments
    WHERE allocation_plan_id = p_allocation_plan_id;

    IF stored_segment_ids IS DISTINCT FROM plan_row.selected_segment_ids_json THEN
        RAISE EXCEPTION 'allocation plan target set does not match selected segments'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_target_segments AS target
        JOIN segment_audience_snapshots AS snapshot
          ON snapshot.snapshot_id = target.audience_snapshot_id
        WHERE target.allocation_plan_id = p_allocation_plan_id
          AND (
              target.analysis_id <> plan_row.target_analysis_id
              OR target.promotion_id <> plan_row.promotion_id
              OR target.project_id <> snapshot.project_id
              OR target.campaign_id <> snapshot.campaign_id
              OR target.promotion_id <> snapshot.promotion_id
              OR target.segment_id <> snapshot.segment_id
              OR snapshot.snapshot_kind <> 'final'
              OR snapshot.allocation_plan_id <> p_allocation_plan_id
          )
    ) THEN
        RAISE EXCEPTION 'allocation plan target identity mismatch'
            USING ERRCODE = '23514';
    END IF;

    IF plan_row.status = 'finalized' THEN
        IF EXISTS (
            SELECT 1
            FROM promotion_target_segments
            WHERE allocation_plan_id = p_allocation_plan_id
              AND audience_reservation_state <> 'reserved'
        ) OR EXISTS (
            SELECT 1
            FROM promotion_run_target_bindings
            WHERE allocation_plan_id = p_allocation_plan_id
        ) THEN
            RAISE EXCEPTION 'finalized plan must contain only reserved targets'
                USING ERRCODE = '23514';
        END IF;
    ELSIF plan_row.status = 'locked' THEN
        IF NOT EXISTS (
            SELECT 1
            FROM promotion_run_target_bindings
            WHERE allocation_plan_id = p_allocation_plan_id
        ) OR EXISTS (
            SELECT 1
            FROM promotion_target_segments AS target
            WHERE target.allocation_plan_id = p_allocation_plan_id
              AND target.audience_reservation_state <>
                  CASE
                      WHEN EXISTS (
                          SELECT 1
                          FROM promotion_run_target_bindings AS binding
                          WHERE binding.target_analysis_id = target.analysis_id
                            AND binding.segment_id = target.segment_id
                      ) THEN 'consumed'
                      ELSE 'reserved'
                  END
        ) THEN
            RAISE EXCEPTION 'locked plan target states must match run bindings'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        IF EXISTS (
            SELECT 1
            FROM promotion_run_target_bindings
            WHERE allocation_plan_id = p_allocation_plan_id
        ) OR EXISTS (
            SELECT 1
            FROM promotion_target_segments
            WHERE allocation_plan_id = p_allocation_plan_id
              AND audience_reservation_state <> 'released'
        ) THEN
            RAISE EXCEPTION 'released plan must release every unbound target'
                USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM promotion_audience_exclusion_members
            WHERE allocation_plan_id = p_allocation_plan_id
              AND state IN ('reserved', 'consumed')
        ) THEN
            RAISE EXCEPTION 'released plan may not retain active exclusions'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF plan_row.status <> 'released' AND EXISTS (
        SELECT 1
        FROM promotion_target_segments AS target
        JOIN segment_audience_snapshots AS snapshot
          ON snapshot.snapshot_id = target.audience_snapshot_id
        WHERE target.allocation_plan_id = p_allocation_plan_id
          AND (
              SELECT count(*)
              FROM promotion_audience_exclusion_members AS excluded
              WHERE excluded.allocation_plan_id = p_allocation_plan_id
                AND excluded.segment_id = target.segment_id
                AND excluded.final_snapshot_id = target.audience_snapshot_id
                AND excluded.state = target.audience_reservation_state
          ) <> snapshot.final_user_count
    ) THEN
        RAISE EXCEPTION 'allocation plan exclusion member count mismatch'
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION validate_allocation_plan_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_plan_id UUID;
BEGIN
    affected_plan_id := CASE
        WHEN TG_TABLE_NAME = 'segment_audience_allocation_plans' THEN
            CASE WHEN TG_OP = 'DELETE' THEN OLD.allocation_plan_id
                 ELSE NEW.allocation_plan_id END
        ELSE
            CASE WHEN TG_OP = 'DELETE' THEN OLD.allocation_plan_id
                 ELSE NEW.allocation_plan_id END
    END;

    IF affected_plan_id IS NOT NULL THEN
        PERFORM assert_segment_audience_allocation_plan(affected_plan_id);
    END IF;
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER trg_validate_allocation_plan
AFTER INSERT OR UPDATE
ON segment_audience_allocation_plans
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_allocation_plan_trigger();

CREATE CONSTRAINT TRIGGER trg_validate_allocation_target
AFTER INSERT OR UPDATE
ON promotion_target_segments
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_allocation_plan_trigger();

CREATE OR REPLACE FUNCTION prevent_promotion_run_target_binding_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'promotion run target bindings are immutable'
        USING ERRCODE = '55000';
END
$$;

CREATE TRIGGER trg_promotion_run_target_binding_immutable
BEFORE UPDATE OR DELETE
ON promotion_run_target_bindings
FOR EACH ROW EXECUTE FUNCTION prevent_promotion_run_target_binding_mutation();

CREATE OR REPLACE FUNCTION assert_promotion_run_target_bindings(
    p_promotion_run_id VARCHAR(100)
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    run_row promotion_runs%ROWTYPE;
    bound_segment_ids JSONB;
    v2_target_count INT;
BEGIN
    SELECT *
    INTO run_row
    FROM promotion_runs
    WHERE promotion_run_id = p_promotion_run_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT count(*)
    INTO v2_target_count
    FROM promotion_target_segments AS target
    WHERE target.analysis_id = run_row.analysis_id
      AND target.segment_id IN (
          SELECT value #>> '{}'
          FROM jsonb_array_elements(run_row.segment_scope_json) AS items(value)
      )
      AND target.allocation_plan_id IS NOT NULL;

    IF v2_target_count = 0
       AND NOT EXISTS (
           SELECT 1
           FROM promotion_run_target_bindings
           WHERE promotion_run_id = p_promotion_run_id
       ) THEN
        RETURN;
    END IF;

    SELECT jsonb_agg(to_jsonb(segment_id) ORDER BY segment_id COLLATE "C")
    INTO bound_segment_ids
    FROM promotion_run_target_bindings
    WHERE promotion_run_id = p_promotion_run_id;

    IF bound_segment_ids IS DISTINCT FROM run_row.segment_scope_json THEN
        RAISE EXCEPTION 'run binding set must match the run segment scope'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_run_target_bindings AS binding
        JOIN promotion_target_segments AS target
          ON target.analysis_id = binding.target_analysis_id
         AND target.segment_id = binding.segment_id
        JOIN segment_audience_allocation_plans AS plan
          ON plan.allocation_plan_id = binding.allocation_plan_id
        JOIN segment_audience_snapshots AS snapshot
          ON snapshot.snapshot_id = binding.final_snapshot_id
        JOIN generation_runs AS generation
          ON generation.generation_id = run_row.generation_id
        WHERE binding.promotion_run_id = p_promotion_run_id
          AND (
              binding.target_analysis_id <> run_row.analysis_id
              OR target.project_id <> run_row.project_id
              OR target.campaign_id <> run_row.campaign_id
              OR target.promotion_id <> run_row.promotion_id
              OR target.allocation_plan_id <> binding.allocation_plan_id
              OR target.audience_snapshot_id <> binding.final_snapshot_id
              OR target.audience_reservation_state <> 'consumed'
              OR plan.status <> 'locked'
              OR plan.target_analysis_id <> run_row.analysis_id
              OR plan.promotion_id <> run_row.promotion_id
              OR snapshot.snapshot_kind <> 'final'
              OR generation.analysis_id <> run_row.analysis_id
              OR generation.project_id <> run_row.project_id
              OR generation.campaign_id <> run_row.campaign_id
              OR generation.promotion_id <> run_row.promotion_id
          )
    ) THEN
        RAISE EXCEPTION 'run binding identity or lifecycle mismatch'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_run_target_bindings AS binding
        JOIN segment_audience_snapshots AS snapshot
          ON snapshot.snapshot_id = binding.final_snapshot_id
        WHERE binding.promotion_run_id = p_promotion_run_id
          AND (
              SELECT count(*)
              FROM promotion_audience_exclusion_members AS excluded
              WHERE excluded.target_analysis_id = binding.target_analysis_id
                AND excluded.segment_id = binding.segment_id
                AND excluded.allocation_plan_id = binding.allocation_plan_id
                AND excluded.final_snapshot_id = binding.final_snapshot_id
                AND excluded.state = 'consumed'
          ) <> snapshot.final_user_count
    ) THEN
        RAISE EXCEPTION 'run binding consumed member count mismatch'
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION validate_promotion_run_target_bindings_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_run_id VARCHAR(100);
BEGIN
    affected_run_id := CASE
        WHEN TG_OP = 'DELETE' THEN OLD.promotion_run_id
        ELSE NEW.promotion_run_id
    END;
    PERFORM assert_promotion_run_target_bindings(affected_run_id);
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER trg_validate_promotion_run_binding
AFTER INSERT
ON promotion_run_target_bindings
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_promotion_run_target_bindings_trigger();

CREATE CONSTRAINT TRIGGER trg_validate_promotion_run_scope
AFTER INSERT OR UPDATE
ON promotion_runs
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_promotion_run_target_bindings_trigger();

-- Preview combinations are stored in
-- promotion_analyses.output_json->'audience_allocation_preview_context'.
-- No allocation preview relation is created.

-- =========================================================
-- 14. Ad Experiments
-- Segment-level ad experiment. One per segment in a promotion_run.
-- =========================================================
CREATE TABLE IF NOT EXISTS ad_experiments (
    ad_experiment_id VARCHAR(100) PRIMARY KEY,

    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    promotion_run_id VARCHAR(100) NOT NULL,

    analysis_id VARCHAR(100) NOT NULL,
    generation_id VARCHAR(100) NOT NULL,

    segment_id VARCHAR(100) NOT NULL,
    segment_name VARCHAR(255),

    content_id VARCHAR(100) NOT NULL,
    content_option_id VARCHAR(100) NOT NULL,

    parent_ad_experiment_id VARCHAR(100),
    source_evaluation_id VARCHAR(100),

    channel VARCHAR(50) NOT NULL,
    loop_count INT NOT NULL DEFAULT 1,
    status VARCHAR(50) NOT NULL DEFAULT 'planned',

    goal_metric VARCHAR(100) NOT NULL,
    goal_target_value NUMERIC(10, 6) NOT NULL,
    goal_basis VARCHAR(50) NOT NULL,

    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_ad_experiments_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_ad_experiments_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_ad_experiments_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_ad_experiments_promotion_run
        FOREIGN KEY (promotion_run_id) REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_ad_experiments_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT fk_ad_experiments_generation
        FOREIGN KEY (generation_id) REFERENCES generation_runs (generation_id),

    CONSTRAINT fk_ad_experiments_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_ad_experiments_content
        FOREIGN KEY (content_id) REFERENCES content_candidates (content_id),

    CONSTRAINT fk_ad_experiments_parent
        FOREIGN KEY (parent_ad_experiment_id) REFERENCES ad_experiments (ad_experiment_id),

    CONSTRAINT chk_ad_experiments_lineage_pair
        CHECK (
            (parent_ad_experiment_id IS NULL AND source_evaluation_id IS NULL)
            OR
            (parent_ad_experiment_id IS NOT NULL AND source_evaluation_id IS NOT NULL)
        ),

    CONSTRAINT chk_ad_experiments_channel
        CHECK (channel IN ('email', 'sms', 'onsite_banner')),

    CONSTRAINT chk_ad_experiments_status
        CHECK (status IN (
            'planned',
            'approved',
            'running',
            'evaluating',
            'goal_met',
            'goal_not_met',
            'goal_near',
            'insufficient_data',
            'stopped'
        )),

    CONSTRAINT chk_ad_experiments_goal_metric
        CHECK (goal_metric IN ('inflow_rate', 'booking_conversion_rate', 'funnel_step_rate')),

    CONSTRAINT chk_ad_experiments_goal_basis
        CHECK (goal_basis IN ('promotion_average', 'all_segments')),

    CONSTRAINT chk_ad_experiments_loop_count
        CHECK (loop_count >= 1),

    CONSTRAINT chk_ad_experiments_goal_target_value
        CHECK (goal_target_value >= 0),

    CONSTRAINT uq_ad_experiments_segment_per_run
        UNIQUE (promotion_run_id, segment_id)
);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_project_id
ON ad_experiments (project_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_campaign_id
ON ad_experiments (campaign_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_promotion_id
ON ad_experiments (promotion_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_promotion_run_id
ON ad_experiments (promotion_run_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_segment_id
ON ad_experiments (segment_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_status
ON ad_experiments (status);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_parent_ad_experiment_id
ON ad_experiments (parent_ad_experiment_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_source_evaluation_id
ON ad_experiments (source_evaluation_id);

-- =========================================================
-- 15. Promotion Evaluations
-- Stores ad_experiment-level and optional promotion_run aggregate evaluation.
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_evaluations (
    evaluation_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    promotion_run_id VARCHAR(100) NOT NULL,
    ad_experiment_id VARCHAR(100),

    segment_id VARCHAR(100),
    content_id VARCHAR(100),
    content_option_id VARCHAR(100),

    metric VARCHAR(100) NOT NULL,
    target_value NUMERIC(10, 6) NOT NULL,
    actual_value NUMERIC(10, 6) NOT NULL DEFAULT 0,
    numerator_count INT NOT NULL DEFAULT 0,
    denominator_count INT NOT NULL DEFAULT 0,
    sample_size INT NOT NULL DEFAULT 0,
    basis VARCHAR(50) NOT NULL,

    status VARCHAR(50) NOT NULL,
    feedback TEXT,
    next_loop_required BOOLEAN NOT NULL DEFAULT false,
    result_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_promotion_evaluations_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_promotion_evaluations_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_promotion_evaluations_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_promotion_evaluations_run
        FOREIGN KEY (promotion_run_id) REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_promotion_evaluations_ad_experiment
        FOREIGN KEY (ad_experiment_id) REFERENCES ad_experiments (ad_experiment_id),

    CONSTRAINT fk_promotion_evaluations_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_promotion_evaluations_content
        FOREIGN KEY (content_id) REFERENCES content_candidates (content_id),

    CONSTRAINT chk_promotion_evaluations_metric
        CHECK (metric IN ('inflow_rate', 'booking_conversion_rate', 'funnel_step_rate', 'promotion_click_rate')),

    CONSTRAINT chk_promotion_evaluations_basis
        CHECK (basis IN ('promotion_average', 'all_segments')),

    CONSTRAINT chk_promotion_evaluations_status
        CHECK (status IN ('goal_met', 'goal_not_met', 'goal_near', 'partial_goal_met', 'insufficient_data')),

    CONSTRAINT chk_promotion_evaluations_target_value
        CHECK (target_value >= 0),

    CONSTRAINT chk_promotion_evaluations_actual_value
        CHECK (actual_value >= 0),

    CONSTRAINT chk_promotion_evaluations_counts
        CHECK (numerator_count >= 0 AND denominator_count >= 0 AND sample_size >= 0)
);

CREATE INDEX IF NOT EXISTS idx_promotion_evaluations_run_id
ON promotion_evaluations (promotion_run_id);

CREATE INDEX IF NOT EXISTS idx_promotion_evaluations_ad_experiment_id
ON promotion_evaluations (ad_experiment_id);

CREATE INDEX IF NOT EXISTS idx_promotion_evaluations_segment_id
ON promotion_evaluations (segment_id);

CREATE INDEX IF NOT EXISTS idx_promotion_evaluations_status
ON promotion_evaluations (status);

CREATE INDEX IF NOT EXISTS idx_promotion_evaluations_individual_provenance
ON promotion_evaluations (project_id, ad_experiment_id, status)
WHERE ad_experiment_id IS NOT NULL;

ALTER TABLE ad_experiments
    ADD CONSTRAINT fk_ad_experiments_source_evaluation
    FOREIGN KEY (source_evaluation_id) REFERENCES promotion_evaluations (evaluation_id);

-- =========================================================
-- 16. Next-loop Preparations
-- Persists manual next-loop approval attempts before child activation.
-- =========================================================
CREATE TABLE IF NOT EXISTS next_loop_preparations (
    next_loop_preparation_id VARCHAR(100) PRIMARY KEY,
    source_promotion_run_id VARCHAR(100) NOT NULL,
    analysis_id VARCHAR(100) NOT NULL,
    generation_id VARCHAR(100) NOT NULL,

    attempt_no INT NOT NULL,
    failed_segment_ids_json JSONB NOT NULL,
    failed_ad_experiment_ids_json JSONB NOT NULL,
    source_evaluation_ids_json JSONB NOT NULL,

    status VARCHAR(50) NOT NULL,
    activated_promotion_run_id VARCHAR(100),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_next_loop_preparations_source_run
        FOREIGN KEY (source_promotion_run_id) REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_next_loop_preparations_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT fk_next_loop_preparations_generation
        FOREIGN KEY (generation_id) REFERENCES generation_runs (generation_id),

    CONSTRAINT fk_next_loop_preparations_activated_run
        FOREIGN KEY (activated_promotion_run_id) REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT chk_next_loop_preparations_attempt_no
        CHECK (attempt_no >= 1),

    CONSTRAINT chk_next_loop_preparations_failed_segment_ids_json
        CHECK (
            CASE
                WHEN jsonb_typeof(failed_segment_ids_json) = 'array'
                THEN jsonb_array_length(failed_segment_ids_json) > 0
                ELSE false
            END
        ),

    CONSTRAINT chk_next_loop_preparations_failed_ad_experiment_ids_json
        CHECK (
            CASE
                WHEN jsonb_typeof(failed_ad_experiment_ids_json) = 'array'
                THEN jsonb_array_length(failed_ad_experiment_ids_json) > 0
                ELSE false
            END
        ),

    CONSTRAINT chk_next_loop_preparations_source_evaluation_ids_json
        CHECK (
            CASE
                WHEN jsonb_typeof(source_evaluation_ids_json) = 'array'
                THEN jsonb_array_length(source_evaluation_ids_json) > 0
                ELSE false
            END
        ),

    CONSTRAINT chk_next_loop_preparations_status
        CHECK (status IN ('awaiting_content_approval', 'rejected', 'activated')),

    CONSTRAINT chk_next_loop_preparations_activation_pair
        CHECK (
            (status = 'activated' AND activated_promotion_run_id IS NOT NULL)
            OR
            (status IN ('awaiting_content_approval', 'rejected') AND activated_promotion_run_id IS NULL)
        ),

    CONSTRAINT uq_next_loop_preparations_source_attempt
        UNIQUE (source_promotion_run_id, attempt_no)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_next_loop_preparations_awaiting_source_run
ON next_loop_preparations (source_promotion_run_id)
WHERE status = 'awaiting_content_approval';

CREATE UNIQUE INDEX IF NOT EXISTS uq_next_loop_preparations_activated_run
ON next_loop_preparations (activated_promotion_run_id)
WHERE activated_promotion_run_id IS NOT NULL;

-- =========================================================
-- 16a. Promotion Automation Jobs
-- Durable, lease-based launch and evaluation schedule for promotion runs.
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_automation_jobs (
    job_id VARCHAR(100) PRIMARY KEY,
    promotion_run_id VARCHAR(100) NOT NULL,
    job_type VARCHAR(30) NOT NULL,
    scheduled_at TIMESTAMPTZ NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'pending',
    attempt_count INT NOT NULL DEFAULT 0,
    worker_id VARCHAR(200),
    lease_token UUID,
    locked_at TIMESTAMPTZ,
    lease_expires_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    last_error_code VARCHAR(100),
    last_error_detail TEXT,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_promotion_automation_jobs_run
        FOREIGN KEY (promotion_run_id) REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT chk_promotion_automation_jobs_type
        CHECK (job_type IN ('launch_run', 'evaluate_run')),

    CONSTRAINT chk_promotion_automation_jobs_status
        CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),

    CONSTRAINT chk_promotion_automation_jobs_attempt_count
        CHECK (attempt_count >= 0),

    CONSTRAINT chk_promotion_automation_jobs_metadata
        CHECK (jsonb_typeof(metadata_json) = 'object'),

    CONSTRAINT chk_promotion_automation_jobs_running_lease
        CHECK (
            status <> 'running'
            OR (
                worker_id IS NOT NULL
                AND lease_token IS NOT NULL
                AND locked_at IS NOT NULL
                AND lease_expires_at IS NOT NULL
            )
        ),

    CONSTRAINT chk_promotion_automation_jobs_completed_at
        CHECK (
            status <> 'completed'
            OR completed_at IS NOT NULL
        ),

    CONSTRAINT uq_promotion_automation_jobs_run_type
        UNIQUE (promotion_run_id, job_type)
);

CREATE INDEX IF NOT EXISTS idx_promotion_automation_jobs_claimable
ON promotion_automation_jobs (scheduled_at, created_at, job_id)
WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_promotion_automation_jobs_expired_lease
ON promotion_automation_jobs (lease_expires_at)
WHERE status = 'running';

-- =========================================================
-- 17. Segment Assignment Execution Provenance
-- Records the matcher/input contract used by one assignment execution.
-- =========================================================
CREATE TABLE IF NOT EXISTS segment_assignment_executions (
    segment_assignment_execution_id VARCHAR(100) PRIMARY KEY,
    promotion_run_id VARCHAR(100) NOT NULL,
    request_fingerprint VARCHAR(64) NOT NULL,
    input_fingerprint VARCHAR(64) NOT NULL,
    matcher_strategy VARCHAR(100) NOT NULL,
    matcher_version VARCHAR(100) NOT NULL,
    vector_version VARCHAR(50) NOT NULL,
    source_cutoff_at TIMESTAMPTZ NOT NULL,
    input_manifest_json JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_assignment_executions_run
        FOREIGN KEY (promotion_run_id)
        REFERENCES promotion_runs (promotion_run_id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,

    CONSTRAINT chk_segment_assignment_executions_identifiers
        CHECK (
            btrim(segment_assignment_execution_id) <> ''
            AND btrim(promotion_run_id) <> ''
            AND btrim(matcher_strategy) <> ''
            AND btrim(matcher_version) <> ''
            AND btrim(vector_version) <> ''
        ),

    CONSTRAINT chk_segment_assignment_executions_fingerprints
        CHECK (
            request_fingerprint ~ '^[0-9a-f]{64}$'
            AND input_fingerprint ~ '^[0-9a-f]{64}$'
        ),

    CONSTRAINT chk_segment_assignment_executions_input_manifest
        CHECK (jsonb_typeof(input_manifest_json) = 'object'),

    CONSTRAINT uq_segment_assignment_executions_run_request
        UNIQUE (promotion_run_id, request_fingerprint),

    CONSTRAINT uq_segment_assignment_executions_run_execution
        UNIQUE (promotion_run_id, segment_assignment_execution_id)
);

-- =========================================================
-- 18. User Segment Assignments
-- Decision builds these in batch. Dashboard ad serving reads these.
-- =========================================================
CREATE TABLE IF NOT EXISTS user_segment_assignments (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    promotion_run_id VARCHAR(100) NOT NULL,
    user_id VARCHAR(255) NOT NULL,

    segment_id VARCHAR(100) NOT NULL,
    ad_experiment_id VARCHAR(100) NOT NULL,
    content_id VARCHAR(100) NOT NULL,
    content_option_id VARCHAR(100) NOT NULL,

    similarity_score NUMERIC(10, 6),
    fallback BOOLEAN NOT NULL DEFAULT false,
    fallback_reason VARCHAR(50),
    assignment_source VARCHAR(50) NOT NULL DEFAULT 'decision_batch',
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ,
    segment_assignment_execution_id VARCHAR(100),

    CONSTRAINT fk_user_segment_assignments_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_user_segment_assignments_run
        FOREIGN KEY (promotion_run_id) REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_user_segment_assignments_execution
        FOREIGN KEY (
            promotion_run_id,
            segment_assignment_execution_id
        )
        REFERENCES segment_assignment_executions (
            promotion_run_id,
            segment_assignment_execution_id
        )
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,

    CONSTRAINT fk_user_segment_assignments_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_user_segment_assignments_ad_experiment
        FOREIGN KEY (ad_experiment_id) REFERENCES ad_experiments (ad_experiment_id),

    CONSTRAINT fk_user_segment_assignments_content
        FOREIGN KEY (content_id) REFERENCES content_candidates (content_id),

    CONSTRAINT chk_user_segment_assignments_score
        CHECK (similarity_score IS NULL OR (similarity_score >= 0 AND similarity_score <= 1)),

    CONSTRAINT chk_user_segment_assignments_source
        CHECK (assignment_source IN (
            'decision_batch',
            'fallback',
            'manual',
            'fixture',
            'analysis_snapshot'
        )),

    CONSTRAINT chk_user_segment_assignments_fallback_reason
        CHECK (
            (fallback = false AND fallback_reason IS NULL)
            OR
            (
                fallback = true
                AND fallback_reason IS NOT NULL
                AND fallback_reason IN (
                    'below_threshold',
                    'no_candidate',
                    'invalid_user_vector'
                )
            )
        ),

    CONSTRAINT uq_user_segment_assignments_run_user
        UNIQUE (promotion_run_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_project_id
ON user_segment_assignments (project_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_run_id
ON user_segment_assignments (promotion_run_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_execution_id
ON user_segment_assignments (segment_assignment_execution_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_user_id
ON user_segment_assignments (user_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_segment_id
ON user_segment_assignments (segment_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_ad_experiment_id
ON user_segment_assignments (ad_experiment_id);

-- =========================================================
-- 19. Ad Dispatch Jobs
-- Dashboard-owned email/sms dispatch state.
-- =========================================================
CREATE TABLE IF NOT EXISTS ad_dispatch_jobs (
    ad_dispatch_job_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    promotion_run_id VARCHAR(100) NOT NULL,
    ad_experiment_id VARCHAR(100),

    channel VARCHAR(50) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'queued',
    provider VARCHAR(100),

    target_count INT NOT NULL DEFAULT 0,
    sent_count INT NOT NULL DEFAULT 0,
    failed_count INT NOT NULL DEFAULT 0,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT fk_ad_dispatch_jobs_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_ad_dispatch_jobs_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_ad_dispatch_jobs_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_ad_dispatch_jobs_run
        FOREIGN KEY (promotion_run_id) REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_ad_dispatch_jobs_ad_experiment
        FOREIGN KEY (ad_experiment_id) REFERENCES ad_experiments (ad_experiment_id),

    CONSTRAINT chk_ad_dispatch_jobs_channel
        CHECK (channel IN ('email', 'sms', 'onsite_banner')),

    CONSTRAINT chk_ad_dispatch_jobs_status
        CHECK (status IN ('queued', 'scheduled', 'running', 'completed', 'failed', 'cancelled')),

    CONSTRAINT chk_ad_dispatch_jobs_counts
        CHECK (target_count >= 0 AND sent_count >= 0 AND failed_count >= 0)
);

CREATE INDEX IF NOT EXISTS idx_ad_dispatch_jobs_run_id
ON ad_dispatch_jobs (promotion_run_id);

CREATE INDEX IF NOT EXISTS idx_ad_dispatch_jobs_ad_experiment_id
ON ad_dispatch_jobs (ad_experiment_id);

CREATE INDEX IF NOT EXISTS idx_ad_dispatch_jobs_status
ON ad_dispatch_jobs (status);

-- =========================================================
-- 20. Redirect Links
-- Dashboard-owned redirect tracking for email/sms.
-- =========================================================
CREATE TABLE IF NOT EXISTS redirect_links (
    redirect_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    promotion_run_id VARCHAR(100) NOT NULL,
    ad_experiment_id VARCHAR(100) NOT NULL,

    user_id VARCHAR(255) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    content_id VARCHAR(100) NOT NULL,
    content_option_id VARCHAR(100) NOT NULL,

    target_url TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ,

    CONSTRAINT fk_redirect_links_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_redirect_links_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_redirect_links_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_redirect_links_run
        FOREIGN KEY (promotion_run_id) REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_redirect_links_ad_experiment
        FOREIGN KEY (ad_experiment_id) REFERENCES ad_experiments (ad_experiment_id),

    CONSTRAINT fk_redirect_links_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_redirect_links_content
        FOREIGN KEY (content_id) REFERENCES content_candidates (content_id)
);

CREATE INDEX IF NOT EXISTS idx_redirect_links_project_id
ON redirect_links (project_id);

CREATE INDEX IF NOT EXISTS idx_redirect_links_run_id
ON redirect_links (promotion_run_id);

CREATE INDEX IF NOT EXISTS idx_redirect_links_ad_experiment_id
ON redirect_links (ad_experiment_id);

CREATE INDEX IF NOT EXISTS idx_redirect_links_user_id
ON redirect_links (user_id);

-- =========================================================
-- 21. Event Validation Errors
-- Collector/Dashboard can show bad event payloads.
-- =========================================================
CREATE TABLE IF NOT EXISTS event_validation_errors (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(100),
    event_id VARCHAR(100),
    event_name VARCHAR(100),
    error_code VARCHAR(100) NOT NULL,
    error_message TEXT NOT NULL,
    payload_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_event_validation_errors_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id)
);

CREATE INDEX IF NOT EXISTS idx_event_validation_errors_project_id
ON event_validation_errors (project_id);

CREATE INDEX IF NOT EXISTS idx_event_validation_errors_event_name
ON event_validation_errors (event_name);

CREATE INDEX IF NOT EXISTS idx_event_validation_errors_created_at
ON event_validation_errors (created_at);

-- =========================================================
-- 22. Active Ad Serving Assignments View
-- Dashboard ad hot path uses DB/view; it must not call Decision API per request.
-- =========================================================
CREATE OR REPLACE VIEW active_ad_serving_assignments AS
SELECT
    usa.project_id,
    usa.promotion_run_id,
    usa.user_id,
    usa.segment_id,
    usa.ad_experiment_id,
    usa.content_id,
    usa.content_option_id,
    usa.fallback,
    usa.similarity_score,
    usa.assigned_at,
    usa.expires_at,

    ae.campaign_id,
    ae.promotion_id,
    ae.channel,
    ae.loop_count,
    ae.status AS ad_experiment_status,

    cc.subject,
    cc.preheader,
    cc.title,
    cc.body,
    cc.cta,
    cc.message,
    cc.image_prompt,
    cc.image_url,
    cc.landing_url,
    cc.status AS content_status,
    cc.creative_format,
    cc.image_generation_status,
    cc.artifact_status,
    cc.artifact_public_url,
    cc.artifact_content_type
FROM user_segment_assignments usa
JOIN ad_experiments ae
  ON usa.ad_experiment_id = ae.ad_experiment_id
JOIN content_candidates cc
  ON usa.content_id = cc.content_id
JOIN generation_runs gr
  ON cc.generation_id = gr.generation_id
-- Re-evaluation may change the latest evaluation result without changing execution state.
-- Legacy serving therefore requires matching historical provenance, not latest-status equality.
WHERE (
        ae.status IN ('approved', 'running')
        OR
        (
            ae.status IN ('goal_met', 'goal_not_met', 'insufficient_data')
            AND ae.ended_at IS NULL
            AND EXISTS (
                SELECT 1
                FROM promotion_evaluations pe
                WHERE pe.ad_experiment_id IS NOT NULL
                  AND pe.project_id = ae.project_id
                  AND pe.campaign_id = ae.campaign_id
                  AND pe.promotion_id = ae.promotion_id
                  AND pe.promotion_run_id = ae.promotion_run_id
                  AND pe.ad_experiment_id = ae.ad_experiment_id
                  AND pe.status = ae.status
            )
        )
    )
  AND cc.status IN ('approved', 'active')
  AND gr.status = 'completed'
  AND (
        (
            cc.channel = 'sms'
            AND cc.message IS NOT NULL
            AND cc.artifact_status = 'not_required'
        )
        OR
        (
            cc.channel IN ('email', 'onsite_banner')
            AND cc.image_generation_status = 'completed'
            AND cc.image_url IS NOT NULL
            AND cc.artifact_status = 'published'
            AND cc.artifact_public_url IS NOT NULL
        )
      )
  AND (usa.expires_at IS NULL OR usa.expires_at > now());

-- =========================================================
-- 22. SDK Tracking Plans
-- Dashboard-owned draft plans and immutable published revisions.
-- =========================================================
CREATE TABLE IF NOT EXISTS tracking_plans (
    tracking_plan_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    name VARCHAR(255) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'draft',
    current_revision INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_tracking_plans_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT chk_tracking_plans_name
        CHECK (btrim(name) <> ''),

    CONSTRAINT chk_tracking_plans_status
        CHECK (status IN ('draft', 'published', 'archived')),

    CONSTRAINT chk_tracking_plans_current_revision
        CHECK (current_revision >= 0)
);

CREATE INDEX IF NOT EXISTS idx_tracking_plans_project_status
ON tracking_plans (project_id, status);

CREATE TABLE IF NOT EXISTS tracking_plan_revisions (
    tracking_plan_id VARCHAR(100) NOT NULL,
    revision INT NOT NULL,
    schema_json JSONB NOT NULL,
    published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by VARCHAR(100),

    CONSTRAINT pk_tracking_plan_revisions
        PRIMARY KEY (tracking_plan_id, revision),

    CONSTRAINT fk_tracking_plan_revisions_plan
        FOREIGN KEY (tracking_plan_id) REFERENCES tracking_plans (tracking_plan_id),

    CONSTRAINT chk_tracking_plan_revisions_revision
        CHECK (revision >= 1),

    CONSTRAINT chk_tracking_plan_revisions_schema_object
        CHECK (jsonb_typeof(schema_json) = 'object')
);

CREATE INDEX IF NOT EXISTS idx_tracking_plan_revisions_published_at
ON tracking_plan_revisions (tracking_plan_id, published_at DESC);

CREATE OR REPLACE FUNCTION prevent_tracking_plan_revision_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'published tracking plan revisions are immutable';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_tracking_plan_revisions_immutable ON tracking_plan_revisions;
CREATE TRIGGER trg_tracking_plan_revisions_immutable
BEFORE UPDATE OR DELETE ON tracking_plan_revisions
FOR EACH ROW EXECUTE FUNCTION prevent_tracking_plan_revision_mutation();

CREATE TABLE IF NOT EXISTS tracking_plan_events (
    tracking_plan_id VARCHAR(100) NOT NULL,
    event_name VARCHAR(100) NOT NULL,
    description TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'draft',
    properties_schema_json JSONB NOT NULL DEFAULT '{"type":"object","properties":{},"required":[]}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_tracking_plan_events
        PRIMARY KEY (tracking_plan_id, event_name),

    CONSTRAINT fk_tracking_plan_events_plan
        FOREIGN KEY (tracking_plan_id) REFERENCES tracking_plans (tracking_plan_id),

    CONSTRAINT chk_tracking_plan_events_name
        CHECK (btrim(event_name) <> ''),

    CONSTRAINT chk_tracking_plan_events_status
        CHECK (status IN ('draft', 'system', 'archived')),

    CONSTRAINT chk_tracking_plan_events_schema_object
        CHECK (jsonb_typeof(properties_schema_json) = 'object')
);

CREATE INDEX IF NOT EXISTS idx_tracking_plan_events_plan_status
ON tracking_plan_events (tracking_plan_id, status);

CREATE TABLE IF NOT EXISTS project_sdk_settings (
    project_id VARCHAR(100) PRIMARY KEY,
    allowed_origins_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    published_tracking_plan_id VARCHAR(100),
    published_revision INT,
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_project_sdk_settings_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_project_sdk_settings_published_revision
        FOREIGN KEY (published_tracking_plan_id, published_revision)
        REFERENCES tracking_plan_revisions (tracking_plan_id, revision),

    CONSTRAINT chk_project_sdk_settings_origins_array
        CHECK (jsonb_typeof(allowed_origins_json) = 'array'),

    CONSTRAINT chk_project_sdk_settings_published_pair
        CHECK (
            (published_tracking_plan_id IS NULL AND published_revision IS NULL)
            OR
            (published_tracking_plan_id IS NOT NULL AND published_revision IS NOT NULL)
        ),

    CONSTRAINT chk_project_sdk_settings_status
        CHECK (status IN ('active', 'disabled'))
);

CREATE INDEX IF NOT EXISTS idx_project_sdk_settings_published_revision
ON project_sdk_settings (published_tracking_plan_id, published_revision);

COMMIT;
