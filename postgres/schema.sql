-- postgres-init.sql
-- 테이블 생성 전용. seed 데이터는 넣지 않는다.
--
-- 설계 원칙:
-- 1. PostgreSQL은 운영 상태 DB다.
-- 2. 추천 서버는 ClickHouse events를 분석하고 PostgreSQL에 추천/실험/매핑 상태를 저장한다.
-- 3. 관리자 승인/거절은 분석 결과가 아니라 추천 액션 단위로 한다.
-- 4. 톰슨 샘플링의 현재 학습 상태(alpha/beta)는 PostgreSQL에 저장한다.
-- 5. 사용자의 실제 행동 로그와 보상 계산 원천 데이터는 ClickHouse events에 저장한다.
-- 6. 광고 서버는 추천 서버를 호출하지 않고 PostgreSQL segment_ad_mappings를 직접 읽는다.

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
-- 고객사/서비스 단위.
-- 모든 PostgreSQL 운영 데이터와 ClickHouse events의 project_id 기준이 된다.
-- =========================================================

CREATE TABLE IF NOT EXISTS projects (
    id VARCHAR(128) PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    domain VARCHAR(255),
    sdk_key VARCHAR(255) UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(24), 'hex'),
    status VARCHAR(32) NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_projects_updated_at ON projects;
CREATE TRIGGER trg_projects_updated_at
BEFORE UPDATE ON projects
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 2. Dashboard Users
-- LoopAd 대시보드에 로그인하는 고객사 관리자/운영자 계정.
-- =========================================================

CREATE TABLE IF NOT EXISTS dashboard_users (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    email VARCHAR(255) NOT NULL,
    password_hash TEXT,
    role VARCHAR(64) NOT NULL DEFAULT 'admin',
    status VARCHAR(32) NOT NULL DEFAULT 'active',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (project_id, email)
);

CREATE INDEX IF NOT EXISTS idx_dashboard_users_project
ON dashboard_users (project_id);

DROP TRIGGER IF EXISTS trg_dashboard_users_updated_at ON dashboard_users;
CREATE TRIGGER trg_dashboard_users_updated_at
BEFORE UPDATE ON dashboard_users
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 3. User Profiles
-- 최종 사용자 프로필.
-- age_group, gender, membership_level 같은 안정적인 사용자 속성을 저장한다.
-- 최신 행동 context는 애플리케이션의 runtime context 저장소가 담당한다.
-- =========================================================

CREATE TABLE IF NOT EXISTS user_profiles (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    external_user_id VARCHAR(255) NOT NULL,

    age_group VARCHAR(32),
    gender VARCHAR(32),
    membership_level VARCHAR(64),

    attributes_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (project_id, external_user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_profiles_project_user
ON user_profiles (project_id, external_user_id);

DROP TRIGGER IF EXISTS trg_user_profiles_updated_at ON user_profiles;
CREATE TRIGGER trg_user_profiles_updated_at
BEFORE UPDATE ON user_profiles
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 4. Segments
-- 대시보드에서 저장/관리하는 세그먼트 정의.
-- MVP에서는 segment_ad_mappings.segment_json만으로도 가능하지만,
-- 운영자가 세그먼트를 이름 붙여 관리하려면 필요하다.
-- =========================================================

CREATE TABLE IF NOT EXISTS segments (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    name VARCHAR(255) NOT NULL,
    conditions_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    segment_hash VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'active',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (project_id, segment_hash)
);

CREATE INDEX IF NOT EXISTS idx_segments_project_status
ON segments (project_id, status);

CREATE INDEX IF NOT EXISTS gin_segments_conditions_json
ON segments USING GIN (conditions_json);

DROP TRIGGER IF EXISTS trg_segments_updated_at ON segments;
CREATE TRIGGER trg_segments_updated_at
BEFORE UPDATE ON segments
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 5. Campaigns
-- 광고/마케팅 캠페인 메타데이터.
-- 광고 서버와 대시보드가 사용한다.
-- =========================================================

CREATE TABLE IF NOT EXISTS campaigns (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    external_campaign_id VARCHAR(255),
    name VARCHAR(255) NOT NULL,
    channel VARCHAR(64),
    goal VARCHAR(64),
    budget NUMERIC(18, 2),
    status VARCHAR(32) NOT NULL DEFAULT 'active',

    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,

    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (project_id, external_campaign_id)
);

CREATE INDEX IF NOT EXISTS idx_campaigns_project_status
ON campaigns (project_id, status);

CREATE INDEX IF NOT EXISTS idx_campaigns_project_channel
ON campaigns (project_id, channel);

DROP TRIGGER IF EXISTS trg_campaigns_updated_at ON campaigns;
CREATE TRIGGER trg_campaigns_updated_at
BEFORE UPDATE ON campaigns
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 6. Coupons
-- 쿠폰형 추천 액션 실행을 위한 쿠폰 메타데이터.
-- =========================================================

CREATE TABLE IF NOT EXISTS coupons (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    code VARCHAR(255),
    name VARCHAR(255) NOT NULL,

    discount_type VARCHAR(64) NOT NULL,
    discount_rate NUMERIC(5, 4),
    discount_amount NUMERIC(18, 2),
    max_discount_amount NUMERIC(18, 2),

    budget NUMERIC(18, 2),
    status VARCHAR(32) NOT NULL DEFAULT 'active',

    starts_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,

    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (project_id, code)
);

CREATE INDEX IF NOT EXISTS idx_coupons_project_status
ON coupons (project_id, status);

DROP TRIGGER IF EXISTS trg_coupons_updated_at ON coupons;
CREATE TRIGGER trg_coupons_updated_at
BEFORE UPDATE ON coupons
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 7. Ad Creatives
-- 실제 사용자에게 보여줄 광고/메시지/배너 소재.
-- segment_ad_mappings는 어떤 액션을 실행할지,
-- ad_creatives는 그 액션을 어떤 문구/이미지/랜딩으로 보여줄지를 담당한다.
-- =========================================================

CREATE TABLE IF NOT EXISTS ad_creatives (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    campaign_id BIGINT REFERENCES campaigns(id) ON DELETE SET NULL,
    coupon_id BIGINT REFERENCES coupons(id) ON DELETE SET NULL,

    action_id VARCHAR(128),
    creative_type VARCHAR(64) NOT NULL DEFAULT 'banner',

    title VARCHAR(255),
    message TEXT,
    image_url TEXT,
    landing_url TEXT,

    payload_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    status VARCHAR(32) NOT NULL DEFAULT 'active',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ad_creatives_project_status
ON ad_creatives (project_id, status);

CREATE INDEX IF NOT EXISTS idx_ad_creatives_project_action_status
ON ad_creatives (project_id, action_id, status);

CREATE INDEX IF NOT EXISTS idx_ad_creatives_campaign
ON ad_creatives (campaign_id);

DROP TRIGGER IF EXISTS trg_ad_creatives_updated_at ON ad_creatives;
CREATE TRIGGER trg_ad_creatives_updated_at
BEFORE UPDATE ON ad_creatives
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 8. Action Catalog
-- 추천 서버가 추천할 수 있는 액션 목록.
-- 현재 코드 기반 ACTION_CATALOG를 쓰더라도,
-- 팀 공통 DB 계약에서는 action_id/action_type 의미를 맞추기 위해 둔다.
-- =========================================================

CREATE TABLE IF NOT EXISTS action_catalog (
    action_id VARCHAR(128) PRIMARY KEY,
    action_type VARCHAR(64) NOT NULL,

    title VARCHAR(255) NOT NULL,
    description TEXT,
    target_step VARCHAR(128),

    base_weight DOUBLE PRECISION NOT NULL DEFAULT 0.5,
    primary_metric VARCHAR(128),
    expected_impact TEXT,

    execution_hint_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    status VARCHAR(32) NOT NULL DEFAULT 'active',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_action_catalog_type_status
ON action_catalog (action_type, status);

DROP TRIGGER IF EXISTS trg_action_catalog_updated_at ON action_catalog;
CREATE TRIGGER trg_action_catalog_updated_at
BEFORE UPDATE ON action_catalog
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 9. Automation Policies
-- 관리자가 AI 자동 실행 범위를 정하는 가드레일.
-- 추천 액션은 이 정책을 통과해야 자동 실험/매핑 생성 가능.
-- =========================================================

CREATE TABLE IF NOT EXISTS automation_policies (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL UNIQUE REFERENCES projects(id) ON DELETE CASCADE,

    enabled BOOLEAN NOT NULL DEFAULT false,
    auto_execute_enabled BOOLEAN NOT NULL DEFAULT false,

    allowed_action_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    allowed_action_types JSONB NOT NULL DEFAULT '[]'::jsonb,
    blocked_action_ids JSONB NOT NULL DEFAULT '[]'::jsonb,

    max_experiment_traffic_ratio DOUBLE PRECISION NOT NULL DEFAULT 0.2,
    min_priority_score DOUBLE PRECISION NOT NULL DEFAULT 0.0,

    max_discount_rate DOUBLE PRECISION,
    max_daily_coupon_budget DOUBLE PRECISION,
    max_message_per_user_per_day BIGINT,
    stop_loss_relative_drop DOUBLE PRECISION,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_automation_policies_project
ON automation_policies (project_id);

DROP TRIGGER IF EXISTS trg_automation_policies_updated_at ON automation_policies;
CREATE TRIGGER trg_automation_policies_updated_at
BEFORE UPDATE ON automation_policies
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 10. Bandit Policies
-- 톰슨 샘플링 문제 정의.
-- 예: 특정 segment에서 어떤 objective를 최적화할지 정의한다.
-- =========================================================

CREATE TABLE IF NOT EXISTS bandit_policies (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    name VARCHAR(255) NOT NULL,

    segment_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    segment_hash VARCHAR(64) NOT NULL,

    objective_metric VARCHAR(128) NOT NULL DEFAULT 'purchase_rate',
    reward_event_name VARCHAR(128) NOT NULL DEFAULT 'purchase',

    algorithm VARCHAR(64) NOT NULL DEFAULT 'thompson_sampling',
    status VARCHAR(64) NOT NULL DEFAULT 'active',

    min_samples_per_arm BIGINT NOT NULL DEFAULT 0,
    exploration_enabled BOOLEAN NOT NULL DEFAULT true,

    config_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (project_id, segment_hash, objective_metric)
);

CREATE INDEX IF NOT EXISTS idx_bandit_policies_project_status
ON bandit_policies (project_id, status);

CREATE INDEX IF NOT EXISTS idx_bandit_policies_segment_hash
ON bandit_policies (segment_hash);

DROP TRIGGER IF EXISTS trg_bandit_policies_updated_at ON bandit_policies;
CREATE TRIGGER trg_bandit_policies_updated_at
BEFORE UPDATE ON bandit_policies
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 11. Bandit Arms
-- 톰슨 샘플링의 arm 상태.
-- alpha/beta는 PostgreSQL에 저장하는 현재 학습 상태다.
-- ClickHouse는 reward 계산 원천 로그를 저장한다.
-- =========================================================

CREATE TABLE IF NOT EXISTS bandit_arms (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    bandit_policy_id BIGINT NOT NULL
        REFERENCES bandit_policies(id) ON DELETE CASCADE,

    action_id VARCHAR(128) NOT NULL
        REFERENCES action_catalog(action_id) ON DELETE RESTRICT,

    action_type VARCHAR(64) NOT NULL,

    status VARCHAR(64) NOT NULL DEFAULT 'active',

    alpha DOUBLE PRECISION NOT NULL DEFAULT 1.0 CHECK (alpha > 0),
    beta DOUBLE PRECISION NOT NULL DEFAULT 1.0 CHECK (beta > 0),

    impressions BIGINT NOT NULL DEFAULT 0 CHECK (impressions >= 0),
    conversions BIGINT NOT NULL DEFAULT 0 CHECK (conversions >= 0),
    failures BIGINT NOT NULL DEFAULT 0 CHECK (failures >= 0),

    last_sampled_value DOUBLE PRECISION,
    last_selected_at TIMESTAMPTZ,
    last_reward_updated_at TIMESTAMPTZ,

    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (bandit_policy_id, action_id)
);

CREATE INDEX IF NOT EXISTS idx_bandit_arms_policy_status
ON bandit_arms (bandit_policy_id, status);

CREATE INDEX IF NOT EXISTS idx_bandit_arms_project_action
ON bandit_arms (project_id, action_id);

DROP TRIGGER IF EXISTS trg_bandit_arms_updated_at ON bandit_arms;
CREATE TRIGGER trg_bandit_arms_updated_at
BEFORE UPDATE ON bandit_arms
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 12. Recommendation Results
-- 분석 결과 묶음.
-- 관리자 승인/거절 대상은 recommendation_results가 아니라 recommendation_actions다.
-- =========================================================

CREATE TABLE IF NOT EXISTS recommendation_results (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    baseline_start TIMESTAMPTZ,
    baseline_end TIMESTAMPTZ,

    segment_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    segment_hash VARCHAR(64) NOT NULL,

    -- 예: no_action, pending_actions, partially_executed, experiment_running, completed, dismissed
    status VARCHAR(64) NOT NULL,

    anomaly_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    root_causes_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    -- 원본 추천 응답 스냅샷.
    -- 액션별 상태의 source of truth는 recommendation_actions다.
    recommendations_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    -- 전체 정책 평가 스냅샷.
    -- 액션별 정책 상태는 recommendation_actions에도 풀어서 저장한다.
    policy_decision_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    -- 톰슨 샘플링이 사용된 경우의 전체 판단 스냅샷.
    bandit_decision_summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    summary_message TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_recommendation_results_project_status
ON recommendation_results (project_id, status);

CREATE INDEX IF NOT EXISTS idx_recommendation_results_project_created
ON recommendation_results (project_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_recommendation_results_segment_hash
ON recommendation_results (segment_hash);

CREATE INDEX IF NOT EXISTS gin_recommendation_results_segment_json
ON recommendation_results USING GIN (segment_json);

DROP TRIGGER IF EXISTS trg_recommendation_results_updated_at ON recommendation_results;
CREATE TRIGGER trg_recommendation_results_updated_at
BEFORE UPDATE ON recommendation_results
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 13. Recommendation Actions
-- 추천 결과 안에 포함된 개별 액션.
-- 관리자 승인/거절은 이 테이블에서 action 단위로 관리한다.
-- 톰슨 샘플링을 쓰는 경우 selected_by_strategy, bandit_arm_id로 추적한다.
-- =========================================================

CREATE TABLE IF NOT EXISTS recommendation_actions (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    recommendation_result_id BIGINT NOT NULL
        REFERENCES recommendation_results(id) ON DELETE CASCADE,

    action_id VARCHAR(128) NOT NULL,
    action_type VARCHAR(64) NOT NULL,

    title VARCHAR(255),
    description TEXT,
    target_step VARCHAR(128),

    priority_score DOUBLE PRECISION,
    expected_impact TEXT,
    rationale TEXT,

    triggered_by_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    execution_hint_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    experiment_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    policy_status VARCHAR(64),
    policy_reasons_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    policy_decision_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    -- 예: rule_based, thompson_sampling, manual
    selected_by_strategy VARCHAR(64) NOT NULL DEFAULT 'rule_based',

    bandit_policy_id BIGINT
        REFERENCES bandit_policies(id) ON DELETE SET NULL,

    bandit_arm_id BIGINT
        REFERENCES bandit_arms(id) ON DELETE SET NULL,

    sampled_value DOUBLE PRECISION,

    -- 예: pending_review, policy_blocked, auto_executed, approved, rejected, experiment_running, stopped
    status VARCHAR(64) NOT NULL DEFAULT 'pending_review',

    auto_executed_at TIMESTAMPTZ,

    reviewed_by VARCHAR(255),
    reviewed_at TIMESTAMPTZ,
    review_reason TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (recommendation_result_id, action_id)
);

CREATE INDEX IF NOT EXISTS idx_recommendation_actions_project_status
ON recommendation_actions (project_id, status);

CREATE INDEX IF NOT EXISTS idx_recommendation_actions_result
ON recommendation_actions (recommendation_result_id);

CREATE INDEX IF NOT EXISTS idx_recommendation_actions_result_status
ON recommendation_actions (recommendation_result_id, status);

CREATE INDEX IF NOT EXISTS idx_recommendation_actions_action
ON recommendation_actions (action_id);

CREATE INDEX IF NOT EXISTS idx_recommendation_actions_policy_status
ON recommendation_actions (policy_status);

CREATE INDEX IF NOT EXISTS idx_recommendation_actions_bandit_arm
ON recommendation_actions (bandit_arm_id);

DROP TRIGGER IF EXISTS trg_recommendation_actions_updated_at ON recommendation_actions;
CREATE TRIGGER trg_recommendation_actions_updated_at
BEFORE UPDATE ON recommendation_actions
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 14. Analysis Jobs
-- 비동기 분석 작업 상태.
-- 동기 API만 쓸 거면 MVP에서는 선택 사항.
-- =========================================================

CREATE TABLE IF NOT EXISTS analysis_jobs (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    status VARCHAR(32) NOT NULL DEFAULT 'queued',
    request_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    recommendation_result_id BIGINT
        REFERENCES recommendation_results(id) ON DELETE SET NULL,

    error_message TEXT,
    attempts BIGINT NOT NULL DEFAULT 0,
    max_attempts BIGINT NOT NULL DEFAULT 1,

    locked_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_analysis_jobs_project_id
ON analysis_jobs (project_id);

CREATE INDEX IF NOT EXISTS idx_analysis_jobs_status
ON analysis_jobs (status);

CREATE INDEX IF NOT EXISTS idx_analysis_jobs_recommendation_result
ON analysis_jobs (recommendation_result_id);

CREATE INDEX IF NOT EXISTS idx_analysis_jobs_status_created
ON analysis_jobs (status, created_at);

DROP TRIGGER IF EXISTS trg_analysis_jobs_updated_at ON analysis_jobs;
CREATE TRIGGER trg_analysis_jobs_updated_at
BEFORE UPDATE ON analysis_jobs
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 15. Experiments
-- 추천 액션이 자동 실행 또는 수동 승인되면 생성되는 실험.
-- recommendation_action_id를 핵심 연결 기준으로 사용한다.
-- =========================================================

CREATE TABLE IF NOT EXISTS experiments (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    recommendation_result_id BIGINT NOT NULL
        REFERENCES recommendation_results(id) ON DELETE CASCADE,

    recommendation_action_id BIGINT NOT NULL
        REFERENCES recommendation_actions(id) ON DELETE CASCADE,

    bandit_policy_id BIGINT
        REFERENCES bandit_policies(id) ON DELETE SET NULL,

    bandit_arm_id BIGINT
        REFERENCES bandit_arms(id) ON DELETE SET NULL,

    segment_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    segment_hash VARCHAR(64) NOT NULL,

    action_id VARCHAR(128) NOT NULL,
    action_type VARCHAR(64) NOT NULL,

    status VARCHAR(64) NOT NULL,

    traffic_split_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    primary_metric VARCHAR(128),
    guardrail_metrics_json JSONB NOT NULL DEFAULT '[]'::jsonb,

    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_experiments_recommendation_action
        UNIQUE (recommendation_action_id)
);

CREATE INDEX IF NOT EXISTS idx_experiments_project_status
ON experiments (project_id, status);

CREATE INDEX IF NOT EXISTS idx_experiments_recommendation_result
ON experiments (recommendation_result_id);

CREATE INDEX IF NOT EXISTS idx_experiments_recommendation_action
ON experiments (recommendation_action_id);

CREATE INDEX IF NOT EXISTS idx_experiments_segment_hash
ON experiments (segment_hash);

CREATE INDEX IF NOT EXISTS idx_experiments_bandit_arm
ON experiments (bandit_arm_id);

DROP TRIGGER IF EXISTS trg_experiments_updated_at ON experiments;
CREATE TRIGGER trg_experiments_updated_at
BEFORE UPDATE ON experiments
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 16. Bandit Decisions
-- 특정 추천/실험 시점에 톰슨 샘플링이 어떤 arm을 왜 선택했는지 기록한다.
-- alpha/beta 현재 상태는 bandit_arms에 있고,
-- 선택 순간의 sampled value와 후보별 sampled values는 여기에 남긴다.
-- =========================================================

CREATE TABLE IF NOT EXISTS bandit_decisions (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    bandit_policy_id BIGINT NOT NULL
        REFERENCES bandit_policies(id) ON DELETE CASCADE,

    selected_arm_id BIGINT NOT NULL
        REFERENCES bandit_arms(id) ON DELETE CASCADE,

    recommendation_result_id BIGINT
        REFERENCES recommendation_results(id) ON DELETE SET NULL,

    recommendation_action_id BIGINT
        REFERENCES recommendation_actions(id) ON DELETE SET NULL,

    experiment_id BIGINT
        REFERENCES experiments(id) ON DELETE SET NULL,

    segment_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    segment_hash VARCHAR(64) NOT NULL,

    sampled_values_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    selected_action_id VARCHAR(128) NOT NULL,
    selected_sampled_value DOUBLE PRECISION,

    -- reward는 ClickHouse events를 집계한 뒤 worker가 반영한다.
    reward_observed BOOLEAN NOT NULL DEFAULT false,
    reward_value DOUBLE PRECISION,
    reward_event_id VARCHAR(255),
    reward_observed_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bandit_decisions_policy_created
ON bandit_decisions (bandit_policy_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_bandit_decisions_project_created
ON bandit_decisions (project_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_bandit_decisions_recommendation_action
ON bandit_decisions (recommendation_action_id);

CREATE INDEX IF NOT EXISTS idx_bandit_decisions_experiment
ON bandit_decisions (experiment_id);

DROP TRIGGER IF EXISTS trg_bandit_decisions_updated_at ON bandit_decisions;
CREATE TRIGGER trg_bandit_decisions_updated_at
BEFORE UPDATE ON bandit_decisions
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 17. Segment Ad Mappings
-- 추천 서버가 쓰고, 광고 서버가 직접 읽는 핵심 테이블.
-- 광고 서버는 추천 서버 API를 호출하지 않는다.
-- runtime user segment/context와 이 테이블의 active mapping을 조합해 광고를 선택한다.
-- =========================================================

CREATE TABLE IF NOT EXISTS segment_ad_mappings (
    id BIGSERIAL PRIMARY KEY,
    project_id VARCHAR(128) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    segment_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    segment_hash VARCHAR(64) NOT NULL,

    recommendation_result_id BIGINT NOT NULL
        REFERENCES recommendation_results(id) ON DELETE CASCADE,

    recommendation_action_id BIGINT NOT NULL
        REFERENCES recommendation_actions(id) ON DELETE CASCADE,

    experiment_id BIGINT
        REFERENCES experiments(id) ON DELETE SET NULL,

    bandit_policy_id BIGINT
        REFERENCES bandit_policies(id) ON DELETE SET NULL,

    bandit_arm_id BIGINT
        REFERENCES bandit_arms(id) ON DELETE SET NULL,

    bandit_decision_id BIGINT
        REFERENCES bandit_decisions(id) ON DELETE SET NULL,

    campaign_id BIGINT
        REFERENCES campaigns(id) ON DELETE SET NULL,

    creative_id BIGINT
        REFERENCES ad_creatives(id) ON DELETE SET NULL,

    coupon_id BIGINT
        REFERENCES coupons(id) ON DELETE SET NULL,

    action_id VARCHAR(128) NOT NULL,
    action_type VARCHAR(64) NOT NULL,

    execution_hint_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    status VARCHAR(64) NOT NULL,
    source VARCHAR(64) NOT NULL,

    expires_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_segment_ad_mappings_recommendation_action
        UNIQUE (recommendation_action_id)
);

CREATE INDEX IF NOT EXISTS idx_segment_ad_mappings_project_status
ON segment_ad_mappings (project_id, status);

CREATE INDEX IF NOT EXISTS idx_segment_ad_mappings_project_segment_status
ON segment_ad_mappings (project_id, segment_hash, status);

CREATE INDEX IF NOT EXISTS idx_segment_ad_mappings_recommendation_result
ON segment_ad_mappings (recommendation_result_id);

CREATE INDEX IF NOT EXISTS idx_segment_ad_mappings_recommendation_action
ON segment_ad_mappings (recommendation_action_id);

CREATE INDEX IF NOT EXISTS idx_segment_ad_mappings_experiment
ON segment_ad_mappings (experiment_id);

CREATE INDEX IF NOT EXISTS idx_segment_ad_mappings_bandit_arm
ON segment_ad_mappings (bandit_arm_id);

CREATE INDEX IF NOT EXISTS idx_segment_ad_mappings_campaign
ON segment_ad_mappings (campaign_id);

CREATE INDEX IF NOT EXISTS idx_segment_ad_mappings_creative
ON segment_ad_mappings (creative_id);

CREATE INDEX IF NOT EXISTS gin_segment_ad_mappings_segment_json
ON segment_ad_mappings USING GIN (segment_json);

DROP TRIGGER IF EXISTS trg_segment_ad_mappings_updated_at ON segment_ad_mappings;
CREATE TRIGGER trg_segment_ad_mappings_updated_at
BEFORE UPDATE ON segment_ad_mappings
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
