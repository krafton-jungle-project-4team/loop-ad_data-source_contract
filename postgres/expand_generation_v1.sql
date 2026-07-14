-- Phase 1: expand the Generation v1 durable job, artifact, and RAG contract.
-- Rerunnable. Existing rows remain readable while Generation starts dual-writing.

BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;

ALTER TABLE public.generation_runs
    ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS finished_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS retry_count INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS next_retry_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_error_code VARCHAR(100),
    ADD COLUMN IF NOT EXISTS last_error_message TEXT,
    ADD COLUMN IF NOT EXISTS worker_id VARCHAR(200),
    ADD COLUMN IF NOT EXISTS lease_token UUID,
    ADD COLUMN IF NOT EXISTS heartbeat_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS lease_expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS idempotency_key VARCHAR(200),
    ADD COLUMN IF NOT EXISTS request_fingerprint CHAR(64);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.generation_runs'::regclass
          AND conname = 'chk_generation_runs_retry_count'
    ) THEN
        ALTER TABLE public.generation_runs
            ADD CONSTRAINT chk_generation_runs_retry_count
            CHECK (retry_count >= 0) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.generation_runs'::regclass
          AND conname = 'chk_generation_runs_fingerprint'
    ) THEN
        ALTER TABLE public.generation_runs
            ADD CONSTRAINT chk_generation_runs_fingerprint
            CHECK (
                request_fingerprint IS NULL
                OR request_fingerprint ~ '^[0-9a-f]{64}$'
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.generation_runs'::regclass
          AND conname = 'chk_generation_runs_idempotency_fingerprint'
    ) THEN
        ALTER TABLE public.generation_runs
            ADD CONSTRAINT chk_generation_runs_idempotency_fingerprint
            CHECK (
                idempotency_key IS NULL
                OR request_fingerprint IS NOT NULL
            ) NOT VALID;
    END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_generation_runs_project_idempotency
ON public.generation_runs (project_id, idempotency_key)
WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_generation_runs_claimable
ON public.generation_runs (
    COALESCE(next_retry_at, created_at),
    created_at,
    generation_id
)
WHERE status = 'requested';

CREATE INDEX IF NOT EXISTS idx_generation_runs_expired_lease
ON public.generation_runs (lease_expires_at)
WHERE status = 'running';

ALTER TABLE public.content_candidates
    ADD COLUMN IF NOT EXISTS creative_format VARCHAR(50),
    ADD COLUMN IF NOT EXISTS image_generation_status VARCHAR(50),
    ADD COLUMN IF NOT EXISTS artifact_status VARCHAR(50),
    ADD COLUMN IF NOT EXISTS artifact_storage_key TEXT,
    ADD COLUMN IF NOT EXISTS artifact_public_url TEXT,
    ADD COLUMN IF NOT EXISTS artifact_sha256 CHAR(64),
    ADD COLUMN IF NOT EXISTS artifact_content_type VARCHAR(100),
    ADD COLUMN IF NOT EXISTS artifact_error_code VARCHAR(100),
    ADD COLUMN IF NOT EXISTS artifact_published_at TIMESTAMPTZ;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.content_candidates'::regclass
          AND conname = 'chk_content_candidates_creative_format'
    ) THEN
        ALTER TABLE public.content_candidates
            ADD CONSTRAINT chk_content_candidates_creative_format
            CHECK (
                creative_format IS NULL
                OR creative_format IN ('email_html', 'banner_html', 'sms_text')
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.content_candidates'::regclass
          AND conname = 'chk_content_candidates_channel_format'
    ) THEN
        ALTER TABLE public.content_candidates
            ADD CONSTRAINT chk_content_candidates_channel_format
            CHECK (
                creative_format IS NULL
                OR (channel = 'email' AND creative_format = 'email_html')
                OR (
                    channel = 'onsite_banner'
                    AND creative_format = 'banner_html'
                )
                OR (channel = 'sms' AND creative_format = 'sms_text')
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.content_candidates'::regclass
          AND conname = 'chk_content_candidates_image_generation_status'
    ) THEN
        ALTER TABLE public.content_candidates
            ADD CONSTRAINT chk_content_candidates_image_generation_status
            CHECK (
                image_generation_status IS NULL
                OR image_generation_status IN (
                    'not_required',
                    'pending',
                    'running',
                    'completed',
                    'failed'
                )
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.content_candidates'::regclass
          AND conname = 'chk_content_candidates_artifact_status'
    ) THEN
        ALTER TABLE public.content_candidates
            ADD CONSTRAINT chk_content_candidates_artifact_status
            CHECK (
                artifact_status IS NULL
                OR artifact_status IN (
                    'not_required', 'pending', 'published', 'failed'
                )
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.content_candidates'::regclass
          AND conname = 'chk_content_candidates_channel_lifecycle'
    ) THEN
        ALTER TABLE public.content_candidates
            ADD CONSTRAINT chk_content_candidates_channel_lifecycle
            CHECK (
                creative_format IS NULL
                OR image_generation_status IS NULL
                OR artifact_status IS NULL
                OR (
                    creative_format = 'sms_text'
                    AND image_generation_status = 'not_required'
                    AND artifact_status = 'not_required'
                )
                OR (
                    creative_format IN ('email_html', 'banner_html')
                    AND image_generation_status IN (
                        'pending', 'running', 'completed', 'failed'
                    )
                    AND artifact_status IN ('pending', 'published', 'failed')
                )
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.content_candidates'::regclass
          AND conname = 'chk_content_candidates_artifact_sha256'
    ) THEN
        ALTER TABLE public.content_candidates
            ADD CONSTRAINT chk_content_candidates_artifact_sha256
            CHECK (
                artifact_sha256 IS NULL
                OR artifact_sha256 ~ '^[0-9a-f]{64}$'
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.content_candidates'::regclass
          AND conname = 'chk_content_candidates_completed_image'
    ) THEN
        ALTER TABLE public.content_candidates
            ADD CONSTRAINT chk_content_candidates_completed_image
            CHECK (
                image_generation_status IS DISTINCT FROM 'completed'
                OR image_url IS NOT NULL
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.content_candidates'::regclass
          AND conname = 'chk_content_candidates_published_artifact'
    ) THEN
        ALTER TABLE public.content_candidates
            ADD CONSTRAINT chk_content_candidates_published_artifact
            CHECK (
                artifact_status IS DISTINCT FROM 'published'
                OR (
                    artifact_storage_key IS NOT NULL
                    AND artifact_public_url IS NOT NULL
                    AND artifact_sha256 IS NOT NULL
                    AND artifact_content_type IS NOT NULL
                    AND artifact_published_at IS NOT NULL
                )
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.content_candidates'::regclass
          AND conname = 'chk_content_candidates_artifact_error'
    ) THEN
        ALTER TABLE public.content_candidates
            ADD CONSTRAINT chk_content_candidates_artifact_error
            CHECK (
                artifact_status IS DISTINCT FROM 'failed'
                OR artifact_error_code IS NOT NULL
            ) NOT VALID;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_content_candidates_artifact_status
ON public.content_candidates (generation_id, artifact_status);

CREATE SCHEMA IF NOT EXISTS generation_rag;

CREATE TABLE IF NOT EXISTS generation_rag.retrieval_documents (
    document_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    context_version VARCHAR(100) NOT NULL,

    source_kind VARCHAR(50) NOT NULL,
    source_id VARCHAR(200) NOT NULL,
    source_version VARCHAR(100) NOT NULL,
    chunk_index INT NOT NULL DEFAULT 0,

    s3_key TEXT,
    document_text TEXT NOT NULL DEFAULT '',
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    embedding vector(1024),
    embedding_model VARCHAR(100) NOT NULL,
    embedding_version VARCHAR(100) NOT NULL,
    content_sha256 CHAR(64) NOT NULL,

    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    last_error_code VARCHAR(100),
    last_error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_generation_rag_project
        FOREIGN KEY (project_id) REFERENCES public.projects (project_id),

    CONSTRAINT chk_generation_rag_source_kind
        CHECK (source_kind IN (
            'brand_asset', 'brand_guide', 'historical_creative'
        )),

    CONSTRAINT chk_generation_rag_chunk_index
        CHECK (chunk_index >= 0),

    CONSTRAINT chk_generation_rag_status
        CHECK (status IN ('pending', 'active', 'failed', 'archived')),

    CONSTRAINT chk_generation_rag_active_embedding
        CHECK (status <> 'active' OR embedding IS NOT NULL),

    CONSTRAINT chk_generation_rag_content_sha256
        CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),

    CONSTRAINT uq_generation_rag_source_context_chunk_embedding
        UNIQUE (
            project_id,
            context_version,
            source_kind,
            source_id,
            source_version,
            chunk_index,
            embedding_model,
            embedding_version
        )
);

CREATE INDEX IF NOT EXISTS idx_generation_rag_retrieval_filter
ON generation_rag.retrieval_documents (
    project_id,
    context_version,
    source_kind,
    status,
    embedding_model,
    embedding_version
);

CREATE INDEX IF NOT EXISTS idx_generation_rag_source
ON generation_rag.retrieval_documents (
    project_id,
    source_kind,
    source_id,
    source_version
);

COMMIT;
