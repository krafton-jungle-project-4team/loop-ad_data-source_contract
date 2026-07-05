-- =========================================================
-- Loop-Ad PostgreSQL Schema Contract v1.6
-- Draft: promotion segment suggestion / confirmation flow
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
        CHECK (status IN ('draft', 'active', 'paused', 'completed', 'stopped'))
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
    project_id VARCHAR(100) NOT NULL,
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
        )
);

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
        CHECK (status IN ('requested', 'running', 'completed', 'failed'))
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
-- 9. Segment Vectors
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
    vector_version VARCHAR(50) NOT NULL DEFAULT 'v1',
    source VARCHAR(50) NOT NULL DEFAULT 'decision_analysis',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_vectors_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_segment_vectors_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_segment_vectors_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),


    CONSTRAINT fk_segment_vectors_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT chk_segment_vectors_dim
        CHECK (vector_dim = 64),

    CONSTRAINT chk_segment_vectors_source
        CHECK (source IN ('decision_analysis', 'fixture', 'manual', 'batch_profile'))
);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_project_id
ON segment_vectors (project_id);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_segment_id
ON segment_vectors (segment_id);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_promotion_id
ON segment_vectors (promotion_id);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_promotion_run_id
ON segment_vectors (promotion_run_id);

-- =========================================================
-- 10. Promotion Target Segments
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
        FOREIGN KEY (suggestion_id) REFERENCES promotion_segment_suggestions (suggestion_id),

    CONSTRAINT chk_promotion_target_segments_priority
        CHECK (priority IS NULL OR priority IN ('low', 'medium', 'high')),

    CONSTRAINT chk_promotion_target_segments_status
        CHECK (status IN ('planned', 'content_ready', 'approved', 'running', 'goal_met', 'goal_not_met', 'insufficient_data', 'stopped')),

    CONSTRAINT chk_promotion_target_segments_estimated_size
        CHECK (estimated_size >= 0),

    CONSTRAINT uq_promotion_target_segments_analysis_segment
        UNIQUE (analysis_id, segment_id)
);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_promotion_id
ON promotion_target_segments (promotion_id);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_segment_id
ON promotion_target_segments (segment_id);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_analysis_id
ON promotion_target_segments (analysis_id);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_suggestion_id
ON promotion_target_segments (suggestion_id);

-- =========================================================
-- 11. Generation Runs
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
        CHECK (content_option_count >= 1)
);

CREATE INDEX IF NOT EXISTS idx_generation_runs_analysis_id
ON generation_runs (analysis_id);

CREATE INDEX IF NOT EXISTS idx_generation_runs_promotion_id
ON generation_runs (promotion_id);

CREATE INDEX IF NOT EXISTS idx_generation_runs_status
ON generation_runs (status);

-- =========================================================
-- 12. Content Candidates
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

    -- onsite_banner
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

-- =========================================================
-- 13. Promotion Runs
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

    CONSTRAINT uq_promotion_runs_loop
        UNIQUE (promotion_id, loop_count)
);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_project_id
ON promotion_runs (project_id);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_campaign_id
ON promotion_runs (campaign_id);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_promotion_id
ON promotion_runs (promotion_id);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_status
ON promotion_runs (status);

-- Add optional FK from segment_vectors.promotion_run_id after promotion_runs exists.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_segment_vectors_promotion_run'
    ) THEN
        ALTER TABLE segment_vectors
        ADD CONSTRAINT fk_segment_vectors_promotion_run
        FOREIGN KEY (promotion_run_id)
        REFERENCES promotion_runs (promotion_run_id);
    END IF;
END $$;

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

-- =========================================================
-- 16. User Segment Assignments
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
    assignment_source VARCHAR(50) NOT NULL DEFAULT 'decision_batch',
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ,

    CONSTRAINT fk_user_segment_assignments_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_user_segment_assignments_run
        FOREIGN KEY (promotion_run_id) REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_user_segment_assignments_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_user_segment_assignments_ad_experiment
        FOREIGN KEY (ad_experiment_id) REFERENCES ad_experiments (ad_experiment_id),

    CONSTRAINT fk_user_segment_assignments_content
        FOREIGN KEY (content_id) REFERENCES content_candidates (content_id),

    CONSTRAINT chk_user_segment_assignments_score
        CHECK (similarity_score IS NULL OR (similarity_score >= 0 AND similarity_score <= 1)),

    CONSTRAINT chk_user_segment_assignments_source
        CHECK (assignment_source IN ('decision_batch', 'fallback', 'manual', 'fixture')),

    CONSTRAINT uq_user_segment_assignments_run_user
        UNIQUE (promotion_run_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_project_id
ON user_segment_assignments (project_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_run_id
ON user_segment_assignments (promotion_run_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_user_id
ON user_segment_assignments (user_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_segment_id
ON user_segment_assignments (segment_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_ad_experiment_id
ON user_segment_assignments (ad_experiment_id);

-- =========================================================
-- 17. Ad Dispatch Jobs
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
-- 18. Redirect Links
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
-- 19. Event Validation Errors
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
-- 20. Active Ad Serving Assignments View
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
    cc.status AS content_status
FROM user_segment_assignments usa
JOIN ad_experiments ae
  ON usa.ad_experiment_id = ae.ad_experiment_id
JOIN content_candidates cc
  ON usa.content_id = cc.content_id
WHERE ae.status IN ('approved', 'running')
  AND cc.status IN ('approved', 'active')
  AND (usa.expires_at IS NULL OR usa.expires_at > now());

COMMIT;
