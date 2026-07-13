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
        UNIQUE (promotion_run_id, request_fingerprint)
);

ALTER TABLE user_segment_assignments
    ADD COLUMN IF NOT EXISTS segment_assignment_execution_id VARCHAR(100);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'user_segment_assignments'::regclass
          AND conname = 'fk_user_segment_assignments_execution'
    ) THEN
        ALTER TABLE user_segment_assignments
            ADD CONSTRAINT fk_user_segment_assignments_execution
            FOREIGN KEY (segment_assignment_execution_id)
            REFERENCES segment_assignment_executions (
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
