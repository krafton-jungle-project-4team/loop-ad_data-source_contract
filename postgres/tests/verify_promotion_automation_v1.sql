\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.expect_failure(
    p_statement TEXT,
    p_expected_sqlstate TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    actual_sqlstate TEXT;
BEGIN
    BEGIN
        EXECUTE p_statement;
    EXCEPTION WHEN OTHERS THEN
        actual_sqlstate := SQLSTATE;
        IF p_expected_sqlstate IS NOT NULL
           AND actual_sqlstate <> p_expected_sqlstate THEN
            RAISE EXCEPTION
                'expected SQLSTATE %, received % for: %',
                p_expected_sqlstate,
                actual_sqlstate,
                p_statement;
        END IF;
        RETURN;
    END;

    RAISE EXCEPTION 'statement unexpectedly succeeded: %', p_statement;
END
$$;

DO $$
DECLARE
    invalid_count INT;
BEGIN
    SELECT count(*)
    INTO invalid_count
    FROM promotions
    WHERE execution_mode <> 'manual'
       OR loop_interval_unit <> 'day'
       OR loop_interval_value <> 1;

    IF invalid_count <> 0 THEN
        RAISE EXCEPTION
            'existing promotions did not retain manual automation defaults';
    END IF;

    IF to_regclass('promotion_automation_jobs') IS NULL THEN
        RAISE EXCEPTION 'promotion_automation_jobs table is missing';
    END IF;

    IF to_regclass('idx_promotion_automation_jobs_claimable') IS NULL
       OR to_regclass('idx_promotion_automation_jobs_expired_lease') IS NULL THEN
        RAISE EXCEPTION 'promotion automation job indexes are missing';
    END IF;

    IF to_regprocedure('loopad_campaign_start_at(date)') IS NULL
       OR to_regprocedure('loopad_campaign_end_at(date)') IS NULL THEN
        RAISE EXCEPTION 'campaign schedule boundary functions are missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'promotions'::regclass
          AND tgname = 'trg_promotions_campaign_schedule'
          AND NOT tgisinternal
    ) OR NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'campaigns'::regclass
          AND tgname = 'trg_campaigns_promotion_schedules'
          AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION 'campaign promotion schedule triggers are missing';
    END IF;
END
$$;

UPDATE campaigns
SET start_date = DATE '2026-07-01',
    end_date = DATE '2026-08-31'
WHERE campaign_id = 'camp_expedia_hotel_demo';

UPDATE promotions
SET execution_mode = 'automatic',
    scheduled_start_at = TIMESTAMPTZ '2026-08-01 09:00:00+09',
    scheduled_end_at = TIMESTAMPTZ '2026-08-07 23:59:00+09',
    loop_interval_unit = 'hour',
    loop_interval_value = 6
WHERE promotion_id = 'promo_expedia_email_reactivation';

SELECT pg_temp.expect_failure(
    $statement$
    UPDATE promotions
    SET scheduled_start_at = TIMESTAMPTZ '2026-06-30 23:59:00+09'
    WHERE promotion_id = 'promo_expedia_email_reactivation'
    $statement$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $statement$
    UPDATE promotions
    SET scheduled_end_at = TIMESTAMPTZ '2026-09-01 00:01:00+09'
    WHERE promotion_id = 'promo_expedia_email_reactivation'
    $statement$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $statement$
    UPDATE campaigns
    SET end_date = DATE '2026-07-31'
    WHERE campaign_id = 'camp_expedia_hotel_demo'
    $statement$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $statement$
    UPDATE promotions
    SET execution_mode = 'unsupported'
    WHERE promotion_id = 'promo_expedia_email_reactivation'
    $statement$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $statement$
    UPDATE promotions
    SET scheduled_end_at = scheduled_start_at
    WHERE promotion_id = 'promo_expedia_email_reactivation'
    $statement$,
    '23514'
);

SELECT pg_temp.expect_failure(
    $statement$
    UPDATE promotions
    SET loop_interval_value = 0
    WHERE promotion_id = 'promo_expedia_email_reactivation'
    $statement$,
    '23514'
);

INSERT INTO promotion_automation_jobs (
    job_id,
    promotion_run_id,
    job_type,
    scheduled_at
)
VALUES (
    'automation_job_launch_email_a1',
    'run_email_a1',
    'launch_run',
    TIMESTAMPTZ '2026-08-01 00:00:00+00'
);

SELECT pg_temp.expect_failure(
    $statement$
    INSERT INTO promotion_automation_jobs (
        job_id,
        promotion_run_id,
        job_type,
        scheduled_at
    ) VALUES (
        'automation_job_launch_email_a1_duplicate',
        'run_email_a1',
        'launch_run',
        TIMESTAMPTZ '2026-08-01 00:00:00+00'
    )
    $statement$,
    '23505'
);

SELECT pg_temp.expect_failure(
    $statement$
    UPDATE promotion_automation_jobs
    SET status = 'running'
    WHERE job_id = 'automation_job_launch_email_a1'
    $statement$,
    '23514'
);

UPDATE promotion_automation_jobs
SET status = 'running',
    attempt_count = attempt_count + 1,
    worker_id = 'contract-worker',
    lease_token = gen_random_uuid(),
    locked_at = now(),
    lease_expires_at = now() + interval '5 minutes'
WHERE job_id = 'automation_job_launch_email_a1';

SELECT pg_temp.expect_failure(
    $statement$
    UPDATE promotion_automation_jobs
    SET status = 'completed'
    WHERE job_id = 'automation_job_launch_email_a1'
    $statement$,
    '23514'
);

UPDATE promotion_automation_jobs
SET status = 'completed',
    completed_at = now(),
    worker_id = NULL,
    lease_token = NULL,
    locked_at = NULL,
    lease_expires_at = NULL
WHERE job_id = 'automation_job_launch_email_a1';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM promotion_automation_jobs
        WHERE job_id = 'automation_job_launch_email_a1'
          AND status = 'completed'
          AND attempt_count = 1
          AND completed_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'promotion automation job lifecycle is invalid';
    END IF;
END
$$;

ROLLBACK;
