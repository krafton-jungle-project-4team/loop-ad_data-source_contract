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
           OR jsonb_typeof(segment_scope_json) <> 'array'
           OR jsonb_array_length(segment_scope_json) = 0
           OR segment_scope_fingerprint !~ '^[0-9a-f]{64}$'
    ) THEN
        RAISE EXCEPTION
            'scope finalize failed: run backfill and validation first';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_runs AS pr
        WHERE pr.segment_scope_json <> (
            SELECT jsonb_agg(segment_id ORDER BY segment_id COLLATE "C")
            FROM (
                SELECT DISTINCT scope_value.segment_id
                FROM jsonb_array_elements_text(
                    pr.segment_scope_json
                ) AS scope_value(segment_id)
                WHERE btrim(scope_value.segment_id) <> ''
                  AND scope_value.segment_id = btrim(scope_value.segment_id)
            ) AS normalized
        )
           OR pr.segment_scope_fingerprint <> (
            SELECT encode(
                digest(
                    convert_to(
                        '[' || string_agg(
                            to_json(scope_value.segment_id)::text,
                            ',' ORDER BY scope_value.ordinality
                        ) || ']',
                        'UTF8'
                    ),
                    'sha256'
                ),
                'hex'
            )
            FROM jsonb_array_elements_text(
                pr.segment_scope_json
            ) WITH ORDINALITY AS scope_value(segment_id, ordinality)
        )
    ) THEN
        RAISE EXCEPTION
            'scope finalize failed: scope or fingerprint is not canonical';
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

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'chk_promotion_runs_segment_scope_json'
    ) THEN
        ALTER TABLE promotion_runs
            ADD CONSTRAINT chk_promotion_runs_segment_scope_json
            CHECK (
                jsonb_typeof(segment_scope_json) = 'array'
                AND jsonb_array_length(segment_scope_json) >= 1
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'chk_promotion_runs_segment_scope_fingerprint'
    ) THEN
        ALTER TABLE promotion_runs
            ADD CONSTRAINT chk_promotion_runs_segment_scope_fingerprint
            CHECK (segment_scope_fingerprint ~ '^[0-9a-f]{64}$');
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
