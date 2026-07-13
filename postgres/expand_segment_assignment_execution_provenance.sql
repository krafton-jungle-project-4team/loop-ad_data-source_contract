BEGIN;

CREATE TABLE IF NOT EXISTS segment_assignment_executions (
    segment_assignment_execution_id VARCHAR(100) PRIMARY KEY,
    promotion_run_id VARCHAR(100) NOT NULL,
    request_fingerprint VARCHAR(64) NOT NULL,
    input_fingerprint VARCHAR(64) NOT NULL,
    matcher_strategy VARCHAR(100) NOT NULL,
    matcher_version VARCHAR(100) NOT NULL,
    vector_version VARCHAR(50) NOT NULL,
    source_cutoff_at TIMESTAMPTZ NOT NULL,
    input_manifest_json JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_assignment_executions_run
        FOREIGN KEY (promotion_run_id)
        REFERENCES promotion_runs (promotion_run_id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,

    CONSTRAINT chk_segment_assignment_executions_identifiers
        CHECK (
            btrim(segment_assignment_execution_id) <> ''
            AND btrim(promotion_run_id) <> ''
            AND btrim(matcher_strategy) <> ''
            AND btrim(matcher_version) <> ''
            AND btrim(vector_version) <> ''
        ),

    CONSTRAINT chk_segment_assignment_executions_fingerprints
        CHECK (
            request_fingerprint ~ '^[0-9a-f]{64}$'
            AND input_fingerprint ~ '^[0-9a-f]{64}$'
        ),

    CONSTRAINT chk_segment_assignment_executions_input_manifest
        CHECK (jsonb_typeof(input_manifest_json) = 'object'),

    CONSTRAINT uq_segment_assignment_executions_run_request
        UNIQUE (promotion_run_id, request_fingerprint),

    CONSTRAINT uq_segment_assignment_executions_run_execution
        UNIQUE (promotion_run_id, segment_assignment_execution_id)
);

ALTER TABLE user_segment_assignments
    ADD COLUMN IF NOT EXISTS segment_assignment_execution_id VARCHAR(100);

DO $$
DECLARE
    execution_run_attnum SMALLINT;
    execution_id_attnum SMALLINT;
BEGIN
    SELECT attnum INTO STRICT execution_run_attnum
    FROM pg_attribute
    WHERE attrelid = 'segment_assignment_executions'::regclass
      AND attname = 'promotion_run_id'
      AND NOT attisdropped;

    SELECT attnum INTO STRICT execution_id_attnum
    FROM pg_attribute
    WHERE attrelid = 'segment_assignment_executions'::regclass
      AND attname = 'segment_assignment_execution_id'
      AND NOT attisdropped;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'segment_assignment_executions'::regclass
          AND conname = 'uq_segment_assignment_executions_run_execution'
          AND contype = 'u'
          AND conkey = ARRAY[
              execution_run_attnum,
              execution_id_attnum
          ]::SMALLINT[]
    ) THEN
        ALTER TABLE segment_assignment_executions
            DROP CONSTRAINT IF EXISTS
            uq_segment_assignment_executions_run_execution;

        ALTER TABLE segment_assignment_executions
            ADD CONSTRAINT uq_segment_assignment_executions_run_execution
            UNIQUE (promotion_run_id, segment_assignment_execution_id);
    END IF;
END
$$;

DO $$
DECLARE
    assignment_run_attnum SMALLINT;
    assignment_execution_attnum SMALLINT;
    execution_run_attnum SMALLINT;
    execution_id_attnum SMALLINT;
BEGIN
    SELECT attnum INTO STRICT assignment_run_attnum
    FROM pg_attribute
    WHERE attrelid = 'user_segment_assignments'::regclass
      AND attname = 'promotion_run_id'
      AND NOT attisdropped;

    SELECT attnum INTO STRICT assignment_execution_attnum
    FROM pg_attribute
    WHERE attrelid = 'user_segment_assignments'::regclass
      AND attname = 'segment_assignment_execution_id'
      AND NOT attisdropped;

    SELECT attnum INTO STRICT execution_run_attnum
    FROM pg_attribute
    WHERE attrelid = 'segment_assignment_executions'::regclass
      AND attname = 'promotion_run_id'
      AND NOT attisdropped;

    SELECT attnum INTO STRICT execution_id_attnum
    FROM pg_attribute
    WHERE attrelid = 'segment_assignment_executions'::regclass
      AND attname = 'segment_assignment_execution_id'
      AND NOT attisdropped;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'user_segment_assignments'::regclass
          AND conname = 'fk_user_segment_assignments_execution'
          AND contype = 'f'
          AND confrelid = 'segment_assignment_executions'::regclass
          AND conkey = ARRAY[
              assignment_run_attnum,
              assignment_execution_attnum
          ]::SMALLINT[]
          AND confkey = ARRAY[
              execution_run_attnum,
              execution_id_attnum
          ]::SMALLINT[]
          AND confmatchtype = 's'
          AND confupdtype = 'a'
          AND confdeltype = 'a'
          AND convalidated
    ) THEN
        ALTER TABLE user_segment_assignments
            DROP CONSTRAINT IF EXISTS
            fk_user_segment_assignments_execution;

        ALTER TABLE user_segment_assignments
            ADD CONSTRAINT fk_user_segment_assignments_execution
            FOREIGN KEY (
                promotion_run_id,
                segment_assignment_execution_id
            )
            REFERENCES segment_assignment_executions (
                promotion_run_id,
                segment_assignment_execution_id
            )
            ON UPDATE NO ACTION
            ON DELETE NO ACTION;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_user_segment_assignments_execution_id
ON user_segment_assignments (segment_assignment_execution_id);

COMMIT;
