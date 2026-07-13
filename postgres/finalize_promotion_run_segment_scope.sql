-- Phase 3: enforce the final segment-scope contract.
-- Rerunnable. Run only after the backfill validation succeeds.

BEGIN;

LOCK TABLE promotion_runs IN SHARE ROW EXCLUSIVE MODE;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM promotion_runs
        WHERE segment_scope_json IS NULL
           OR segment_scope_fingerprint IS NULL
           OR NOT is_valid_promotion_run_segment_scope(
                segment_scope_json,
                segment_scope_fingerprint
           )
    ) THEN
        RAISE EXCEPTION
            'scope finalize failed: run backfill and validation first';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_runs
        GROUP BY
            project_id,
            promotion_id,
            analysis_id,
            generation_id,
            segment_scope_fingerprint,
            loop_count
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION
            'scope finalize failed: composite scope duplicates exist';
    END IF;
END
$$;

ALTER TABLE promotion_runs
    ALTER COLUMN segment_scope_json SET NOT NULL,
    ALTER COLUMN segment_scope_fingerprint SET NOT NULL;

ALTER TABLE promotion_runs
    DROP CONSTRAINT IF EXISTS chk_promotion_runs_segment_scope_json,
    DROP CONSTRAINT IF EXISTS chk_promotion_runs_segment_scope_fingerprint;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'chk_promotion_runs_segment_scope'
    ) THEN
        ALTER TABLE promotion_runs
            ADD CONSTRAINT chk_promotion_runs_segment_scope
            CHECK (is_valid_promotion_run_segment_scope(
                segment_scope_json,
                segment_scope_fingerprint
            ));
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'uq_promotion_runs_segment_scope'
    ) THEN
        IF EXISTS (
            SELECT 1
            FROM pg_class AS index_relation
            JOIN pg_namespace AS index_namespace
              ON index_namespace.oid = index_relation.relnamespace
            WHERE index_relation.relkind = 'i'
              AND index_relation.relname = 'uq_promotion_runs_segment_scope'
              AND index_namespace.nspname = current_schema()
        ) THEN
            DROP INDEX uq_promotion_runs_segment_scope;
        END IF;

        ALTER TABLE promotion_runs
            ADD CONSTRAINT uq_promotion_runs_segment_scope
            UNIQUE (
                project_id,
                promotion_id,
                analysis_id,
                generation_id,
                segment_scope_fingerprint,
                loop_count
            );
    END IF;
END
$$;

ALTER TABLE promotion_runs
    DROP CONSTRAINT IF EXISTS uq_promotion_runs_loop;

CREATE INDEX IF NOT EXISTS idx_promotion_runs_promotion_loop
ON promotion_runs (promotion_id, loop_count);

COMMIT;
