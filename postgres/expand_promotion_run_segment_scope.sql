-- Phase 1: expand promotion_runs for segment-scoped dual writes.
-- Rerunnable. Keep uq_promotion_runs_loop until the finalize phase.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- seg_existing_all is a global FK target shared by every project. Ordinary
-- segment definitions remain project-scoped through the CHECK constraint.
ALTER TABLE segment_definitions
    ALTER COLUMN project_id DROP NOT NULL;

ALTER TABLE segment_definitions
    DROP CONSTRAINT IF EXISTS chk_segment_definitions_project_scope;

INSERT INTO segment_definitions (
    segment_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_name,
    source,
    query_preview_id,
    natural_language_query,
    generated_sql,
    rule_json,
    profile_json,
    sample_size,
    total_eligible_user_count,
    sample_ratio,
    status
)
VALUES (
    'seg_existing_all',
    NULL,
    NULL,
    NULL,
    'All existing users',
    'system_default',
    NULL,
    NULL,
    NULL,
    '{"type": "all_existing_users"}'::jsonb,
    '{"description": "Global fallback for all existing users."}'::jsonb,
    0,
    0,
    0,
    'active'
)
ON CONFLICT (segment_id) DO UPDATE SET
    project_id = NULL,
    campaign_id = NULL,
    promotion_id = NULL,
    segment_name = EXCLUDED.segment_name,
    source = EXCLUDED.source,
    query_preview_id = NULL,
    natural_language_query = NULL,
    generated_sql = NULL,
    rule_json = EXCLUDED.rule_json,
    profile_json = EXCLUDED.profile_json,
    sample_size = EXCLUDED.sample_size,
    total_eligible_user_count = EXCLUDED.total_eligible_user_count,
    sample_ratio = EXCLUDED.sample_ratio,
    status = EXCLUDED.status,
    updated_at = now();

ALTER TABLE segment_definitions
    ADD CONSTRAINT chk_segment_definitions_project_scope
    CHECK (
        (
            segment_id = 'seg_existing_all'
            AND project_id IS NULL
            AND campaign_id IS NULL
            AND promotion_id IS NULL
            AND query_preview_id IS NULL
            AND source = 'system_default'
        )
        OR (
            segment_id <> 'seg_existing_all'
            AND project_id IS NOT NULL
        )
    );

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
