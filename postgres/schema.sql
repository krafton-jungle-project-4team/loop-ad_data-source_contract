-- postgres/schema.sql
-- Loop-Ad hotel reservation promotion contract schema.
--
-- This repo owns the shared PostgreSQL schema contract only. It intentionally
-- does not contain seed data or migration history.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =========================================================
-- 1. Projects
-- Customer service unit shared by PostgreSQL and ClickHouse.
-- =========================================================

CREATE TABLE IF NOT EXISTS projects (
    project_id VARCHAR(100) PRIMARY KEY,
    project_name VARCHAR(255) NOT NULL,
    domain VARCHAR(255),
    sdk_key VARCHAR(255) UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(24), 'hex'),
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_projects_status
ON projects (status);

DROP TRIGGER IF EXISTS trg_projects_updated_at ON projects;
CREATE TRIGGER trg_projects_updated_at
BEFORE UPDATE ON projects
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 2. Campaigns
-- User-facing top-level marketing plan.
-- =========================================================

CREATE TABLE IF NOT EXISTS campaigns (
    campaign_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,

    name VARCHAR(255) NOT NULL,
    objective TEXT,
    target_audience VARCHAR(255) NOT NULL DEFAULT 'existing_users',
    primary_metric VARCHAR(100) NOT NULL DEFAULT 'booking_conversion_rate',

    start_date DATE,
    end_date DATE,
    status VARCHAR(50) NOT NULL DEFAULT 'draft',
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_campaigns_project_status
ON campaigns (project_id, status);

CREATE INDEX IF NOT EXISTS idx_campaigns_project_dates
ON campaigns (project_id, start_date, end_date);

DROP TRIGGER IF EXISTS trg_campaigns_updated_at ON campaigns;
CREATE TRIGGER trg_campaigns_updated_at
BEFORE UPDATE ON campaigns
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 3. Promotions
-- Channel-specific execution unit inside a campaign.
-- =========================================================

CREATE TABLE IF NOT EXISTS promotions (
    promotion_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    campaign_id VARCHAR(100) NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,

    name VARCHAR(255) NOT NULL,
    channel VARCHAR(50) NOT NULL,
    target_audience VARCHAR(255) NOT NULL DEFAULT 'existing_users',
    goal_metric VARCHAR(100) NOT NULL,
    target_value NUMERIC(10, 6) NOT NULL,
    goal_basis VARCHAR(50) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'draft',
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_promotions_channel
        CHECK (channel IN ('email', 'sms', 'onsite_banner')),
    CONSTRAINT chk_promotions_goal_metric
        CHECK (goal_metric IN ('inflow_rate', 'booking_conversion_rate', 'promotion_click_rate')),
    CONSTRAINT chk_promotions_goal_basis
        CHECK (goal_basis IN ('promotion_average', 'all_segments'))
);

CREATE INDEX IF NOT EXISTS idx_promotions_campaign
ON promotions (campaign_id);

CREATE INDEX IF NOT EXISTS idx_promotions_project_status
ON promotions (project_id, status);

CREATE INDEX IF NOT EXISTS idx_promotions_project_channel
ON promotions (project_id, channel);

DROP TRIGGER IF EXISTS trg_promotions_updated_at ON promotions;
CREATE TRIGGER trg_promotions_updated_at
BEFORE UPDATE ON promotions
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 4. Segment Query Previews
-- Dashboard natural-language segment query preview result.
-- =========================================================

CREATE TABLE IF NOT EXISTS segment_query_previews (
    query_preview_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    created_by VARCHAR(100),

    natural_language_query TEXT NOT NULL,
    generated_sql TEXT NOT NULL,
    query_params_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    sample_size INT NOT NULL DEFAULT 0,
    total_eligible_user_count INT NOT NULL DEFAULT 0,
    sample_ratio NUMERIC(10, 6) NOT NULL DEFAULT 0,
    sample_size_status VARCHAR(50) NOT NULL,

    result_columns_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    result_preview_json JSONB NOT NULL DEFAULT '[]'::jsonb,

    status VARCHAR(50) NOT NULL DEFAULT 'previewed',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_segment_query_preview_status
        CHECK (status IN ('previewed', 'saved', 'rejected', 'failed')),
    CONSTRAINT chk_segment_query_preview_sample_status
        CHECK (sample_size_status IN ('valid', 'too_small', 'too_large', 'failed'))
);

CREATE INDEX IF NOT EXISTS idx_segment_query_previews_project_status
ON segment_query_previews (project_id, status, created_at DESC);

-- =========================================================
-- 5. Segment Definitions
-- Saved segment definitions used by Dashboard and Decision.
-- =========================================================

CREATE TABLE IF NOT EXISTS segment_definitions (
    segment_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,

    segment_name VARCHAR(255) NOT NULL,
    source VARCHAR(50) NOT NULL,
    query_preview_id VARCHAR(100)
        REFERENCES segment_query_previews(query_preview_id) ON DELETE SET NULL,

    natural_language_query TEXT,
    generated_sql TEXT,
    rule_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    sample_size INT NOT NULL DEFAULT 0,
    sample_ratio NUMERIC(10, 6) NOT NULL DEFAULT 0,

    status VARCHAR(50) NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_segment_definitions_source
        CHECK (source IN ('ai_suggested', 'custom_chatkit', 'manual_rule', 'system_default')),
    CONSTRAINT chk_segment_definitions_status
        CHECK (status IN ('active', 'archived'))
);

CREATE INDEX IF NOT EXISTS idx_segment_definitions_project_status
ON segment_definitions (project_id, status);

CREATE INDEX IF NOT EXISTS idx_segment_definitions_query_preview
ON segment_definitions (query_preview_id);

CREATE INDEX IF NOT EXISTS gin_segment_definitions_rule_json
ON segment_definitions USING GIN (rule_json);

DROP TRIGGER IF EXISTS trg_segment_definitions_updated_at ON segment_definitions;
CREATE TRIGGER trg_segment_definitions_updated_at
BEFORE UPDATE ON segment_definitions
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 6. Funnel Definitions / Steps
-- Dashboard-managed hotel booking funnel contract.
-- =========================================================

CREATE TABLE IF NOT EXISTS funnel_definitions (
    funnel_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,

    funnel_name VARCHAR(255) NOT NULL,
    domain_type VARCHAR(100) NOT NULL DEFAULT 'hotel_booking',
    status VARCHAR(50) NOT NULL DEFAULT 'active',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_funnel_definitions_project_status
ON funnel_definitions (project_id, status);

DROP TRIGGER IF EXISTS trg_funnel_definitions_updated_at ON funnel_definitions;
CREATE TRIGGER trg_funnel_definitions_updated_at
BEFORE UPDATE ON funnel_definitions
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS funnel_steps (
    id BIGSERIAL PRIMARY KEY,
    funnel_id VARCHAR(100) NOT NULL
        REFERENCES funnel_definitions(funnel_id) ON DELETE CASCADE,

    step_order INT NOT NULL,
    step_name VARCHAR(255) NOT NULL,
    event_name VARCHAR(100) NOT NULL,
    condition_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (funnel_id, step_order)
);

CREATE INDEX IF NOT EXISTS idx_funnel_steps_funnel
ON funnel_steps (funnel_id, step_order);

-- =========================================================
-- 7. ChatKit Persistence
-- Dashboard owns ChatKit session/action processing.
-- =========================================================

CREATE TABLE IF NOT EXISTS ai_chat_sessions (
    chat_session_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,

    user_id VARCHAR(100),
    chatkit_thread_id VARCHAR(255),
    context_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_chat_sessions_project_user
ON ai_chat_sessions (project_id, user_id);

DROP TRIGGER IF EXISTS trg_ai_chat_sessions_updated_at ON ai_chat_sessions;
CREATE TRIGGER trg_ai_chat_sessions_updated_at
BEFORE UPDATE ON ai_chat_sessions
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS ai_chat_messages (
    id BIGSERIAL PRIMARY KEY,
    chat_session_id VARCHAR(100) NOT NULL
        REFERENCES ai_chat_sessions(chat_session_id) ON DELETE CASCADE,

    role VARCHAR(50) NOT NULL,
    content TEXT NOT NULL,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_chat_messages_session_created
ON ai_chat_messages (chat_session_id, created_at);

CREATE TABLE IF NOT EXISTS ai_action_runs (
    action_run_id VARCHAR(100) PRIMARY KEY,
    chat_session_id VARCHAR(100)
        REFERENCES ai_chat_sessions(chat_session_id) ON DELETE SET NULL,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,

    action_type VARCHAR(100) NOT NULL,
    input_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    output_json JSONB,

    requires_confirmation BOOLEAN NOT NULL DEFAULT false,
    confirmed_at TIMESTAMPTZ,
    status VARCHAR(50) NOT NULL DEFAULT 'requested',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_action_runs_project_status
ON ai_action_runs (project_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_action_runs_session
ON ai_action_runs (chat_session_id);

DROP TRIGGER IF EXISTS trg_ai_action_runs_updated_at ON ai_action_runs;
CREATE TRIGGER trg_ai_action_runs_updated_at
BEFORE UPDATE ON ai_action_runs
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 8. Promotion Analyses
-- Decision stores promotion analysis results here.
-- =========================================================

CREATE TABLE IF NOT EXISTS promotion_analyses (
    analysis_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    campaign_id VARCHAR(100) NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    promotion_id VARCHAR(100) NOT NULL REFERENCES promotions(promotion_id) ON DELETE CASCADE,

    focus_segment_ids_json JSONB,
    operator_instruction TEXT,
    summary TEXT,
    data_evidence_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    target_segments_json JSONB NOT NULL DEFAULT '[]'::jsonb,

    status VARCHAR(50) NOT NULL DEFAULT 'completed',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_promotion_analyses_promotion
ON promotion_analyses (promotion_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_promotion_analyses_project_status
ON promotion_analyses (project_id, status);

DROP TRIGGER IF EXISTS trg_promotion_analyses_updated_at ON promotion_analyses;
CREATE TRIGGER trg_promotion_analyses_updated_at
BEFORE UPDATE ON promotion_analyses
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 9. Segment Vectors
-- Decision-owned 64-dimensional segment vectors.
-- =========================================================

CREATE TABLE IF NOT EXISTS segment_vectors (
    segment_vector_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    segment_id VARCHAR(100) NOT NULL,
    analysis_id VARCHAR(100)
        REFERENCES promotion_analyses(analysis_id) ON DELETE SET NULL,

    dimensions INT NOT NULL DEFAULT 64,
    vector_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    top_features_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    embedding_model VARCHAR(255),

    status VARCHAR(50) NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_project_segment
ON segment_vectors (project_id, segment_id);

CREATE INDEX IF NOT EXISTS idx_segment_vectors_analysis
ON segment_vectors (analysis_id);

DROP TRIGGER IF EXISTS trg_segment_vectors_updated_at ON segment_vectors;
CREATE TRIGGER trg_segment_vectors_updated_at
BEFORE UPDATE ON segment_vectors
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 10. Promotion Target Segments
-- Segment targets selected for a promotion analysis.
-- =========================================================

CREATE TABLE IF NOT EXISTS promotion_target_segments (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    campaign_id VARCHAR(100) NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    promotion_id VARCHAR(100) NOT NULL REFERENCES promotions(promotion_id) ON DELETE CASCADE,
    analysis_id VARCHAR(100) NOT NULL REFERENCES promotion_analyses(analysis_id) ON DELETE CASCADE,

    segment_id VARCHAR(100) NOT NULL,
    segment_name VARCHAR(255) NOT NULL,
    segment_vector_id VARCHAR(100)
        REFERENCES segment_vectors(segment_vector_id) ON DELETE SET NULL,

    estimated_size INT NOT NULL DEFAULT 0,
    sample_ratio NUMERIC(10, 6) NOT NULL DEFAULT 0,
    selection_reason TEXT,
    content_brief_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    data_evidence_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    status VARCHAR(50) NOT NULL DEFAULT 'selected',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (analysis_id, segment_id)
);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_promotion
ON promotion_target_segments (promotion_id, status);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_segment
ON promotion_target_segments (segment_id);

DROP TRIGGER IF EXISTS trg_promotion_target_segments_updated_at ON promotion_target_segments;
CREATE TRIGGER trg_promotion_target_segments_updated_at
BEFORE UPDATE ON promotion_target_segments
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 11. Generation Runs
-- Decision content generation execution.
-- =========================================================

CREATE TABLE IF NOT EXISTS generation_runs (
    generation_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    campaign_id VARCHAR(100) NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    promotion_id VARCHAR(100) NOT NULL REFERENCES promotions(promotion_id) ON DELETE CASCADE,
    analysis_id VARCHAR(100) NOT NULL REFERENCES promotion_analyses(analysis_id) ON DELETE CASCADE,

    content_option_count INT NOT NULL DEFAULT 3,
    operator_instruction TEXT,
    prompt_context_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    report_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    status VARCHAR(50) NOT NULL DEFAULT 'completed',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_generation_runs_promotion
ON generation_runs (promotion_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_generation_runs_analysis
ON generation_runs (analysis_id);

DROP TRIGGER IF EXISTS trg_generation_runs_updated_at ON generation_runs;
CREATE TRIGGER trg_generation_runs_updated_at
BEFORE UPDATE ON generation_runs
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 12. Content Candidates
-- Generated content options. MVP allows one approved content per
-- generation_id + segment_id.
-- =========================================================

CREATE TABLE IF NOT EXISTS content_candidates (
    content_id VARCHAR(100) PRIMARY KEY,
    content_option_id VARCHAR(100) NOT NULL UNIQUE,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    campaign_id VARCHAR(100) NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    promotion_id VARCHAR(100) NOT NULL REFERENCES promotions(promotion_id) ON DELETE CASCADE,
    analysis_id VARCHAR(100) NOT NULL REFERENCES promotion_analyses(analysis_id) ON DELETE CASCADE,
    generation_id VARCHAR(100) NOT NULL REFERENCES generation_runs(generation_id) ON DELETE CASCADE,

    segment_id VARCHAR(100) NOT NULL,
    segment_name VARCHAR(255),
    channel VARCHAR(50) NOT NULL,

    subject TEXT,
    preheader TEXT,
    title TEXT,
    body TEXT,
    cta TEXT,
    message TEXT,
    image_prompt TEXT,
    landing_url TEXT,

    reason_summary TEXT,
    data_evidence_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    message_strategy TEXT,
    payload_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    status VARCHAR(50) NOT NULL DEFAULT 'draft',
    approved_at TIMESTAMPTZ,
    approved_by VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (generation_id, segment_id, content_option_id),
    CONSTRAINT chk_content_candidates_channel
        CHECK (channel IN ('email', 'sms', 'onsite_banner'))
);

CREATE INDEX IF NOT EXISTS idx_content_candidates_generation_segment
ON content_candidates (generation_id, segment_id);

CREATE INDEX IF NOT EXISTS idx_content_candidates_promotion_status
ON content_candidates (promotion_id, status);

CREATE UNIQUE INDEX IF NOT EXISTS uq_content_candidates_one_approved_per_segment
ON content_candidates (generation_id, segment_id)
WHERE status = 'approved';

DROP TRIGGER IF EXISTS trg_content_candidates_updated_at ON content_candidates;
CREATE TRIGGER trg_content_candidates_updated_at
BEFORE UPDATE ON content_candidates
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 13. Promotion Runs
-- One loop group inside a promotion.
-- =========================================================

CREATE TABLE IF NOT EXISTS promotion_runs (
    promotion_run_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    campaign_id VARCHAR(100) NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    promotion_id VARCHAR(100) NOT NULL REFERENCES promotions(promotion_id) ON DELETE CASCADE,
    analysis_id VARCHAR(100) NOT NULL REFERENCES promotion_analyses(analysis_id) ON DELETE CASCADE,
    generation_id VARCHAR(100) NOT NULL REFERENCES generation_runs(generation_id) ON DELETE CASCADE,

    previous_promotion_run_id VARCHAR(100)
        REFERENCES promotion_runs(promotion_run_id) ON DELETE SET NULL,
    loop_count INT NOT NULL DEFAULT 1,
    operator_instruction TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'planned',
    summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_promotion
ON promotion_runs (promotion_id, loop_count DESC);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_project_status
ON promotion_runs (project_id, status);

DROP TRIGGER IF EXISTS trg_promotion_runs_updated_at ON promotion_runs;
CREATE TRIGGER trg_promotion_runs_updated_at
BEFORE UPDATE ON promotion_runs
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 14. Ad Experiments
-- One actual ad experiment per segment in a promotion_run.
-- =========================================================

CREATE TABLE IF NOT EXISTS ad_experiments (
    ad_experiment_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    campaign_id VARCHAR(100) NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    promotion_id VARCHAR(100) NOT NULL REFERENCES promotions(promotion_id) ON DELETE CASCADE,
    promotion_run_id VARCHAR(100) NOT NULL REFERENCES promotion_runs(promotion_run_id) ON DELETE CASCADE,
    analysis_id VARCHAR(100) NOT NULL REFERENCES promotion_analyses(analysis_id) ON DELETE CASCADE,
    generation_id VARCHAR(100) NOT NULL REFERENCES generation_runs(generation_id) ON DELETE CASCADE,

    segment_id VARCHAR(100) NOT NULL,
    segment_name VARCHAR(255),
    content_id VARCHAR(100) NOT NULL REFERENCES content_candidates(content_id) ON DELETE RESTRICT,
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

    CONSTRAINT uq_ad_experiments_segment_per_run UNIQUE (promotion_run_id, segment_id),
    CONSTRAINT fk_ad_experiments_content_option
        FOREIGN KEY (content_option_id)
        REFERENCES content_candidates(content_option_id),
    CONSTRAINT chk_ad_experiments_channel
        CHECK (channel IN ('email', 'sms', 'onsite_banner')),
    CONSTRAINT chk_ad_experiments_goal_metric
        CHECK (goal_metric IN ('inflow_rate', 'booking_conversion_rate', 'promotion_click_rate')),
    CONSTRAINT chk_ad_experiments_goal_basis
        CHECK (goal_basis IN ('promotion_average', 'all_segments'))
);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_promotion_run_id
ON ad_experiments (promotion_run_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_segment_id
ON ad_experiments (segment_id);

CREATE INDEX IF NOT EXISTS idx_ad_experiments_status
ON ad_experiments (status);

DROP TRIGGER IF EXISTS trg_ad_experiments_updated_at ON ad_experiments;
CREATE TRIGGER trg_ad_experiments_updated_at
BEFORE UPDATE ON ad_experiments
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 15. Promotion Evaluations
-- Ad experiment and promotion_run evaluation results.
-- =========================================================

CREATE TABLE IF NOT EXISTS promotion_evaluations (
    evaluation_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    campaign_id VARCHAR(100) NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    promotion_id VARCHAR(100) NOT NULL REFERENCES promotions(promotion_id) ON DELETE CASCADE,
    promotion_run_id VARCHAR(100) NOT NULL REFERENCES promotion_runs(promotion_run_id) ON DELETE CASCADE,
    ad_experiment_id VARCHAR(100)
        REFERENCES ad_experiments(ad_experiment_id) ON DELETE CASCADE,

    segment_id VARCHAR(100),
    metric VARCHAR(100) NOT NULL,
    numerator_count BIGINT NOT NULL DEFAULT 0,
    denominator_count BIGINT NOT NULL DEFAULT 0,
    actual_value NUMERIC(10, 6) NOT NULL DEFAULT 0,
    target_value NUMERIC(10, 6) NOT NULL DEFAULT 0,
    goal_basis VARCHAR(50) NOT NULL,

    status VARCHAR(50) NOT NULL,
    failed_segment_ids_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    failed_ad_experiment_ids_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    result_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    evaluated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_promotion_evaluations_promotion_run
ON promotion_evaluations (promotion_run_id, evaluated_at DESC);

CREATE INDEX IF NOT EXISTS idx_promotion_evaluations_ad_experiment_id
ON promotion_evaluations (ad_experiment_id);

CREATE INDEX IF NOT EXISTS idx_promotion_evaluations_status
ON promotion_evaluations (status);

-- =========================================================
-- 16. User Segment Assignments
-- Precomputed promotion_run user-to-segment/ad assignment.
-- =========================================================

CREATE TABLE IF NOT EXISTS user_segment_assignments (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    promotion_run_id VARCHAR(100) NOT NULL REFERENCES promotion_runs(promotion_run_id) ON DELETE CASCADE,

    user_id VARCHAR(255) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    ad_experiment_id VARCHAR(100) NOT NULL
        REFERENCES ad_experiments(ad_experiment_id) ON DELETE CASCADE,
    content_id VARCHAR(100) NOT NULL
        REFERENCES content_candidates(content_id) ON DELETE RESTRICT,
    content_option_id VARCHAR(100) NOT NULL
        REFERENCES content_candidates(content_option_id) ON DELETE RESTRICT,

    similarity_score NUMERIC(10, 6),
    fallback BOOLEAN NOT NULL DEFAULT false,
    assignment_scope VARCHAR(100) NOT NULL DEFAULT 'eligible_users',
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ,

    UNIQUE (promotion_run_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_project_user
ON user_segment_assignments (project_id, user_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_run_segment
ON user_segment_assignments (promotion_run_id, segment_id);

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_ad_experiment
ON user_segment_assignments (ad_experiment_id);

-- =========================================================
-- 17. Dispatch / Redirect
-- Dashboard advertising execution module state.
-- =========================================================

CREATE TABLE IF NOT EXISTS ad_dispatch_jobs (
    dispatch_job_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    campaign_id VARCHAR(100) NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    promotion_id VARCHAR(100) NOT NULL REFERENCES promotions(promotion_id) ON DELETE CASCADE,
    promotion_run_id VARCHAR(100) NOT NULL REFERENCES promotion_runs(promotion_run_id) ON DELETE CASCADE,
    ad_experiment_id VARCHAR(100)
        REFERENCES ad_experiments(ad_experiment_id) ON DELETE SET NULL,

    channel VARCHAR(50) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'queued',
    target_count INT NOT NULL DEFAULT 0,
    dispatched_count INT NOT NULL DEFAULT 0,
    failed_count INT NOT NULL DEFAULT 0,

    request_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    result_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    error_message TEXT,

    scheduled_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_ad_dispatch_jobs_channel
        CHECK (channel IN ('email', 'sms', 'onsite_banner'))
);

CREATE INDEX IF NOT EXISTS idx_ad_dispatch_jobs_promotion_run
ON ad_dispatch_jobs (promotion_run_id, status);

CREATE INDEX IF NOT EXISTS idx_ad_dispatch_jobs_ad_experiment_id
ON ad_dispatch_jobs (ad_experiment_id);

DROP TRIGGER IF EXISTS trg_ad_dispatch_jobs_updated_at ON ad_dispatch_jobs;
CREATE TRIGGER trg_ad_dispatch_jobs_updated_at
BEFORE UPDATE ON ad_dispatch_jobs
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS redirect_links (
    redirect_link_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    campaign_id VARCHAR(100) NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    promotion_id VARCHAR(100) NOT NULL REFERENCES promotions(promotion_id) ON DELETE CASCADE,
    promotion_run_id VARCHAR(100) NOT NULL REFERENCES promotion_runs(promotion_run_id) ON DELETE CASCADE,
    ad_experiment_id VARCHAR(100)
        REFERENCES ad_experiments(ad_experiment_id) ON DELETE SET NULL,

    segment_id VARCHAR(100),
    user_id VARCHAR(255),
    content_id VARCHAR(100),
    content_option_id VARCHAR(100),
    redirect_token VARCHAR(255) NOT NULL UNIQUE,
    destination_url TEXT NOT NULL,

    status VARCHAR(50) NOT NULL DEFAULT 'active',
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    expires_at TIMESTAMPTZ,
    clicked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_redirect_links_ad_experiment_id
ON redirect_links (ad_experiment_id);

CREATE INDEX IF NOT EXISTS idx_redirect_links_token
ON redirect_links (redirect_token);

CREATE INDEX IF NOT EXISTS idx_redirect_links_promotion_run_user
ON redirect_links (promotion_run_id, user_id);

DROP TRIGGER IF EXISTS trg_redirect_links_updated_at ON redirect_links;
CREATE TRIGGER trg_redirect_links_updated_at
BEFORE UPDATE ON redirect_links
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 18. Event Validation Errors
-- Collector validation failures mirrored in PostgreSQL for operations.
-- =========================================================

CREATE TABLE IF NOT EXISTS event_validation_errors (
    error_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id VARCHAR(100),
    schema_version VARCHAR(100),
    event_id VARCHAR(255),
    event_name VARCHAR(100),
    source VARCHAR(100),

    error_code VARCHAR(100) NOT NULL,
    error_message TEXT NOT NULL,
    payload_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_event_validation_errors_project_created
ON event_validation_errors (project_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_event_validation_errors_event_name
ON event_validation_errors (event_name);

-- =========================================================
-- 19. Active Ad Serving Assignments
-- Hot-path view for Dashboard banner resolve / dispatch / redirect.
-- =========================================================

CREATE OR REPLACE VIEW active_ad_serving_assignments AS
SELECT
    usa.promotion_run_id,
    usa.user_id,
    usa.segment_id,
    usa.ad_experiment_id,
    usa.content_id,
    usa.content_option_id,
    usa.fallback,
    usa.similarity_score,
    ae.project_id,
    ae.campaign_id,
    ae.promotion_id,
    ae.channel,
    cc.subject,
    cc.preheader,
    cc.title,
    cc.body,
    cc.cta,
    cc.message,
    cc.image_prompt,
    cc.landing_url,
    cc.status AS content_status,
    ae.status AS ad_experiment_status
FROM user_segment_assignments usa
JOIN ad_experiments ae
  ON usa.ad_experiment_id = ae.ad_experiment_id
JOIN content_candidates cc
  ON usa.content_id = cc.content_id
WHERE ae.status IN ('approved', 'running')
  AND cc.status IN ('approved', 'active');
