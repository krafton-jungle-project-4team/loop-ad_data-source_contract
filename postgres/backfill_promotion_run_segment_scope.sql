-- Phase 2: reconstruct normalized non-fallback segment scopes for legacy rows.
-- Rerunnable. Apply only after Decision dual-writes both scope columns.

BEGIN;

LOCK TABLE promotion_runs IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE ad_experiments IN SHARE MODE;

WITH distinct_segments AS (
    SELECT DISTINCT
        promotion_run_id,
        segment_id
    FROM ad_experiments
    WHERE segment_id <> 'seg_existing_all'
), normalized_scopes AS (
    SELECT
        promotion_run_id,
        jsonb_agg(segment_id ORDER BY segment_id COLLATE "C") AS scope_json,
        '[' || string_agg(
            to_json(segment_id)::text,
            ',' ORDER BY segment_id COLLATE "C"
        ) || ']' AS scope_serialized
    FROM distinct_segments
    GROUP BY promotion_run_id
)
UPDATE promotion_runs AS pr
SET segment_scope_json = scopes.scope_json,
    segment_scope_fingerprint = encode(
        digest(convert_to(scopes.scope_serialized, 'UTF8'), 'sha256'),
        'hex'
    )
FROM normalized_scopes AS scopes
WHERE scopes.promotion_run_id = pr.promotion_run_id;

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
            'scope backfill failed [canonical_scope]: promotion_run_id=%',
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
            'scope backfill failed [target_scope_mismatch]: promotion_run_id=%',
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
            'scope backfill failed [fallback_experiment_count]: promotion_run_id=%',
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
            'scope backfill failed [composite_identity_duplicate]: promotion_run_id=%',
            invalid_promotion_run_id;
    END IF;
END
$$;

COMMIT;
