-- =========================================================
-- Segment Audience V2 additive PostgreSQL expansion
-- Base contract: Loop-Ad PostgreSQL Schema Contract v1.6
-- Target contract: Loop-Ad PostgreSQL Schema Contract v1.7
--
-- This migration is additive and intentionally performs no data backfill.
-- =========================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;

DO $$
DECLARE
    vector_extversion TEXT;
    vector_version_parts INT[];
BEGIN
    SELECT extversion
    INTO vector_extversion
    FROM pg_extension
    WHERE extname = 'vector';

    IF vector_extversion IS NULL THEN
        RAISE EXCEPTION 'pgvector extension is required';
    END IF;

    vector_version_parts := string_to_array(
        regexp_replace(vector_extversion, '[^0-9.].*$', ''),
        '.'
    )::INT[];

    IF vector_version_parts < ARRAY[0, 8, 0] THEN
        RAISE EXCEPTION
            'pgvector >= 0.8.0 is required, found %',
            vector_extversion;
    END IF;
END
$$;

ALTER TABLE segment_vectors
    ADD COLUMN IF NOT EXISTS embedding vector(64);

ALTER TABLE promotion_segment_suggestions
    ADD COLUMN IF NOT EXISTS audience_snapshot_id VARCHAR(100);

ALTER TABLE promotion_target_segments
    ADD COLUMN IF NOT EXISTS audience_snapshot_id VARCHAR(100);

DO $$
DECLARE
    actual_type TEXT;
BEGIN
    SELECT format_type(attribute.atttypid, attribute.atttypmod)
    INTO actual_type
    FROM pg_attribute AS attribute
    WHERE attribute.attrelid = 'segment_vectors'::regclass
      AND attribute.attname = 'embedding'
      AND NOT attribute.attisdropped;

    IF actual_type IS DISTINCT FROM 'vector(64)' THEN
        RAISE EXCEPTION
            'segment_vectors.embedding must be vector(64), found %',
            actual_type;
    END IF;

    SELECT format_type(attribute.atttypid, attribute.atttypmod)
    INTO actual_type
    FROM pg_attribute AS attribute
    WHERE attribute.attrelid = 'promotion_segment_suggestions'::regclass
      AND attribute.attname = 'audience_snapshot_id'
      AND NOT attribute.attisdropped;

    IF actual_type IS DISTINCT FROM 'character varying(100)' THEN
        RAISE EXCEPTION
            'promotion_segment_suggestions.audience_snapshot_id must be varchar(100), found %',
            actual_type;
    END IF;

    SELECT format_type(attribute.atttypid, attribute.atttypmod)
    INTO actual_type
    FROM pg_attribute AS attribute
    WHERE attribute.attrelid = 'promotion_target_segments'::regclass
      AND attribute.attname = 'audience_snapshot_id'
      AND NOT attribute.attisdropped;

    IF actual_type IS DISTINCT FROM 'character varying(100)' THEN
        RAISE EXCEPTION
            'promotion_target_segments.audience_snapshot_id must be varchar(100), found %',
            actual_type;
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS user_behavior_vector_search_generations (
    vector_generation_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    vector_version VARCHAR(50) NOT NULL,
    manifest_hash VARCHAR(128) NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    source_revision_cutoff TIMESTAMPTZ NOT NULL,
    expected_user_count INT NOT NULL,
    synced_user_count INT NOT NULL DEFAULT 0,
    invalid_user_count INT NOT NULL DEFAULT 0,
    last_user_id VARCHAR(255),
    status VARCHAR(50) NOT NULL DEFAULT 'in_progress',
    is_active BOOLEAN NOT NULL DEFAULT false,
    failure_reason TEXT,
    activated_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_user_behavior_vector_search_generations_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT chk_user_behavior_vector_search_generations_expected_count
        CHECK (expected_user_count >= 0),

    CONSTRAINT chk_user_behavior_vector_search_generations_synced_count
        CHECK (synced_user_count >= 0),

    CONSTRAINT chk_user_behavior_vector_search_generations_invalid_count
        CHECK (invalid_user_count >= 0),

    CONSTRAINT chk_user_behavior_vector_search_generations_status
        CHECK (status IN ('in_progress', 'activated', 'superseded', 'failed'))
);

ALTER TABLE user_behavior_vector_search_generations
    ADD COLUMN IF NOT EXISTS vector_generation_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS project_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS vector_version VARCHAR(50),
    ADD COLUMN IF NOT EXISTS manifest_hash VARCHAR(128),
    ADD COLUMN IF NOT EXISTS window_start TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS window_end TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS source_revision_cutoff TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS expected_user_count INT,
    ADD COLUMN IF NOT EXISTS synced_user_count INT DEFAULT 0,
    ADD COLUMN IF NOT EXISTS invalid_user_count INT DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_user_id VARCHAR(255),
    ADD COLUMN IF NOT EXISTS status VARCHAR(50) DEFAULT 'in_progress',
    ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS failure_reason TEXT,
    ADD COLUMN IF NOT EXISTS activated_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now(),
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();

CREATE TABLE IF NOT EXISTS user_behavior_vector_search (
    vector_generation_id VARCHAR(100) NOT NULL,
    project_id VARCHAR(100) NOT NULL,
    user_id VARCHAR(255) NOT NULL,
    vector_version VARCHAR(50) NOT NULL,
    vector_dim INT NOT NULL DEFAULT 64,
    embedding vector(64) NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    source_vector_row_id VARCHAR(100) NOT NULL,
    source_updated_at TIMESTAMPTZ NOT NULL,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_user_behavior_vector_search_generation
        FOREIGN KEY (vector_generation_id)
        REFERENCES user_behavior_vector_search_generations (vector_generation_id),

    CONSTRAINT fk_user_behavior_vector_search_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT chk_user_behavior_vector_search_dim
        CHECK (vector_dim = 64),

    CONSTRAINT uq_user_behavior_vector_search_generation_user
        UNIQUE (vector_generation_id, user_id)
);

ALTER TABLE user_behavior_vector_search
    ADD COLUMN IF NOT EXISTS vector_generation_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS project_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS user_id VARCHAR(255),
    ADD COLUMN IF NOT EXISTS vector_version VARCHAR(50),
    ADD COLUMN IF NOT EXISTS vector_dim INT DEFAULT 64,
    ADD COLUMN IF NOT EXISTS embedding vector(64),
    ADD COLUMN IF NOT EXISTS window_start TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS window_end TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS source_vector_row_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS source_updated_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS source_ingested_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS synced_at TIMESTAMPTZ DEFAULT now();

CREATE TABLE IF NOT EXISTS segment_audience_snapshots (
    snapshot_id VARCHAR(100) PRIMARY KEY,
    suggestion_id VARCHAR(100),
    analysis_id VARCHAR(100) NOT NULL,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    segment_vector_id VARCHAR(100) NOT NULL,
    vector_generation_id VARCHAR(100) NOT NULL,

    schema_version VARCHAR(50) NOT NULL,
    vector_version VARCHAR(50) NOT NULL,
    manifest_hash VARCHAR(128) NOT NULL,
    audience_resolution_contract VARCHAR(100) NOT NULL,
    segment_audience_spec_hash VARCHAR(128) NOT NULL,
    query_vector_hash VARCHAR(128) NOT NULL,
    query_compiler_version VARCHAR(100) NOT NULL,
    query_compiler_hash VARCHAR(128) NOT NULL,
    matcher_version VARCHAR(100) NOT NULL,
    search_policy_version VARCHAR(100) NOT NULL,
    calibration_version VARCHAR(100) NOT NULL,
    calibration_hash VARCHAR(128) NOT NULL,
    score_threshold NUMERIC(10, 6) NOT NULL,

    source_cutoff TIMESTAMPTZ NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    eligible_user_count INT NOT NULL,
    behavior_match_count INT NOT NULL,
    final_user_count INT NOT NULL,
    min_sample_size INT NOT NULL,

    audience_status VARCHAR(50) NOT NULL,
    selection_method VARCHAR(50) NOT NULL,
    estimated_recall NUMERIC(10, 6) NOT NULL,
    recall_lower_bound NUMERIC(10, 6) NOT NULL,
    recall_target NUMERIC(10, 6) NOT NULL,
    input_fingerprint VARCHAR(128) NOT NULL,
    meets_min_sample_size BOOLEAN NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'completed',
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_audience_snapshots_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT fk_segment_audience_snapshots_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_segment_audience_snapshots_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_segment_audience_snapshots_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_segment_audience_snapshots_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT fk_segment_audience_snapshots_segment_vector
        FOREIGN KEY (segment_vector_id) REFERENCES segment_vectors (segment_vector_id),

    CONSTRAINT fk_segment_audience_snapshots_vector_generation
        FOREIGN KEY (vector_generation_id)
        REFERENCES user_behavior_vector_search_generations (vector_generation_id),

    CONSTRAINT chk_segment_audience_snapshots_eligible_count
        CHECK (eligible_user_count >= 0),

    CONSTRAINT chk_segment_audience_snapshots_behavior_match_count
        CHECK (
            behavior_match_count >= 0
            AND behavior_match_count <= eligible_user_count
        ),

    CONSTRAINT chk_segment_audience_snapshots_final_count
        CHECK (
            final_user_count >= 0
            AND final_user_count <= behavior_match_count
        ),

    CONSTRAINT chk_segment_audience_snapshots_min_sample_size
        CHECK (min_sample_size >= 0),

    CONSTRAINT chk_segment_audience_snapshots_audience_status
        CHECK (audience_status IN (
            'no_eligible_audience',
            'insufficient_sample',
            'targetable'
        )),

    CONSTRAINT chk_segment_audience_snapshots_selection_method
        CHECK (selection_method IN ('exact', 'transition', 'ann', 'exact_fallback')),

    CONSTRAINT chk_segment_audience_snapshots_status
        CHECK (status = 'completed')
);

ALTER TABLE segment_audience_snapshots
    ADD COLUMN IF NOT EXISTS snapshot_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS suggestion_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS analysis_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS project_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS campaign_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS promotion_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS segment_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS segment_vector_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS vector_generation_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS schema_version VARCHAR(50),
    ADD COLUMN IF NOT EXISTS vector_version VARCHAR(50),
    ADD COLUMN IF NOT EXISTS manifest_hash VARCHAR(128),
    ADD COLUMN IF NOT EXISTS audience_resolution_contract VARCHAR(100),
    ADD COLUMN IF NOT EXISTS segment_audience_spec_hash VARCHAR(128),
    ADD COLUMN IF NOT EXISTS query_vector_hash VARCHAR(128),
    ADD COLUMN IF NOT EXISTS query_compiler_version VARCHAR(100),
    ADD COLUMN IF NOT EXISTS query_compiler_hash VARCHAR(128),
    ADD COLUMN IF NOT EXISTS matcher_version VARCHAR(100),
    ADD COLUMN IF NOT EXISTS search_policy_version VARCHAR(100),
    ADD COLUMN IF NOT EXISTS calibration_version VARCHAR(100),
    ADD COLUMN IF NOT EXISTS calibration_hash VARCHAR(128),
    ADD COLUMN IF NOT EXISTS score_threshold NUMERIC(10, 6),
    ADD COLUMN IF NOT EXISTS source_cutoff TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS window_start TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS window_end TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS eligible_user_count INT,
    ADD COLUMN IF NOT EXISTS behavior_match_count INT,
    ADD COLUMN IF NOT EXISTS final_user_count INT,
    ADD COLUMN IF NOT EXISTS min_sample_size INT,
    ADD COLUMN IF NOT EXISTS audience_status VARCHAR(50),
    ADD COLUMN IF NOT EXISTS selection_method VARCHAR(50),
    ADD COLUMN IF NOT EXISTS estimated_recall NUMERIC(10, 6),
    ADD COLUMN IF NOT EXISTS recall_lower_bound NUMERIC(10, 6),
    ADD COLUMN IF NOT EXISTS recall_target NUMERIC(10, 6),
    ADD COLUMN IF NOT EXISTS input_fingerprint VARCHAR(128),
    ADD COLUMN IF NOT EXISTS meets_min_sample_size BOOLEAN,
    ADD COLUMN IF NOT EXISTS status VARCHAR(50) DEFAULT 'completed',
    ADD COLUMN IF NOT EXISTS metadata_json JSONB DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now();

CREATE TABLE IF NOT EXISTS segment_audience_members (
    snapshot_id VARCHAR(100) NOT NULL,
    user_id VARCHAR(255) NOT NULL,
    behavior_fit_score NUMERIC(10, 6),
    retrieval_source VARCHAR(50) NOT NULL,
    retrieval_rank INT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_audience_members_snapshot
        FOREIGN KEY (snapshot_id) REFERENCES segment_audience_snapshots (snapshot_id),

    CONSTRAINT chk_segment_audience_members_score
        CHECK (
            behavior_fit_score IS NULL
            OR (behavior_fit_score >= -1 AND behavior_fit_score <= 1)
        ),

    CONSTRAINT chk_segment_audience_members_retrieval_source
        CHECK (retrieval_source IN ('exact', 'ann')),

    CONSTRAINT chk_segment_audience_members_retrieval_rank
        CHECK (retrieval_rank IS NULL OR retrieval_rank >= 1),

    CONSTRAINT uq_segment_audience_members_snapshot_user
        UNIQUE (snapshot_id, user_id)
);

ALTER TABLE segment_audience_members
    ADD COLUMN IF NOT EXISTS snapshot_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS user_id VARCHAR(255),
    ADD COLUMN IF NOT EXISTS behavior_fit_score NUMERIC(10, 6),
    ADD COLUMN IF NOT EXISTS retrieval_source VARCHAR(50),
    ADD COLUMN IF NOT EXISTS retrieval_rank INT,
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now();

ALTER TABLE user_behavior_vector_search_generations
    ALTER COLUMN vector_generation_id SET NOT NULL,
    ALTER COLUMN project_id SET NOT NULL,
    ALTER COLUMN vector_version SET NOT NULL,
    ALTER COLUMN manifest_hash SET NOT NULL,
    ALTER COLUMN window_start SET NOT NULL,
    ALTER COLUMN window_end SET NOT NULL,
    ALTER COLUMN source_revision_cutoff SET NOT NULL,
    ALTER COLUMN expected_user_count SET NOT NULL,
    ALTER COLUMN synced_user_count SET DEFAULT 0,
    ALTER COLUMN synced_user_count SET NOT NULL,
    ALTER COLUMN invalid_user_count SET DEFAULT 0,
    ALTER COLUMN invalid_user_count SET NOT NULL,
    ALTER COLUMN status SET DEFAULT 'in_progress',
    ALTER COLUMN status SET NOT NULL,
    ALTER COLUMN is_active SET DEFAULT false,
    ALTER COLUMN is_active SET NOT NULL,
    ALTER COLUMN created_at SET DEFAULT now(),
    ALTER COLUMN created_at SET NOT NULL,
    ALTER COLUMN updated_at SET DEFAULT now(),
    ALTER COLUMN updated_at SET NOT NULL;

ALTER TABLE user_behavior_vector_search
    ALTER COLUMN vector_generation_id SET NOT NULL,
    ALTER COLUMN project_id SET NOT NULL,
    ALTER COLUMN user_id SET NOT NULL,
    ALTER COLUMN vector_version SET NOT NULL,
    ALTER COLUMN vector_dim SET DEFAULT 64,
    ALTER COLUMN vector_dim SET NOT NULL,
    ALTER COLUMN embedding SET NOT NULL,
    ALTER COLUMN window_start SET NOT NULL,
    ALTER COLUMN window_end SET NOT NULL,
    ALTER COLUMN source_vector_row_id SET NOT NULL,
    ALTER COLUMN source_updated_at SET NOT NULL,
    ALTER COLUMN source_ingested_at SET NOT NULL,
    ALTER COLUMN synced_at SET DEFAULT now(),
    ALTER COLUMN synced_at SET NOT NULL;

ALTER TABLE segment_audience_snapshots
    ALTER COLUMN snapshot_id SET NOT NULL,
    ALTER COLUMN analysis_id SET NOT NULL,
    ALTER COLUMN project_id SET NOT NULL,
    ALTER COLUMN campaign_id SET NOT NULL,
    ALTER COLUMN promotion_id SET NOT NULL,
    ALTER COLUMN segment_id SET NOT NULL,
    ALTER COLUMN segment_vector_id SET NOT NULL,
    ALTER COLUMN vector_generation_id SET NOT NULL,
    ALTER COLUMN schema_version SET NOT NULL,
    ALTER COLUMN vector_version SET NOT NULL,
    ALTER COLUMN manifest_hash SET NOT NULL,
    ALTER COLUMN audience_resolution_contract SET NOT NULL,
    ALTER COLUMN segment_audience_spec_hash SET NOT NULL,
    ALTER COLUMN query_vector_hash SET NOT NULL,
    ALTER COLUMN query_compiler_version SET NOT NULL,
    ALTER COLUMN query_compiler_hash SET NOT NULL,
    ALTER COLUMN matcher_version SET NOT NULL,
    ALTER COLUMN search_policy_version SET NOT NULL,
    ALTER COLUMN calibration_version SET NOT NULL,
    ALTER COLUMN calibration_hash SET NOT NULL,
    ALTER COLUMN score_threshold SET NOT NULL,
    ALTER COLUMN source_cutoff SET NOT NULL,
    ALTER COLUMN window_start SET NOT NULL,
    ALTER COLUMN window_end SET NOT NULL,
    ALTER COLUMN eligible_user_count SET NOT NULL,
    ALTER COLUMN behavior_match_count SET NOT NULL,
    ALTER COLUMN final_user_count SET NOT NULL,
    ALTER COLUMN min_sample_size SET NOT NULL,
    ALTER COLUMN audience_status SET NOT NULL,
    ALTER COLUMN selection_method SET NOT NULL,
    ALTER COLUMN estimated_recall SET NOT NULL,
    ALTER COLUMN recall_lower_bound SET NOT NULL,
    ALTER COLUMN recall_target SET NOT NULL,
    ALTER COLUMN input_fingerprint SET NOT NULL,
    ALTER COLUMN meets_min_sample_size SET NOT NULL,
    ALTER COLUMN status SET DEFAULT 'completed',
    ALTER COLUMN status SET NOT NULL,
    ALTER COLUMN metadata_json SET DEFAULT '{}'::jsonb,
    ALTER COLUMN metadata_json SET NOT NULL,
    ALTER COLUMN created_at SET DEFAULT now(),
    ALTER COLUMN created_at SET NOT NULL;

ALTER TABLE segment_audience_members
    ALTER COLUMN snapshot_id SET NOT NULL,
    ALTER COLUMN user_id SET NOT NULL,
    ALTER COLUMN retrieval_source SET NOT NULL,
    ALTER COLUMN created_at SET DEFAULT now(),
    ALTER COLUMN created_at SET NOT NULL;

ALTER TABLE segment_vectors
    DROP CONSTRAINT IF EXISTS chk_segment_vectors_source;

ALTER TABLE segment_vectors
    ADD CONSTRAINT chk_segment_vectors_source
    CHECK (source IN (
        'decision_analysis',
        'fixture',
        'manual',
        'batch_profile',
        'behavior_query'
    ));

ALTER TABLE user_segment_assignments
    DROP CONSTRAINT IF EXISTS chk_user_segment_assignments_source;

ALTER TABLE user_segment_assignments
    ADD CONSTRAINT chk_user_segment_assignments_source
    CHECK (assignment_source IN (
        'decision_batch',
        'fallback',
        'manual',
        'fixture',
        'analysis_snapshot'
    ));

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_behavior_vector_search_generations'::regclass
          AND conname = 'user_behavior_vector_search_generations_pkey'
    ) THEN
        ALTER TABLE user_behavior_vector_search_generations
            ADD CONSTRAINT user_behavior_vector_search_generations_pkey
            PRIMARY KEY (vector_generation_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_behavior_vector_search_generations'::regclass
          AND conname = 'fk_user_behavior_vector_search_generations_project'
    ) THEN
        ALTER TABLE user_behavior_vector_search_generations
            ADD CONSTRAINT fk_user_behavior_vector_search_generations_project
            FOREIGN KEY (project_id) REFERENCES projects (project_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_behavior_vector_search_generations'::regclass
          AND conname = 'chk_user_behavior_vector_search_generations_expected_count'
    ) THEN
        ALTER TABLE user_behavior_vector_search_generations
            ADD CONSTRAINT chk_user_behavior_vector_search_generations_expected_count
            CHECK (expected_user_count >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_behavior_vector_search_generations'::regclass
          AND conname = 'chk_user_behavior_vector_search_generations_synced_count'
    ) THEN
        ALTER TABLE user_behavior_vector_search_generations
            ADD CONSTRAINT chk_user_behavior_vector_search_generations_synced_count
            CHECK (synced_user_count >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_behavior_vector_search_generations'::regclass
          AND conname = 'chk_user_behavior_vector_search_generations_invalid_count'
    ) THEN
        ALTER TABLE user_behavior_vector_search_generations
            ADD CONSTRAINT chk_user_behavior_vector_search_generations_invalid_count
            CHECK (invalid_user_count >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_behavior_vector_search_generations'::regclass
          AND conname = 'chk_user_behavior_vector_search_generations_status'
    ) THEN
        ALTER TABLE user_behavior_vector_search_generations
            ADD CONSTRAINT chk_user_behavior_vector_search_generations_status
            CHECK (status IN ('in_progress', 'activated', 'superseded', 'failed'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_behavior_vector_search'::regclass
          AND conname = 'fk_user_behavior_vector_search_generation'
    ) THEN
        ALTER TABLE user_behavior_vector_search
            ADD CONSTRAINT fk_user_behavior_vector_search_generation
            FOREIGN KEY (vector_generation_id)
            REFERENCES user_behavior_vector_search_generations (vector_generation_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_behavior_vector_search'::regclass
          AND conname = 'fk_user_behavior_vector_search_project'
    ) THEN
        ALTER TABLE user_behavior_vector_search
            ADD CONSTRAINT fk_user_behavior_vector_search_project
            FOREIGN KEY (project_id) REFERENCES projects (project_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_behavior_vector_search'::regclass
          AND conname = 'chk_user_behavior_vector_search_dim'
    ) THEN
        ALTER TABLE user_behavior_vector_search
            ADD CONSTRAINT chk_user_behavior_vector_search_dim
            CHECK (vector_dim = 64);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_behavior_vector_search'::regclass
          AND conname = 'uq_user_behavior_vector_search_generation_user'
    ) THEN
        ALTER TABLE user_behavior_vector_search
            ADD CONSTRAINT uq_user_behavior_vector_search_generation_user
            UNIQUE (vector_generation_id, user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'segment_audience_snapshots_pkey'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT segment_audience_snapshots_pkey
            PRIMARY KEY (snapshot_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'fk_segment_audience_snapshots_analysis'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT fk_segment_audience_snapshots_analysis
            FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'fk_segment_audience_snapshots_project'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT fk_segment_audience_snapshots_project
            FOREIGN KEY (project_id) REFERENCES projects (project_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'fk_segment_audience_snapshots_campaign'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT fk_segment_audience_snapshots_campaign
            FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'fk_segment_audience_snapshots_promotion'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT fk_segment_audience_snapshots_promotion
            FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'fk_segment_audience_snapshots_segment'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT fk_segment_audience_snapshots_segment
            FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'fk_segment_audience_snapshots_segment_vector'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT fk_segment_audience_snapshots_segment_vector
            FOREIGN KEY (segment_vector_id) REFERENCES segment_vectors (segment_vector_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'fk_segment_audience_snapshots_vector_generation'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT fk_segment_audience_snapshots_vector_generation
            FOREIGN KEY (vector_generation_id)
            REFERENCES user_behavior_vector_search_generations (vector_generation_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_eligible_count'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_eligible_count
            CHECK (eligible_user_count >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_behavior_match_count'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_behavior_match_count
            CHECK (
                behavior_match_count >= 0
                AND behavior_match_count <= eligible_user_count
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_final_count'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_final_count
            CHECK (
                final_user_count >= 0
                AND final_user_count <= behavior_match_count
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_min_sample_size'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_min_sample_size
            CHECK (min_sample_size >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_audience_status'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_audience_status
            CHECK (audience_status IN (
                'no_eligible_audience',
                'insufficient_sample',
                'targetable'
            ));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_selection_method'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_selection_method
            CHECK (selection_method IN ('exact', 'transition', 'ann', 'exact_fallback'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_status'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_status
            CHECK (status = 'completed');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_members'::regclass
          AND conname = 'fk_segment_audience_members_snapshot'
    ) THEN
        ALTER TABLE segment_audience_members
            ADD CONSTRAINT fk_segment_audience_members_snapshot
            FOREIGN KEY (snapshot_id) REFERENCES segment_audience_snapshots (snapshot_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_members'::regclass
          AND conname = 'chk_segment_audience_members_score'
    ) THEN
        ALTER TABLE segment_audience_members
            ADD CONSTRAINT chk_segment_audience_members_score
            CHECK (
                behavior_fit_score IS NULL
                OR (behavior_fit_score >= -1 AND behavior_fit_score <= 1)
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_members'::regclass
          AND conname = 'chk_segment_audience_members_retrieval_source'
    ) THEN
        ALTER TABLE segment_audience_members
            ADD CONSTRAINT chk_segment_audience_members_retrieval_source
            CHECK (retrieval_source IN ('exact', 'ann'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_members'::regclass
          AND conname = 'chk_segment_audience_members_retrieval_rank'
    ) THEN
        ALTER TABLE segment_audience_members
            ADD CONSTRAINT chk_segment_audience_members_retrieval_rank
            CHECK (retrieval_rank IS NULL OR retrieval_rank >= 1);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_members'::regclass
          AND conname = 'uq_segment_audience_members_snapshot_user'
    ) THEN
        ALTER TABLE segment_audience_members
            ADD CONSTRAINT uq_segment_audience_members_snapshot_user
            UNIQUE (snapshot_id, user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'promotion_segment_suggestions'::regclass
          AND conname = 'fk_promotion_segment_suggestions_audience_snapshot'
    ) THEN
        ALTER TABLE promotion_segment_suggestions
            ADD CONSTRAINT fk_promotion_segment_suggestions_audience_snapshot
            FOREIGN KEY (audience_snapshot_id)
            REFERENCES segment_audience_snapshots (snapshot_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'promotion_target_segments'::regclass
          AND conname = 'fk_promotion_target_segments_audience_snapshot'
    ) THEN
        ALTER TABLE promotion_target_segments
            ADD CONSTRAINT fk_promotion_target_segments_audience_snapshot
            FOREIGN KEY (audience_snapshot_id)
            REFERENCES segment_audience_snapshots (snapshot_id);
    END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_behavior_vector_search_generations_active
ON user_behavior_vector_search_generations (project_id, vector_version)
WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_user_behavior_vector_search_embedding_hnsw
ON user_behavior_vector_search
USING hnsw (embedding vector_cosine_ops);

DO $$
DECLARE
    incompatible_columns TEXT;
    incompatible_constraints TEXT;
    active_generation_index_definition TEXT;
    search_hnsw_index_definition TEXT;
BEGIN
    WITH type_groups (relation_name, expected_type, column_names) AS (
        VALUES
            (
                'user_behavior_vector_search_generations',
                'character varying(100)',
                ARRAY['vector_generation_id', 'project_id']
            ),
            (
                'user_behavior_vector_search_generations',
                'character varying(50)',
                ARRAY['vector_version', 'status']
            ),
            (
                'user_behavior_vector_search_generations',
                'character varying(128)',
                ARRAY['manifest_hash']
            ),
            (
                'user_behavior_vector_search_generations',
                'timestamp with time zone',
                ARRAY[
                    'window_start', 'window_end', 'source_revision_cutoff',
                    'activated_at', 'created_at', 'updated_at'
                ]
            ),
            (
                'user_behavior_vector_search_generations',
                'integer',
                ARRAY[
                    'expected_user_count', 'synced_user_count',
                    'invalid_user_count'
                ]
            ),
            (
                'user_behavior_vector_search_generations',
                'character varying(255)',
                ARRAY['last_user_id']
            ),
            (
                'user_behavior_vector_search_generations',
                'boolean',
                ARRAY['is_active']
            ),
            (
                'user_behavior_vector_search_generations',
                'text',
                ARRAY['failure_reason']
            ),
            (
                'user_behavior_vector_search',
                'character varying(100)',
                ARRAY[
                    'vector_generation_id', 'project_id',
                    'source_vector_row_id'
                ]
            ),
            (
                'user_behavior_vector_search',
                'character varying(255)',
                ARRAY['user_id']
            ),
            (
                'user_behavior_vector_search',
                'character varying(50)',
                ARRAY['vector_version']
            ),
            (
                'user_behavior_vector_search',
                'integer',
                ARRAY['vector_dim']
            ),
            (
                'user_behavior_vector_search',
                'vector(64)',
                ARRAY['embedding']
            ),
            (
                'user_behavior_vector_search',
                'timestamp with time zone',
                ARRAY[
                    'window_start', 'window_end', 'source_updated_at',
                    'source_ingested_at', 'synced_at'
                ]
            ),
            (
                'segment_audience_snapshots',
                'character varying(100)',
                ARRAY[
                    'snapshot_id', 'suggestion_id', 'analysis_id', 'project_id',
                    'campaign_id', 'promotion_id', 'segment_id',
                    'segment_vector_id', 'vector_generation_id',
                    'audience_resolution_contract', 'query_compiler_version',
                    'matcher_version', 'search_policy_version',
                    'calibration_version'
                ]
            ),
            (
                'segment_audience_snapshots',
                'character varying(50)',
                ARRAY[
                    'schema_version', 'vector_version', 'audience_status',
                    'selection_method', 'status'
                ]
            ),
            (
                'segment_audience_snapshots',
                'character varying(128)',
                ARRAY[
                    'manifest_hash', 'segment_audience_spec_hash',
                    'query_vector_hash', 'query_compiler_hash',
                    'calibration_hash', 'input_fingerprint'
                ]
            ),
            (
                'segment_audience_snapshots',
                'numeric(10,6)',
                ARRAY[
                    'score_threshold', 'estimated_recall',
                    'recall_lower_bound', 'recall_target'
                ]
            ),
            (
                'segment_audience_snapshots',
                'timestamp with time zone',
                ARRAY['source_cutoff', 'window_start', 'window_end', 'created_at']
            ),
            (
                'segment_audience_snapshots',
                'integer',
                ARRAY[
                    'eligible_user_count', 'behavior_match_count',
                    'final_user_count', 'min_sample_size'
                ]
            ),
            (
                'segment_audience_snapshots',
                'boolean',
                ARRAY['meets_min_sample_size']
            ),
            (
                'segment_audience_snapshots',
                'jsonb',
                ARRAY['metadata_json']
            ),
            (
                'segment_audience_members',
                'character varying(100)',
                ARRAY['snapshot_id']
            ),
            (
                'segment_audience_members',
                'character varying(255)',
                ARRAY['user_id']
            ),
            (
                'segment_audience_members',
                'numeric(10,6)',
                ARRAY['behavior_fit_score']
            ),
            (
                'segment_audience_members',
                'character varying(50)',
                ARRAY['retrieval_source']
            ),
            (
                'segment_audience_members',
                'integer',
                ARRAY['retrieval_rank']
            ),
            (
                'segment_audience_members',
                'timestamp with time zone',
                ARRAY['created_at']
            ),
            (
                'segment_vectors',
                'vector(64)',
                ARRAY['embedding']
            ),
            (
                'promotion_segment_suggestions',
                'character varying(100)',
                ARRAY['audience_snapshot_id']
            ),
            (
                'promotion_target_segments',
                'character varying(100)',
                ARRAY['audience_snapshot_id']
            )
    ),
    expected_types AS (
        SELECT
            type_groups.relation_name,
            type_groups.expected_type,
            unnest(type_groups.column_names) AS column_name
        FROM type_groups
    ),
    nullability_groups (relation_name, expected_not_null, column_names) AS (
        VALUES
            (
                'user_behavior_vector_search_generations',
                true,
                ARRAY[
                    'vector_generation_id', 'project_id', 'vector_version',
                    'manifest_hash', 'window_start', 'window_end',
                    'source_revision_cutoff', 'expected_user_count',
                    'synced_user_count', 'invalid_user_count', 'status',
                    'is_active', 'created_at', 'updated_at'
                ]
            ),
            (
                'user_behavior_vector_search_generations',
                false,
                ARRAY['last_user_id', 'failure_reason', 'activated_at']
            ),
            (
                'user_behavior_vector_search',
                true,
                ARRAY[
                    'vector_generation_id', 'project_id', 'user_id',
                    'vector_version', 'vector_dim', 'embedding', 'window_start',
                    'window_end', 'source_vector_row_id', 'source_updated_at',
                    'source_ingested_at', 'synced_at'
                ]
            ),
            (
                'segment_audience_snapshots',
                false,
                ARRAY['suggestion_id']
            ),
            (
                'segment_audience_snapshots',
                true,
                ARRAY[
                    'snapshot_id', 'analysis_id', 'project_id', 'campaign_id',
                    'promotion_id', 'segment_id', 'segment_vector_id',
                    'vector_generation_id', 'schema_version', 'vector_version',
                    'manifest_hash', 'audience_resolution_contract',
                    'segment_audience_spec_hash', 'query_vector_hash',
                    'query_compiler_version', 'query_compiler_hash',
                    'matcher_version', 'search_policy_version',
                    'calibration_version', 'calibration_hash',
                    'score_threshold', 'source_cutoff', 'window_start',
                    'window_end', 'eligible_user_count', 'behavior_match_count',
                    'final_user_count', 'min_sample_size', 'audience_status',
                    'selection_method', 'estimated_recall', 'recall_lower_bound',
                    'recall_target', 'input_fingerprint',
                    'meets_min_sample_size', 'status', 'metadata_json',
                    'created_at'
                ]
            ),
            (
                'segment_audience_members',
                true,
                ARRAY['snapshot_id', 'user_id', 'retrieval_source', 'created_at']
            ),
            (
                'segment_audience_members',
                false,
                ARRAY['behavior_fit_score', 'retrieval_rank']
            ),
            (
                'segment_vectors',
                false,
                ARRAY['embedding']
            ),
            (
                'promotion_segment_suggestions',
                false,
                ARRAY['audience_snapshot_id']
            ),
            (
                'promotion_target_segments',
                false,
                ARRAY['audience_snapshot_id']
            )
    ),
    expected_nullability AS (
        SELECT
            nullability_groups.relation_name,
            nullability_groups.expected_not_null,
            unnest(nullability_groups.column_names) AS column_name
        FROM nullability_groups
    ),
    incompatible_type_columns AS (
        SELECT
            expected_types.relation_name,
            expected_types.column_name
        FROM expected_types
        LEFT JOIN pg_attribute AS actual
          ON actual.attrelid = to_regclass(expected_types.relation_name)
         AND actual.attname = expected_types.column_name
         AND NOT actual.attisdropped
        WHERE actual.attnum IS NULL
           OR format_type(actual.atttypid, actual.atttypmod)
              <> expected_types.expected_type
    ),
    incompatible_nullability_columns AS (
        SELECT
            expected_nullability.relation_name,
            expected_nullability.column_name
        FROM expected_nullability
        LEFT JOIN pg_attribute AS actual
          ON actual.attrelid = to_regclass(expected_nullability.relation_name)
         AND actual.attname = expected_nullability.column_name
         AND NOT actual.attisdropped
        WHERE actual.attnum IS NULL
           OR actual.attnotnull IS DISTINCT FROM
              expected_nullability.expected_not_null
    ),
    incompatible AS (
        SELECT * FROM incompatible_type_columns
        UNION
        SELECT * FROM incompatible_nullability_columns
    )
    SELECT string_agg(
        format('%s.%s', incompatible.relation_name, incompatible.column_name),
        ', '
        ORDER BY incompatible.relation_name, incompatible.column_name
    )
    INTO incompatible_columns
    FROM incompatible;

    IF incompatible_columns IS NOT NULL THEN
        RAISE EXCEPTION
            'incompatible Segment Audience V2 column definition(s): %',
            incompatible_columns;
    END IF;

    WITH expected (
        relation_name,
        constraint_name,
        constraint_type,
        constraint_definition
    ) AS (
        VALUES
            (
                'user_behavior_vector_search_generations',
                'user_behavior_vector_search_generations_pkey',
                'p',
                'PRIMARY KEY (vector_generation_id)'
            ),
            (
                'user_behavior_vector_search_generations',
                'fk_user_behavior_vector_search_generations_project',
                'f',
                'FOREIGN KEY (project_id) REFERENCES projects(project_id)'
            ),
            (
                'user_behavior_vector_search_generations',
                'chk_user_behavior_vector_search_generations_expected_count',
                'c',
                'CHECK (expected_user_count >= 0)'
            ),
            (
                'user_behavior_vector_search_generations',
                'chk_user_behavior_vector_search_generations_synced_count',
                'c',
                'CHECK (synced_user_count >= 0)'
            ),
            (
                'user_behavior_vector_search_generations',
                'chk_user_behavior_vector_search_generations_invalid_count',
                'c',
                'CHECK (invalid_user_count >= 0)'
            ),
            (
                'user_behavior_vector_search_generations',
                'chk_user_behavior_vector_search_generations_status',
                'c',
                'CHECK (status::text = ANY (ARRAY[''in_progress''::character varying, ''activated''::character varying, ''superseded''::character varying, ''failed''::character varying]::text[]))'
            ),
            (
                'user_behavior_vector_search',
                'fk_user_behavior_vector_search_generation',
                'f',
                'FOREIGN KEY (vector_generation_id) REFERENCES user_behavior_vector_search_generations(vector_generation_id)'
            ),
            (
                'user_behavior_vector_search',
                'fk_user_behavior_vector_search_project',
                'f',
                'FOREIGN KEY (project_id) REFERENCES projects(project_id)'
            ),
            (
                'user_behavior_vector_search',
                'chk_user_behavior_vector_search_dim',
                'c',
                'CHECK (vector_dim = 64)'
            ),
            (
                'user_behavior_vector_search',
                'uq_user_behavior_vector_search_generation_user',
                'u',
                'UNIQUE (vector_generation_id, user_id)'
            ),
            (
                'segment_audience_snapshots',
                'segment_audience_snapshots_pkey',
                'p',
                'PRIMARY KEY (snapshot_id)'
            ),
            (
                'segment_audience_snapshots',
                'fk_segment_audience_snapshots_analysis',
                'f',
                'FOREIGN KEY (analysis_id) REFERENCES promotion_analyses(analysis_id)'
            ),
            (
                'segment_audience_snapshots',
                'fk_segment_audience_snapshots_project',
                'f',
                'FOREIGN KEY (project_id) REFERENCES projects(project_id)'
            ),
            (
                'segment_audience_snapshots',
                'fk_segment_audience_snapshots_campaign',
                'f',
                'FOREIGN KEY (campaign_id) REFERENCES campaigns(campaign_id)'
            ),
            (
                'segment_audience_snapshots',
                'fk_segment_audience_snapshots_promotion',
                'f',
                'FOREIGN KEY (promotion_id) REFERENCES promotions(promotion_id)'
            ),
            (
                'segment_audience_snapshots',
                'fk_segment_audience_snapshots_segment',
                'f',
                'FOREIGN KEY (segment_id) REFERENCES segment_definitions(segment_id)'
            ),
            (
                'segment_audience_snapshots',
                'fk_segment_audience_snapshots_segment_vector',
                'f',
                'FOREIGN KEY (segment_vector_id) REFERENCES segment_vectors(segment_vector_id)'
            ),
            (
                'segment_audience_snapshots',
                'fk_segment_audience_snapshots_vector_generation',
                'f',
                'FOREIGN KEY (vector_generation_id) REFERENCES user_behavior_vector_search_generations(vector_generation_id)'
            ),
            (
                'segment_audience_snapshots',
                'chk_segment_audience_snapshots_eligible_count',
                'c',
                'CHECK (eligible_user_count >= 0)'
            ),
            (
                'segment_audience_snapshots',
                'chk_segment_audience_snapshots_behavior_match_count',
                'c',
                'CHECK (behavior_match_count >= 0 AND behavior_match_count <= eligible_user_count)'
            ),
            (
                'segment_audience_snapshots',
                'chk_segment_audience_snapshots_final_count',
                'c',
                'CHECK (final_user_count >= 0 AND final_user_count <= behavior_match_count)'
            ),
            (
                'segment_audience_snapshots',
                'chk_segment_audience_snapshots_min_sample_size',
                'c',
                'CHECK (min_sample_size >= 0)'
            ),
            (
                'segment_audience_snapshots',
                'chk_segment_audience_snapshots_audience_status',
                'c',
                'CHECK (audience_status::text = ANY (ARRAY[''no_eligible_audience''::character varying, ''insufficient_sample''::character varying, ''targetable''::character varying]::text[]))'
            ),
            (
                'segment_audience_snapshots',
                'chk_segment_audience_snapshots_selection_method',
                'c',
                'CHECK (selection_method::text = ANY (ARRAY[''exact''::character varying, ''transition''::character varying, ''ann''::character varying, ''exact_fallback''::character varying]::text[]))'
            ),
            (
                'segment_audience_snapshots',
                'chk_segment_audience_snapshots_status',
                'c',
                'CHECK (status::text = ''completed''::text)'
            ),
            (
                'segment_audience_members',
                'fk_segment_audience_members_snapshot',
                'f',
                'FOREIGN KEY (snapshot_id) REFERENCES segment_audience_snapshots(snapshot_id)'
            ),
            (
                'segment_audience_members',
                'chk_segment_audience_members_score',
                'c',
                'CHECK (behavior_fit_score IS NULL OR behavior_fit_score >= ''-1''::integer::numeric AND behavior_fit_score <= 1::numeric)'
            ),
            (
                'segment_audience_members',
                'chk_segment_audience_members_retrieval_source',
                'c',
                'CHECK (retrieval_source::text = ANY (ARRAY[''exact''::character varying, ''ann''::character varying]::text[]))'
            ),
            (
                'segment_audience_members',
                'chk_segment_audience_members_retrieval_rank',
                'c',
                'CHECK (retrieval_rank IS NULL OR retrieval_rank >= 1)'
            ),
            (
                'segment_audience_members',
                'uq_segment_audience_members_snapshot_user',
                'u',
                'UNIQUE (snapshot_id, user_id)'
            ),
            (
                'promotion_segment_suggestions',
                'fk_promotion_segment_suggestions_audience_snapshot',
                'f',
                'FOREIGN KEY (audience_snapshot_id) REFERENCES segment_audience_snapshots(snapshot_id)'
            ),
            (
                'promotion_target_segments',
                'fk_promotion_target_segments_audience_snapshot',
                'f',
                'FOREIGN KEY (audience_snapshot_id) REFERENCES segment_audience_snapshots(snapshot_id)'
            ),
            (
                'segment_vectors',
                'chk_segment_vectors_source',
                'c',
                'CHECK (source::text = ANY (ARRAY[''decision_analysis''::character varying, ''fixture''::character varying, ''manual''::character varying, ''batch_profile''::character varying, ''behavior_query''::character varying]::text[]))'
            ),
            (
                'user_segment_assignments',
                'chk_user_segment_assignments_source',
                'c',
                'CHECK (assignment_source::text = ANY (ARRAY[''decision_batch''::character varying, ''fallback''::character varying, ''manual''::character varying, ''fixture''::character varying, ''analysis_snapshot''::character varying]::text[]))'
            )
    )
    SELECT string_agg(
        format('%s.%s', expected.relation_name, expected.constraint_name),
        ', '
        ORDER BY expected.relation_name, expected.constraint_name
    )
    INTO incompatible_constraints
    FROM expected
    LEFT JOIN pg_constraint AS actual
      ON actual.conrelid = to_regclass(expected.relation_name)
     AND actual.conname = expected.constraint_name
    WHERE actual.oid IS NULL
       OR actual.contype::TEXT <> expected.constraint_type
       OR pg_get_constraintdef(actual.oid, true) <> expected.constraint_definition;

    IF incompatible_constraints IS NOT NULL THEN
        RAISE EXCEPTION
            'incompatible Segment Audience V2 constraint definition(s): %',
            incompatible_constraints;
    END IF;

    SELECT pg_get_indexdef(index_rel.oid)
    INTO active_generation_index_definition
    FROM pg_class AS index_rel
    JOIN pg_namespace AS index_namespace
      ON index_namespace.oid = index_rel.relnamespace
    WHERE index_namespace.nspname = 'public'
      AND index_rel.relname = 'uq_user_behavior_vector_search_generations_active';

    IF active_generation_index_definition IS DISTINCT FROM
        'CREATE UNIQUE INDEX uq_user_behavior_vector_search_generations_active ON public.user_behavior_vector_search_generations USING btree (project_id, vector_version) WHERE (is_active = true)'
    THEN
        RAISE EXCEPTION
            'incompatible index definition: uq_user_behavior_vector_search_generations_active';
    END IF;

    SELECT pg_get_indexdef(index_rel.oid)
    INTO search_hnsw_index_definition
    FROM pg_class AS index_rel
    JOIN pg_namespace AS index_namespace
      ON index_namespace.oid = index_rel.relnamespace
    WHERE index_namespace.nspname = 'public'
      AND index_rel.relname = 'idx_user_behavior_vector_search_embedding_hnsw';

    IF search_hnsw_index_definition IS DISTINCT FROM
        'CREATE INDEX idx_user_behavior_vector_search_embedding_hnsw ON public.user_behavior_vector_search USING hnsw (embedding vector_cosine_ops)'
    THEN
        RAISE EXCEPTION
            'incompatible index definition: idx_user_behavior_vector_search_embedding_hnsw';
    END IF;
END
$$;

COMMIT;
