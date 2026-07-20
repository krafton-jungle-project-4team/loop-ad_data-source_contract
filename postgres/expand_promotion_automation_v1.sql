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
