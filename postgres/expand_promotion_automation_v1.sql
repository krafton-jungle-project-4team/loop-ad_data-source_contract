-- =========================================================
-- Promotion automation additive PostgreSQL expansion
-- Base contract: Loop-Ad PostgreSQL Schema Contract v1.10
-- Target contract: Loop-Ad PostgreSQL Schema Contract v1.11
--
-- Existing promotions remain manual. The migration is rerunnable and does
-- not create automation jobs for existing promotion runs.
-- =========================================================

BEGIN;

ALTER TABLE promotions
    ADD COLUMN IF NOT EXISTS execution_mode VARCHAR(20) NOT NULL DEFAULT 'manual',
    ADD COLUMN IF NOT EXISTS scheduled_start_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS scheduled_end_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS loop_interval_unit VARCHAR(20) NOT NULL DEFAULT 'day',
    ADD COLUMN IF NOT EXISTS loop_interval_value INT NOT NULL DEFAULT 1;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'campaigns'::regclass
          AND conname = 'chk_campaigns_schedule'
    ) THEN
        ALTER TABLE campaigns
            ADD CONSTRAINT chk_campaigns_schedule
            CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date);
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotions'::regclass
          AND conname = 'chk_promotions_execution_mode'
    ) THEN
        ALTER TABLE promotions
            ADD CONSTRAINT chk_promotions_execution_mode
            CHECK (execution_mode IN ('manual', 'automatic'));
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotions'::regclass
          AND conname = 'chk_promotions_schedule'
    ) THEN
        ALTER TABLE promotions
            ADD CONSTRAINT chk_promotions_schedule
            CHECK (
                scheduled_start_at IS NULL
                OR scheduled_end_at IS NULL
                OR scheduled_end_at > scheduled_start_at
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotions'::regclass
          AND conname = 'chk_promotions_loop_interval_unit'
    ) THEN
        ALTER TABLE promotions
            ADD CONSTRAINT chk_promotions_loop_interval_unit
            CHECK (loop_interval_unit IN ('hour', 'day'));
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotions'::regclass
          AND conname = 'chk_promotions_loop_interval_value'
    ) THEN
        ALTER TABLE promotions
            ADD CONSTRAINT chk_promotions_loop_interval_value
            CHECK (loop_interval_value >= 1);
    END IF;
END
$$;

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
        CHECK (status <> 'completed' OR completed_at IS NOT NULL),

    CONSTRAINT uq_promotion_automation_jobs_run_type
        UNIQUE (promotion_run_id, job_type)
);

CREATE INDEX IF NOT EXISTS idx_promotion_automation_jobs_claimable
ON promotion_automation_jobs (scheduled_at, created_at, job_id)
WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_promotion_automation_jobs_expired_lease
ON promotion_automation_jobs (lease_expires_at)
WHERE status = 'running';

COMMIT;
