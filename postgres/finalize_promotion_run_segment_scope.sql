-- Phase 3: enforce the final segment-scope contract.
-- Rerunnable. Run only after the backfill validation succeeds.

BEGIN;

LOCK TABLE promotion_runs IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE ad_experiments IN SHARE MODE;

DO $$
DECLARE
    invalid_promotion_run_id promotion_runs.promotion_run_id%TYPE;
BEGIN
    SELECT promotion_run_id
    INTO invalid_promotion_run_id
    FROM promotion_runs
    WHERE segment_scope_json IS NULL
       OR segment_scope_fingerprint IS NULL
       OR NOT is_valid_promotion_run_segment_scope(
            segment_scope_json,
            segment_scope_fingerprint
       )
    ORDER BY promotion_run_id
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'scope finalize failed [canonical_scope]: promotion_run_id=%',
            invalid_promotion_run_id;
    END IF;

    SELECT pr.promotion_run_id
    INTO invalid_promotion_run_id
    FROM promotion_runs AS pr
    WHERE (
        SELECT count(*)
        FROM ad_experiments AS ae
        WHERE ae.promotion_run_id = pr.promotion_run_id
          AND ae.segment_id <> 'seg_existing_all'
    ) <> jsonb_array_length(pr.segment_scope_json)
       OR EXISTS (
            SELECT scope_segment.segment_id
            FROM jsonb_array_elements_text(
                pr.segment_scope_json
            ) AS scope_segment(segment_id)
            EXCEPT
            SELECT ae.segment_id
            FROM ad_experiments AS ae
            WHERE ae.promotion_run_id = pr.promotion_run_id
              AND ae.segment_id <> 'seg_existing_all'
       )
       OR EXISTS (
            SELECT ae.segment_id
            FROM ad_experiments AS ae
            WHERE ae.promotion_run_id = pr.promotion_run_id
              AND ae.segment_id <> 'seg_existing_all'
            EXCEPT
            SELECT scope_segment.segment_id
            FROM jsonb_array_elements_text(
                pr.segment_scope_json
            ) AS scope_segment(segment_id)
       )
    ORDER BY pr.promotion_run_id
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'scope finalize failed [target_scope_mismatch]: promotion_run_id=%',
            invalid_promotion_run_id;
    END IF;

    SELECT pr.promotion_run_id
    INTO invalid_promotion_run_id
    FROM promotion_runs AS pr
    WHERE (
        SELECT count(*)
        FROM ad_experiments AS ae
        WHERE ae.promotion_run_id = pr.promotion_run_id
          AND ae.segment_id = 'seg_existing_all'
    ) <> 1
    ORDER BY pr.promotion_run_id
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'scope finalize failed [fallback_experiment_count]: promotion_run_id=%',
            invalid_promotion_run_id;
    END IF;

    SELECT pr.promotion_run_id
    INTO invalid_promotion_run_id
    FROM promotion_runs AS pr
    WHERE EXISTS (
        SELECT 1
        FROM promotion_runs AS duplicate
        WHERE duplicate.project_id = pr.project_id
          AND duplicate.promotion_id = pr.promotion_id
          AND duplicate.analysis_id = pr.analysis_id
          AND duplicate.generation_id = pr.generation_id
          AND duplicate.segment_scope_fingerprint =
              pr.segment_scope_fingerprint
          AND duplicate.loop_count = pr.loop_count
          AND duplicate.promotion_run_id <> pr.promotion_run_id
    )
    ORDER BY pr.promotion_run_id
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'scope finalize failed [composite_identity_duplicate]: promotion_run_id=%',
            invalid_promotion_run_id;
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
