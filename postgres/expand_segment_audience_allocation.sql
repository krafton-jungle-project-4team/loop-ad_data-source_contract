-- =========================================================
-- Segment Audience allocation additive PostgreSQL expansion
-- Base contract: Loop-Ad PostgreSQL Schema Contract v1.9
-- Target contract: Loop-Ad PostgreSQL Schema Contract v1.10
--
-- Existing snapshots, targets, runs, and assignments are preserved. This
-- migration performs no INSERT, UPDATE, DELETE, or legacy inference.
-- =========================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('segment_audience_snapshots') IS NULL
       OR to_regclass('segment_audience_members') IS NULL
       OR to_regclass('promotion_target_segments') IS NULL
       OR to_regclass('promotion_runs') IS NULL THEN
        RAISE EXCEPTION
            'Segment Audience V2 v1.9 contract must be installed before allocation expansion';
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS segment_audience_allocation_plans (
    allocation_plan_id VARCHAR(100) PRIMARY KEY,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    recommendation_analysis_id VARCHAR(100) NOT NULL,
    selection_signature VARCHAR(255) NOT NULL,
    allocation_policy_id VARCHAR(100) NOT NULL,
    allocation_policy_version VARCHAR(100) NOT NULL,
    allocation_policy_hash VARCHAR(128) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'draft',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    finalized_at TIMESTAMPTZ,
    superseded_at TIMESTAMPTZ,

    CONSTRAINT fk_segment_audience_allocation_plans_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_segment_audience_allocation_plans_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_segment_audience_allocation_plans_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_segment_audience_allocation_plans_analysis
        FOREIGN KEY (recommendation_analysis_id)
        REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT chk_segment_audience_allocation_plans_status
        CHECK (status IN ('draft', 'finalized', 'superseded', 'locked')),

    CONSTRAINT chk_segment_audience_allocation_plans_identifiers
        CHECK (
            btrim(selection_signature) <> ''
            AND btrim(allocation_policy_id) <> ''
            AND btrim(allocation_policy_version) <> ''
            AND btrim(allocation_policy_hash) <> ''
        ),

    CONSTRAINT chk_segment_audience_allocation_plans_lifecycle
        CHECK (
            (
                status = 'draft'
                AND finalized_at IS NULL
                AND superseded_at IS NULL
            )
            OR (
                status IN ('finalized', 'locked')
                AND finalized_at IS NOT NULL
                AND superseded_at IS NULL
            )
            OR (
                status = 'superseded'
                AND superseded_at IS NOT NULL
                AND (
                    finalized_at IS NULL
                    OR finalized_at <= superseded_at
                )
            )
        ),

    CONSTRAINT uq_segment_audience_allocation_plans_identity
        UNIQUE (
            allocation_plan_id,
            project_id,
            campaign_id,
            promotion_id,
            recommendation_analysis_id
        ),

    CONSTRAINT uq_segment_audience_allocation_plans_status
        UNIQUE (allocation_plan_id, status)
);

ALTER TABLE promotion_runs
    ADD COLUMN IF NOT EXISTS audience_allocation_plan_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS audience_allocation_plan_status VARCHAR(50)
        GENERATED ALWAYS AS (
            CASE
                WHEN audience_allocation_plan_id IS NULL THEN NULL
                ELSE 'locked'
            END
        ) STORED;

ALTER TABLE segment_audience_snapshots
    ADD COLUMN IF NOT EXISTS snapshot_role VARCHAR(50)
        NOT NULL DEFAULT 'source_candidate',
    ADD COLUMN IF NOT EXISTS source_snapshot_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS allocation_plan_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS allocation_policy_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS allocation_policy_version VARCHAR(100),
    ADD COLUMN IF NOT EXISTS allocation_policy_hash VARCHAR(128),
    ADD COLUMN IF NOT EXISTS targetable BOOLEAN
        GENERATED ALWAYS AS (final_user_count > 0) STORED;

ALTER TABLE promotion_target_segments
    ADD COLUMN IF NOT EXISTS source_audience_snapshot_id VARCHAR(100);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'uq_segment_audience_snapshots_identity'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT uq_segment_audience_snapshots_identity
            UNIQUE (
                snapshot_id,
                project_id,
                campaign_id,
                promotion_id,
                segment_id
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'uq_segment_audience_snapshots_plan_source'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT uq_segment_audience_snapshots_plan_source
            UNIQUE (allocation_plan_id, source_snapshot_id, snapshot_id);
    END IF;

END
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'fk_promotion_runs_audience_allocation_plan_identity'
    ) THEN
        ALTER TABLE promotion_runs
            ADD CONSTRAINT fk_promotion_runs_audience_allocation_plan_identity
            FOREIGN KEY (
                audience_allocation_plan_id,
                project_id,
                campaign_id,
                promotion_id,
                analysis_id
            )
            REFERENCES segment_audience_allocation_plans (
                allocation_plan_id,
                project_id,
                campaign_id,
                promotion_id,
                recommendation_analysis_id
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_runs'::regclass
          AND conname = 'fk_promotion_runs_audience_allocation_plan_locked'
    ) THEN
        ALTER TABLE promotion_runs
            ADD CONSTRAINT fk_promotion_runs_audience_allocation_plan_locked
            FOREIGN KEY (
                audience_allocation_plan_id,
                audience_allocation_plan_status
            )
            REFERENCES segment_audience_allocation_plans (
                allocation_plan_id,
                status
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'fk_segment_audience_snapshots_source_identity'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT fk_segment_audience_snapshots_source_identity
            FOREIGN KEY (
                source_snapshot_id,
                project_id,
                campaign_id,
                promotion_id,
                segment_id
            )
            REFERENCES segment_audience_snapshots (
                snapshot_id,
                project_id,
                campaign_id,
                promotion_id,
                segment_id
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'fk_segment_audience_snapshots_allocation_plan_identity'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT fk_segment_audience_snapshots_allocation_plan_identity
            FOREIGN KEY (
                allocation_plan_id,
                project_id,
                campaign_id,
                promotion_id,
                analysis_id
            )
            REFERENCES segment_audience_allocation_plans (
                allocation_plan_id,
                project_id,
                campaign_id,
                promotion_id,
                recommendation_analysis_id
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_target_segments'::regclass
          AND conname = 'fk_promotion_target_segments_source_snapshot_identity'
    ) THEN
        ALTER TABLE promotion_target_segments
            ADD CONSTRAINT fk_promotion_target_segments_source_snapshot_identity
            FOREIGN KEY (
                source_audience_snapshot_id,
                project_id,
                campaign_id,
                promotion_id,
                segment_id
            )
            REFERENCES segment_audience_snapshots (
                snapshot_id,
                project_id,
                campaign_id,
                promotion_id,
                segment_id
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_target_segments'::regclass
          AND conname = 'fk_promotion_target_segments_final_snapshot_identity'
    ) THEN
        ALTER TABLE promotion_target_segments
            ADD CONSTRAINT fk_promotion_target_segments_final_snapshot_identity
            FOREIGN KEY (
                audience_snapshot_id,
                project_id,
                campaign_id,
                promotion_id,
                segment_id
            )
            REFERENCES segment_audience_snapshots (
                snapshot_id,
                project_id,
                campaign_id,
                promotion_id,
                segment_id
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_role'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_role
            CHECK (snapshot_role IN ('source_candidate', 'final_allocation'));
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_allocation_identity'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_allocation_identity
            CHECK (
                (
                    snapshot_role = 'source_candidate'
                    AND source_snapshot_id IS NULL
                    AND allocation_plan_id IS NULL
                    AND allocation_policy_id IS NULL
                    AND allocation_policy_version IS NULL
                    AND allocation_policy_hash IS NULL
                )
                OR (
                    snapshot_role = 'final_allocation'
                    AND source_snapshot_id IS NOT NULL
                    AND source_snapshot_id <> snapshot_id
                    AND allocation_plan_id IS NOT NULL
                    AND allocation_policy_id IS NOT NULL
                    AND allocation_policy_version IS NOT NULL
                    AND allocation_policy_hash IS NOT NULL
                )
            );
    END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_segment_audience_allocation_plans_active
ON segment_audience_allocation_plans (promotion_id)
WHERE status IN ('draft', 'finalized');

CREATE INDEX IF NOT EXISTS idx_segment_audience_allocation_plans_analysis_selection
ON segment_audience_allocation_plans (
    recommendation_analysis_id,
    selection_signature
);

CREATE INDEX IF NOT EXISTS idx_promotion_runs_audience_allocation_plan_id
ON promotion_runs (audience_allocation_plan_id);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_source_audience_snapshot_id
ON promotion_target_segments (source_audience_snapshot_id);

CREATE TABLE IF NOT EXISTS segment_audience_allocation_plan_targets (
    allocation_plan_id VARCHAR(100) NOT NULL,
    target_segment_id BIGINT NOT NULL,
    source_snapshot_id VARCHAR(100) NOT NULL,
    final_snapshot_id VARCHAR(100) NOT NULL,
    template_id VARCHAR(100) NOT NULL,
    template_version VARCHAR(100) NOT NULL,
    template_hash VARCHAR(128) NOT NULL,
    allocation_priority INT NOT NULL,
    final_user_count INT NOT NULL,
    audience_status VARCHAR(50) NOT NULL,
    targetable BOOLEAN NOT NULL,

    CONSTRAINT pk_segment_audience_allocation_plan_targets
        PRIMARY KEY (allocation_plan_id, target_segment_id),

    CONSTRAINT fk_segment_audience_allocation_plan_targets_plan
        FOREIGN KEY (allocation_plan_id)
        REFERENCES segment_audience_allocation_plans (allocation_plan_id),

    CONSTRAINT fk_segment_audience_allocation_plan_targets_target
        FOREIGN KEY (target_segment_id)
        REFERENCES promotion_target_segments (id),

    CONSTRAINT fk_segment_audience_allocation_plan_targets_snapshot_binding
        FOREIGN KEY (
            allocation_plan_id,
            source_snapshot_id,
            final_snapshot_id
        )
        REFERENCES segment_audience_snapshots (
            allocation_plan_id,
            source_snapshot_id,
            snapshot_id
        ),

    CONSTRAINT chk_segment_audience_allocation_plan_targets_template
        CHECK (
            btrim(template_id) <> ''
            AND btrim(template_version) <> ''
            AND btrim(template_hash) <> ''
        ),

    CONSTRAINT chk_segment_audience_allocation_plan_targets_priority
        CHECK (allocation_priority >= 1),

    CONSTRAINT chk_segment_audience_allocation_plan_targets_final_count
        CHECK (final_user_count >= 0),

    CONSTRAINT chk_segment_audience_allocation_plan_targets_audience_status
        CHECK (audience_status IN (
            'no_eligible_audience',
            'insufficient_sample',
            'targetable'
        )),

    CONSTRAINT chk_segment_audience_allocation_plan_targets_targetable
        CHECK (targetable = (final_user_count > 0)),

    CONSTRAINT uq_segment_audience_allocation_plan_targets_binding
        UNIQUE (
            allocation_plan_id,
            target_segment_id,
            source_snapshot_id,
            final_snapshot_id
        ),

    CONSTRAINT uq_segment_audience_allocation_plan_targets_final_snapshot
        UNIQUE (allocation_plan_id, final_snapshot_id)
);

CREATE TABLE IF NOT EXISTS segment_audience_allocation_members (
    allocation_plan_id VARCHAR(100) NOT NULL,
    user_id VARCHAR(255) NOT NULL,
    target_segment_id BIGINT NOT NULL,
    source_snapshot_id VARCHAR(100) NOT NULL,
    final_snapshot_id VARCHAR(100) NOT NULL,
    behavior_fit_score NUMERIC(10, 6),
    threshold NUMERIC(10, 6) NOT NULL,
    semantic_margin NUMERIC(10, 6) NOT NULL,
    normalized_fit NUMERIC(10, 6) NOT NULL,
    allocation_reason VARCHAR(100) NOT NULL,
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_audience_allocation_members_target_binding
        FOREIGN KEY (
            allocation_plan_id,
            target_segment_id,
            source_snapshot_id,
            final_snapshot_id
        )
        REFERENCES segment_audience_allocation_plan_targets (
            allocation_plan_id,
            target_segment_id,
            source_snapshot_id,
            final_snapshot_id
        ),

    CONSTRAINT fk_segment_audience_allocation_members_source_member
        FOREIGN KEY (source_snapshot_id, user_id)
        REFERENCES segment_audience_members (snapshot_id, user_id),

    CONSTRAINT fk_segment_audience_allocation_members_final_member
        FOREIGN KEY (final_snapshot_id, user_id)
        REFERENCES segment_audience_members (snapshot_id, user_id)
        DEFERRABLE INITIALLY DEFERRED,

    CONSTRAINT chk_segment_audience_allocation_members_score
        CHECK (
            behavior_fit_score IS NULL
            OR (
                behavior_fit_score >= -1
                AND behavior_fit_score <= 1
            )
        ),

    CONSTRAINT chk_segment_audience_allocation_members_normalized_fit
        CHECK (normalized_fit >= 0 AND normalized_fit <= 1),

    CONSTRAINT chk_segment_audience_allocation_members_reason
        CHECK (btrim(allocation_reason) <> ''),

    CONSTRAINT uq_segment_audience_allocation_members_plan_user
        UNIQUE (allocation_plan_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_segment_audience_allocation_members_plan_target
ON segment_audience_allocation_members (
    allocation_plan_id,
    target_segment_id
);

CREATE INDEX IF NOT EXISTS idx_segment_audience_allocation_members_target_plan
ON segment_audience_allocation_members (
    target_segment_id,
    allocation_plan_id
);

CREATE OR REPLACE FUNCTION prevent_locked_audience_allocation_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    old_plan_id VARCHAR(100);
    new_plan_id VARCHAR(100);
BEGIN
    IF TG_OP <> 'INSERT' THEN
        old_plan_id := OLD.allocation_plan_id;
    END IF;

    IF TG_OP <> 'DELETE' THEN
        new_plan_id := NEW.allocation_plan_id;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM segment_audience_allocation_plans AS plan
        WHERE plan.allocation_plan_id IN (old_plan_id, new_plan_id)
          AND plan.status = 'locked'
    ) THEN
        RAISE EXCEPTION
            'locked audience allocation plan cannot be mutated'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_allocation_plan_targets_locked
ON segment_audience_allocation_plan_targets;
CREATE TRIGGER trg_allocation_plan_targets_locked
BEFORE INSERT OR UPDATE OR DELETE
ON segment_audience_allocation_plan_targets
FOR EACH ROW EXECUTE FUNCTION prevent_locked_audience_allocation_mutation();

DROP TRIGGER IF EXISTS trg_allocation_members_locked
ON segment_audience_allocation_members;
CREATE TRIGGER trg_allocation_members_locked
BEFORE INSERT OR UPDATE OR DELETE
ON segment_audience_allocation_members
FOR EACH ROW EXECUTE FUNCTION prevent_locked_audience_allocation_mutation();

CREATE OR REPLACE FUNCTION prevent_locked_target_snapshot_rebinding()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (
        OLD.source_audience_snapshot_id,
        OLD.audience_snapshot_id
    ) IS DISTINCT FROM (
        NEW.source_audience_snapshot_id,
        NEW.audience_snapshot_id
    ) AND EXISTS (
        SELECT 1
        FROM segment_audience_allocation_plan_targets AS plan_target
        JOIN segment_audience_allocation_plans AS plan
          ON plan.allocation_plan_id = plan_target.allocation_plan_id
        WHERE plan_target.target_segment_id = OLD.id
          AND plan.status = 'locked'
    ) THEN
        RAISE EXCEPTION
            'target snapshots used by a locked allocation plan cannot be rebound'
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_promotion_target_locked_snapshot_rebinding
ON promotion_target_segments;
CREATE TRIGGER trg_promotion_target_locked_snapshot_rebinding
BEFORE UPDATE OF source_audience_snapshot_id, audience_snapshot_id
ON promotion_target_segments
FOR EACH ROW EXECUTE FUNCTION prevent_locked_target_snapshot_rebinding();

CREATE TABLE IF NOT EXISTS segment_audience_allocation_previews (
    preview_id VARCHAR(100) PRIMARY KEY,
    recommendation_analysis_id VARCHAR(100) NOT NULL,
    selection_signature VARCHAR(255) NOT NULL,
    source_snapshot_set_hash VARCHAR(128) NOT NULL,
    allocation_policy_version VARCHAR(100) NOT NULL,
    allocation_policy_hash VARCHAR(128) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_segment_audience_allocation_previews_analysis
        FOREIGN KEY (recommendation_analysis_id)
        REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT chk_segment_audience_allocation_previews_status
        CHECK (status IN ('active', 'superseded')),

    CONSTRAINT chk_segment_audience_allocation_previews_identity
        CHECK (
            btrim(selection_signature) <> ''
            AND btrim(source_snapshot_set_hash) <> ''
            AND btrim(allocation_policy_version) <> ''
            AND btrim(allocation_policy_hash) <> ''
        ),

    CONSTRAINT uq_segment_audience_allocation_previews_version
        UNIQUE (
            recommendation_analysis_id,
            selection_signature,
            source_snapshot_set_hash,
            allocation_policy_version,
            allocation_policy_hash
        )
);

CREATE INDEX IF NOT EXISTS idx_segment_audience_allocation_previews_analysis_selection
ON segment_audience_allocation_previews (
    recommendation_analysis_id,
    selection_signature
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_segment_audience_allocation_previews_active
ON segment_audience_allocation_previews (
    recommendation_analysis_id,
    selection_signature
)
WHERE status = 'active';

CREATE TABLE IF NOT EXISTS segment_audience_allocation_preview_targets (
    preview_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    final_user_count INT NOT NULL,
    targetable BOOLEAN NOT NULL,
    audience_status VARCHAR(50) NOT NULL,

    CONSTRAINT pk_segment_audience_allocation_preview_targets
        PRIMARY KEY (preview_id, segment_id),

    CONSTRAINT fk_segment_audience_allocation_preview_targets_preview
        FOREIGN KEY (preview_id)
        REFERENCES segment_audience_allocation_previews (preview_id),

    CONSTRAINT fk_segment_audience_allocation_preview_targets_segment
        FOREIGN KEY (segment_id)
        REFERENCES segment_definitions (segment_id),

    CONSTRAINT chk_segment_audience_allocation_preview_targets_final_count
        CHECK (final_user_count >= 0),

    CONSTRAINT chk_segment_audience_allocation_preview_targets_targetable
        CHECK (targetable = (final_user_count > 0)),

    CONSTRAINT chk_segment_audience_allocation_preview_targets_audience_status
        CHECK (audience_status IN (
            'no_eligible_audience',
            'insufficient_sample',
            'targetable'
        ))
);

DO $$
DECLARE
    missing_relations TEXT;
    missing_constraints TEXT;
    missing_indexes TEXT;
BEGIN
    SELECT string_agg(relation_name, ', ' ORDER BY relation_name)
    INTO missing_relations
    FROM unnest(ARRAY[
        'segment_audience_allocation_plans',
        'segment_audience_allocation_plan_targets',
        'segment_audience_allocation_members',
        'segment_audience_allocation_previews',
        'segment_audience_allocation_preview_targets'
    ]) AS expected(relation_name)
    WHERE to_regclass(expected.relation_name) IS NULL;

    IF missing_relations IS NOT NULL THEN
        RAISE EXCEPTION
            'missing Segment Audience allocation relation(s): %',
            missing_relations;
    END IF;

    SELECT string_agg(constraint_name, ', ' ORDER BY constraint_name)
    INTO missing_constraints
    FROM unnest(ARRAY[
        'fk_promotion_runs_audience_allocation_plan_identity',
        'fk_promotion_runs_audience_allocation_plan_locked',
        'fk_segment_audience_snapshots_source_identity',
        'fk_segment_audience_snapshots_allocation_plan_identity',
        'fk_promotion_target_segments_source_snapshot_identity',
        'fk_promotion_target_segments_final_snapshot_identity',
        'uq_segment_audience_allocation_members_plan_user'
    ]) AS expected(constraint_name)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = expected.constraint_name
    );

    IF missing_constraints IS NOT NULL THEN
        RAISE EXCEPTION
            'missing Segment Audience allocation constraint(s): %',
            missing_constraints;
    END IF;

    SELECT string_agg(index_name, ', ' ORDER BY index_name)
    INTO missing_indexes
    FROM unnest(ARRAY[
        'uq_segment_audience_allocation_plans_active',
        'idx_segment_audience_allocation_plans_analysis_selection',
        'idx_promotion_runs_audience_allocation_plan_id',
        'idx_promotion_target_segments_source_audience_snapshot_id',
        'idx_segment_audience_allocation_members_plan_target',
        'idx_segment_audience_allocation_members_target_plan',
        'idx_segment_audience_allocation_previews_analysis_selection'
    ]) AS expected(index_name)
    WHERE to_regclass(expected.index_name) IS NULL;

    IF missing_indexes IS NOT NULL THEN
        RAISE EXCEPTION
            'missing Segment Audience allocation index(es): %',
            missing_indexes;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = 'segment_audience_snapshots'::regclass
          AND attname = 'targetable'
          AND attgenerated = 's'
          AND NOT attisdropped
    ) THEN
        RAISE EXCEPTION
            'segment_audience_snapshots.targetable must be a stored generated column';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = 'promotion_runs'::regclass
          AND attname = 'audience_allocation_plan_status'
          AND attgenerated = 's'
          AND NOT attisdropped
    ) THEN
        RAISE EXCEPTION
            'promotion_runs.audience_allocation_plan_status must be a stored generated column';
    END IF;
END
$$;

COMMIT;
