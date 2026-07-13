-- Phase 1: expand promotion_runs for segment-scoped dual writes.
-- Rerunnable. Keep uq_promotion_runs_loop until the finalize phase.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION is_valid_promotion_run_segment_scope(
    p_segment_scope_json JSONB,
    p_segment_scope_fingerprint TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
    scope_item JSONB;
    segment_id TEXT;
    canonical_scope_json JSONB;
    canonical_scope_serialized TEXT;
BEGIN
    IF jsonb_typeof(p_segment_scope_json) <> 'array'
       OR jsonb_array_length(p_segment_scope_json) = 0 THEN
        RETURN false;
    END IF;

    FOR scope_item IN
        SELECT value
        FROM jsonb_array_elements(p_segment_scope_json) AS scope_items(value)
    LOOP
        IF jsonb_typeof(scope_item) <> 'string' THEN
            RETURN false;
        END IF;

        segment_id := scope_item #>> '{}';
        IF btrim(segment_id) = ''
           OR segment_id <> btrim(segment_id)
           OR segment_id = 'seg_existing_all' THEN
            RETURN false;
        END IF;
    END LOOP;

    SELECT
        jsonb_agg(
            normalized.segment_id
            ORDER BY normalized.segment_id COLLATE "C"
        ),
        '[' || string_agg(
            to_json(normalized.segment_id)::text,
            ',' ORDER BY normalized.segment_id COLLATE "C"
        ) || ']'
    INTO canonical_scope_json, canonical_scope_serialized
    FROM (
        SELECT DISTINCT scope_values.value #>> '{}' AS segment_id
        FROM jsonb_array_elements(p_segment_scope_json) AS scope_values(value)
    ) AS normalized;

    RETURN p_segment_scope_json = canonical_scope_json
       AND p_segment_scope_fingerprint = encode(
            digest(
                convert_to(canonical_scope_serialized, 'UTF8'),
                'sha256'
            ),
            'hex'
       );
END
$$;

ALTER TABLE promotion_runs
    ADD COLUMN IF NOT EXISTS segment_scope_json JSONB;

ALTER TABLE promotion_runs
    ADD COLUMN IF NOT EXISTS segment_scope_fingerprint VARCHAR(64);

COMMIT;
