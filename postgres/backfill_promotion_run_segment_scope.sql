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
BEGIN
    IF EXISTS (
        SELECT 1
        FROM promotion_runs
        WHERE segment_scope_json IS NULL
           OR segment_scope_fingerprint IS NULL
    ) THEN
        RAISE EXCEPTION
            'scope backfill failed: every run needs a non-fallback experiment';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_runs
        WHERE NOT is_valid_promotion_run_segment_scope(
            segment_scope_json,
            segment_scope_fingerprint
        )
    ) THEN
        RAISE EXCEPTION
            'scope backfill failed: scope or fingerprint is not canonical';
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
            'scope backfill failed: composite scope duplicates exist';
    END IF;
END
$$;

COMMIT;
