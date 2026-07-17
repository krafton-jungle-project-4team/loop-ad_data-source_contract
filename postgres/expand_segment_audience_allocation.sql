-- =========================================================
-- Segment Audience lean allocation expansion (v1.9 -> v1.10)
--
-- Apply after expand_segment_audience_v2.sql. Existing rows are preserved;
-- this migration performs no INSERT, UPDATE, DELETE, or legacy inference.
-- The earlier allocation/reservation drafts were never shipped and are not
-- upgraded in place.
-- =========================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('segment_audience_snapshots') IS NULL
       OR to_regclass('segment_audience_members') IS NULL
       OR to_regclass('promotion_target_segments') IS NULL
       OR to_regclass('promotion_runs') IS NULL THEN
        RAISE EXCEPTION
            'Segment Audience V2 v1.9 must be installed before lean allocation expansion';
    END IF;

    IF to_regclass('segment_audience_allocation_plan_targets') IS NOT NULL
       OR to_regclass('segment_audience_allocation_plan_segments') IS NOT NULL
       OR to_regclass('segment_audience_allocation_members') IS NOT NULL
       OR to_regclass('segment_audience_allocation_previews') IS NOT NULL
       OR to_regclass('segment_audience_allocation_preview_targets') IS NOT NULL
       OR to_regclass('promotion_audience_exclusion_revisions') IS NOT NULL
       OR to_regclass('promotion_audience_exclusion_events') IS NOT NULL
       OR to_regclass('promotion_run_target_audience_bindings') IS NOT NULL
       OR EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = current_schema()
             AND table_name = 'segment_audience_snapshots'
             AND column_name IN (
                 'snapshot_role',
                 'source_audience_snapshot_id',
                 'allocation_policy_id',
                 'allocation_policy_version',
                 'allocation_policy_hash',
                 'targetable',
                 'promotion_exclusion_revision',
                 'promotion_exclusion_hash'
             )
       )
       OR EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = current_schema()
             AND table_name = 'promotion_target_segments'
             AND column_name = 'source_audience_snapshot_id'
       ) THEN
        RAISE EXCEPTION
            'incompatible pre-release allocation draft detected; recreate the database from the V2 v1.9 baseline';
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'promotion_analyses'::regclass
          AND conname = 'uq_promotion_analyses_promotion_identity'
    ) THEN
        ALTER TABLE promotion_analyses
            ADD CONSTRAINT uq_promotion_analyses_promotion_identity
            UNIQUE (analysis_id, promotion_id);
    END IF;
END
$$;

-- =========================================================
-- 12A. Segment Audience Allocation Plans
-- One immutable confirmation action containing one to three segments.
-- =========================================================
CREATE OR REPLACE FUNCTION is_valid_selected_segment_ids_json(
    p_selected_segment_ids_json JSONB
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
    item JSONB;
    segment_id_value TEXT;
    seen_segment_ids TEXT[] := ARRAY[]::TEXT[];
    canonical_segment_ids JSONB;
BEGIN
    IF jsonb_typeof(p_selected_segment_ids_json) <> 'array'
       OR jsonb_array_length(p_selected_segment_ids_json) NOT BETWEEN 1 AND 3 THEN
        RETURN false;
    END IF;

    FOR item IN
        SELECT value
        FROM jsonb_array_elements(p_selected_segment_ids_json) AS items(value)
    LOOP
        IF jsonb_typeof(item) <> 'string' THEN
            RETURN false;
        END IF;

        segment_id_value := item #>> '{}';
        IF btrim(segment_id_value) = ''
           OR segment_id_value <> btrim(segment_id_value)
           OR segment_id_value = ANY(seen_segment_ids) THEN
            RETURN false;
        END IF;

        seen_segment_ids := array_append(seen_segment_ids, segment_id_value);
    END LOOP;

    SELECT jsonb_agg(to_jsonb(value) ORDER BY value COLLATE "C")
    INTO canonical_segment_ids
    FROM unnest(seen_segment_ids) AS values(value);

    RETURN p_selected_segment_ids_json = canonical_segment_ids;
END
$$;

CREATE TABLE IF NOT EXISTS segment_audience_allocation_plans (
    allocation_plan_id UUID PRIMARY KEY,
    promotion_id VARCHAR(100) NOT NULL,
    candidate_batch_analysis_id VARCHAR(100) NOT NULL,
    target_analysis_id VARCHAR(100) NOT NULL,
    selection_fingerprint VARCHAR(128) NOT NULL,
    selected_segment_ids_json JSONB NOT NULL,
    exclusion_revision BIGINT NOT NULL,
    allocation_policy_version VARCHAR(100) NOT NULL,
    allocation_policy_hash VARCHAR(128) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'finalized',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_at TIMESTAMPTZ,
    released_at TIMESTAMPTZ,

    CONSTRAINT fk_segment_audience_allocation_plans_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_segment_audience_allocation_plans_candidate_analysis
        FOREIGN KEY (candidate_batch_analysis_id, promotion_id)
        REFERENCES promotion_analyses (analysis_id, promotion_id),

    CONSTRAINT fk_segment_audience_allocation_plans_target_analysis
        FOREIGN KEY (target_analysis_id, promotion_id)
        REFERENCES promotion_analyses (analysis_id, promotion_id),

    CONSTRAINT chk_segment_audience_allocation_plans_status
        CHECK (status IN ('finalized', 'locked', 'released')),

    CONSTRAINT chk_segment_audience_allocation_plans_identifiers
        CHECK (
            btrim(selection_fingerprint) <> ''
            AND exclusion_revision >= 1
            AND btrim(allocation_policy_version) <> ''
            AND btrim(allocation_policy_hash) <> ''
        ),

    CONSTRAINT chk_segment_audience_allocation_plans_selected_segments
        CHECK (is_valid_selected_segment_ids_json(selected_segment_ids_json)),

    CONSTRAINT chk_segment_audience_allocation_plans_lifecycle
        CHECK (
            (
                status = 'finalized'
                AND locked_at IS NULL
                AND released_at IS NULL
            )
            OR (
                status = 'locked'
                AND locked_at IS NOT NULL
                AND released_at IS NULL
            )
            OR (
                status = 'released'
                AND locked_at IS NULL
                AND released_at IS NOT NULL
            )
        ),

    CONSTRAINT uq_segment_audience_allocation_plans_selection
        UNIQUE (candidate_batch_analysis_id, selection_fingerprint),

    CONSTRAINT uq_segment_audience_allocation_plans_target_identity
        UNIQUE (
            allocation_plan_id,
            target_analysis_id,
            promotion_id
        ),

    CONSTRAINT uq_segment_audience_allocation_plans_status
        UNIQUE (allocation_plan_id, status)
);

CREATE INDEX IF NOT EXISTS idx_segment_audience_allocation_plans_promotion
ON segment_audience_allocation_plans (promotion_id, created_at);



ALTER TABLE segment_audience_snapshots
    ADD COLUMN IF NOT EXISTS snapshot_kind VARCHAR(50)
        NOT NULL DEFAULT 'source',
    ADD COLUMN IF NOT EXISTS source_snapshot_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS allocation_plan_id UUID;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
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
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'uq_segment_audience_snapshots_target_binding'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT uq_segment_audience_snapshots_target_binding
            UNIQUE (
                snapshot_id,
                analysis_id,
                promotion_id,
                segment_id,
                allocation_plan_id
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'uq_segment_audience_snapshots_plan_segment'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT uq_segment_audience_snapshots_plan_segment
            UNIQUE (allocation_plan_id, segment_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
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
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'fk_segment_audience_snapshots_allocation_plan_identity'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT fk_segment_audience_snapshots_allocation_plan_identity
            FOREIGN KEY (allocation_plan_id, analysis_id, promotion_id)
            REFERENCES segment_audience_allocation_plans (
                allocation_plan_id,
                target_analysis_id,
                promotion_id
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_kind'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_kind
            CHECK (snapshot_kind IN ('source', 'final'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'segment_audience_snapshots'::regclass
          AND conname = 'chk_segment_audience_snapshots_allocation_identity'
    ) THEN
        ALTER TABLE segment_audience_snapshots
            ADD CONSTRAINT chk_segment_audience_snapshots_allocation_identity
            CHECK (
                (
                    snapshot_kind = 'source'
                    AND source_snapshot_id IS NULL
                    AND allocation_plan_id IS NULL
                )
                OR (
                    snapshot_kind = 'final'
                    AND source_snapshot_id IS NOT NULL
                    AND source_snapshot_id <> snapshot_id
                    AND allocation_plan_id IS NOT NULL
                )
            );
    END IF;
END
$$;

ALTER TABLE promotion_target_segments
    ADD COLUMN IF NOT EXISTS allocation_plan_id UUID,
    ADD COLUMN IF NOT EXISTS audience_reservation_state VARCHAR(50);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'promotion_target_segments'::regclass
          AND conname = 'fk_promotion_target_segments_allocation_plan_identity'
    ) THEN
        ALTER TABLE promotion_target_segments
            ADD CONSTRAINT fk_promotion_target_segments_allocation_plan_identity
            FOREIGN KEY (allocation_plan_id, analysis_id, promotion_id)
            REFERENCES segment_audience_allocation_plans (
                allocation_plan_id,
                target_analysis_id,
                promotion_id
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'promotion_target_segments'::regclass
          AND conname = 'fk_promotion_target_segments_final_snapshot_identity'
    ) THEN
        ALTER TABLE promotion_target_segments
            ADD CONSTRAINT fk_promotion_target_segments_final_snapshot_identity
            FOREIGN KEY (
                audience_snapshot_id,
                analysis_id,
                promotion_id,
                segment_id,
                allocation_plan_id
            )
            REFERENCES segment_audience_snapshots (
                snapshot_id,
                analysis_id,
                promotion_id,
                segment_id,
                allocation_plan_id
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'promotion_target_segments'::regclass
          AND conname = 'chk_promotion_target_segments_reservation_state'
    ) THEN
        ALTER TABLE promotion_target_segments
            ADD CONSTRAINT chk_promotion_target_segments_reservation_state
            CHECK (
                audience_reservation_state IS NULL
                OR audience_reservation_state IN (
                    'reserved', 'consumed', 'released'
                )
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'promotion_target_segments'::regclass
          AND conname = 'chk_promotion_target_segments_audience_binding'
    ) THEN
        ALTER TABLE promotion_target_segments
            ADD CONSTRAINT chk_promotion_target_segments_audience_binding
            CHECK (
                (
                    audience_snapshot_id IS NULL
                    AND allocation_plan_id IS NULL
                    AND audience_reservation_state IS NULL
                )
                OR (
                    audience_snapshot_id IS NOT NULL
                    AND allocation_plan_id IS NOT NULL
                    AND audience_reservation_state IS NOT NULL
                )
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'promotion_target_segments'::regclass
          AND conname = 'uq_promotion_target_segments_audience_binding'
    ) THEN
        ALTER TABLE promotion_target_segments
            ADD CONSTRAINT uq_promotion_target_segments_audience_binding
            UNIQUE (
                analysis_id,
                segment_id,
                allocation_plan_id,
                audience_snapshot_id
            );
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_allocation_plan_id
ON promotion_target_segments (allocation_plan_id);

-- =========================================================
-- 13A. Promotion Audience Exclusion State
-- PostgreSQL is authoritative. A promotion row is locked and advanced once
-- per confirmation, run binding, or whole-plan release transaction.
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_audience_exclusion_state (
    promotion_id VARCHAR(100) PRIMARY KEY,
    revision BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_promotion_audience_exclusion_state_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT chk_promotion_audience_exclusion_state_revision
        CHECK (revision >= 0)
);

CREATE OR REPLACE FUNCTION advance_promotion_audience_exclusion_revision(
    p_promotion_id VARCHAR(100)
)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    next_revision BIGINT;
BEGIN
    INSERT INTO promotion_audience_exclusion_state (
        promotion_id,
        revision
    ) VALUES (
        p_promotion_id,
        0
    )
    ON CONFLICT (promotion_id) DO NOTHING;

    PERFORM 1
    FROM promotion_audience_exclusion_state
    WHERE promotion_id = p_promotion_id
    FOR UPDATE;

    UPDATE promotion_audience_exclusion_state
    SET revision = revision + 1,
        updated_at = now()
    WHERE promotion_id = p_promotion_id
    RETURNING revision INTO next_revision;

    RETURN next_revision;
END
$$;

CREATE TABLE IF NOT EXISTS promotion_audience_exclusion_members (
    project_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    user_id VARCHAR(255) NOT NULL,
    target_analysis_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    allocation_plan_id UUID NOT NULL,
    final_snapshot_id VARCHAR(100) NOT NULL,
    state VARCHAR(50) NOT NULL,
    revision BIGINT NOT NULL,
    reserved_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    released_at TIMESTAMPTZ,

    CONSTRAINT pk_promotion_audience_exclusion_members
        PRIMARY KEY (project_id, promotion_id, user_id),

    CONSTRAINT fk_promotion_audience_exclusion_members_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_promotion_audience_exclusion_members_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_promotion_audience_exclusion_members_target_binding
        FOREIGN KEY (
            target_analysis_id,
            segment_id,
            allocation_plan_id,
            final_snapshot_id
        )
        REFERENCES promotion_target_segments (
            analysis_id,
            segment_id,
            allocation_plan_id,
            audience_snapshot_id
        ),

    CONSTRAINT chk_promotion_audience_exclusion_members_state
        CHECK (state IN ('reserved', 'consumed', 'released')),

    CONSTRAINT chk_promotion_audience_exclusion_members_revision
        CHECK (revision >= 1),

    CONSTRAINT chk_promotion_audience_exclusion_members_timestamps
        CHECK (
            (
                state = 'reserved'
                AND consumed_at IS NULL
                AND released_at IS NULL
            )
            OR (
                state = 'consumed'
                AND consumed_at IS NOT NULL
                AND released_at IS NULL
            )
            OR (
                state = 'released'
                AND consumed_at IS NULL
                AND released_at IS NOT NULL
            )
        )
);

CREATE INDEX IF NOT EXISTS idx_promotion_audience_exclusion_members_active
ON promotion_audience_exclusion_members (
    project_id,
    promotion_id,
    state,
    user_id
);

CREATE INDEX IF NOT EXISTS idx_promotion_audience_exclusion_members_plan_segment
ON promotion_audience_exclusion_members (
    allocation_plan_id,
    segment_id,
    state
);

CREATE INDEX IF NOT EXISTS idx_promotion_audience_exclusion_members_final_snapshot
ON promotion_audience_exclusion_members (final_snapshot_id);

-- =========================================================
-- 13B. Promotion Run Target Bindings
-- Every binding in a run shares the run row's analysis and generation.
-- =========================================================
CREATE TABLE IF NOT EXISTS promotion_run_target_bindings (
    promotion_run_id VARCHAR(100) NOT NULL,
    target_analysis_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,
    allocation_plan_id UUID NOT NULL,
    final_snapshot_id VARCHAR(100) NOT NULL,
    bound_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_promotion_run_target_bindings
        PRIMARY KEY (promotion_run_id, segment_id),

    CONSTRAINT uq_promotion_run_target_bindings_target
        UNIQUE (target_analysis_id, segment_id),

    CONSTRAINT fk_promotion_run_target_bindings_run
        FOREIGN KEY (promotion_run_id)
        REFERENCES promotion_runs (promotion_run_id),

    CONSTRAINT fk_promotion_run_target_bindings_plan
        FOREIGN KEY (allocation_plan_id)
        REFERENCES segment_audience_allocation_plans (allocation_plan_id),

    CONSTRAINT fk_promotion_run_target_bindings_final_snapshot
        FOREIGN KEY (final_snapshot_id)
        REFERENCES segment_audience_snapshots (snapshot_id),

    CONSTRAINT fk_promotion_run_target_bindings_target_binding
        FOREIGN KEY (
            target_analysis_id,
            segment_id,
            allocation_plan_id,
            final_snapshot_id
        )
        REFERENCES promotion_target_segments (
            analysis_id,
            segment_id,
            allocation_plan_id,
            audience_snapshot_id
        )
);

CREATE INDEX IF NOT EXISTS idx_promotion_run_target_bindings_plan
ON promotion_run_target_bindings (allocation_plan_id);



DROP TRIGGER IF EXISTS trg_segment_audience_allocation_plan_lifecycle
ON segment_audience_allocation_plans;
DROP TRIGGER IF EXISTS trg_promotion_target_audience_lifecycle
ON promotion_target_segments;
DROP TRIGGER IF EXISTS trg_promotion_audience_exclusion_member_lifecycle
ON promotion_audience_exclusion_members;
DROP TRIGGER IF EXISTS trg_final_audience_member_mutation
ON segment_audience_members;
DROP TRIGGER IF EXISTS trg_validate_final_audience_snapshot
ON segment_audience_snapshots;
DROP TRIGGER IF EXISTS trg_validate_allocation_plan
ON segment_audience_allocation_plans;
DROP TRIGGER IF EXISTS trg_validate_allocation_target
ON promotion_target_segments;
DROP TRIGGER IF EXISTS trg_promotion_run_target_binding_immutable
ON promotion_run_target_bindings;
DROP TRIGGER IF EXISTS trg_validate_promotion_run_binding
ON promotion_run_target_bindings;
DROP TRIGGER IF EXISTS trg_validate_promotion_run_scope
ON promotion_runs;

-- =========================================================
-- 13C. Lean Allocation Lifecycle Validation
-- =========================================================
CREATE OR REPLACE FUNCTION enforce_segment_audience_allocation_plan_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'segment audience allocation plans are immutable'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'finalized' THEN
            RAISE EXCEPTION 'new allocation plan must start finalized'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    IF ROW(
        OLD.allocation_plan_id,
        OLD.promotion_id,
        OLD.candidate_batch_analysis_id,
        OLD.target_analysis_id,
        OLD.selection_fingerprint,
        OLD.selected_segment_ids_json,
        OLD.exclusion_revision,
        OLD.allocation_policy_version,
        OLD.allocation_policy_hash,
        OLD.created_at
    ) IS DISTINCT FROM ROW(
        NEW.allocation_plan_id,
        NEW.promotion_id,
        NEW.candidate_batch_analysis_id,
        NEW.target_analysis_id,
        NEW.selection_fingerprint,
        NEW.selected_segment_ids_json,
        NEW.exclusion_revision,
        NEW.allocation_policy_version,
        NEW.allocation_policy_hash,
        NEW.created_at
    ) THEN
        RAISE EXCEPTION 'allocation plan identity is immutable'
            USING ERRCODE = '55000';
    END IF;

    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'finalized'
       AND NEW.status IN ('locked', 'released') THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'invalid allocation plan transition: % -> %',
        OLD.status, NEW.status
        USING ERRCODE = '55000';
END
$$;

CREATE TRIGGER trg_segment_audience_allocation_plan_lifecycle
BEFORE INSERT OR UPDATE OR DELETE
ON segment_audience_allocation_plans
FOR EACH ROW EXECUTE FUNCTION enforce_segment_audience_allocation_plan_lifecycle();

CREATE OR REPLACE FUNCTION enforce_promotion_target_audience_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.allocation_plan_id IS NOT NULL THEN
            RAISE EXCEPTION 'V2 promotion targets are retained after release'
                USING ERRCODE = '55000';
        END IF;
        RETURN OLD;
    END IF;

    IF TG_OP = 'INSERT' OR OLD.allocation_plan_id IS NULL THEN
        IF NEW.allocation_plan_id IS NULL
           OR NEW.audience_reservation_state = 'reserved' THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'new V2 target must start reserved'
            USING ERRCODE = '55000';
    END IF;

    IF ROW(
        OLD.audience_snapshot_id,
        OLD.allocation_plan_id
    ) IS DISTINCT FROM ROW(
        NEW.audience_snapshot_id,
        NEW.allocation_plan_id
    ) THEN
        RAISE EXCEPTION 'V2 target audience binding is immutable'
            USING ERRCODE = '55000';
    END IF;

    IF OLD.audience_reservation_state = NEW.audience_reservation_state THEN
        RETURN NEW;
    END IF;

    IF OLD.audience_reservation_state = 'reserved'
       AND NEW.audience_reservation_state IN ('consumed', 'released') THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'invalid target reservation transition: % -> %',
        OLD.audience_reservation_state,
        NEW.audience_reservation_state
        USING ERRCODE = '55000';
END
$$;

CREATE TRIGGER trg_promotion_target_audience_lifecycle
BEFORE INSERT OR UPDATE OR DELETE
ON promotion_target_segments
FOR EACH ROW EXECUTE FUNCTION enforce_promotion_target_audience_lifecycle();

CREATE OR REPLACE FUNCTION enforce_promotion_audience_exclusion_member_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_revision BIGINT;
    target_project_id VARCHAR(100);
    target_promotion_id VARCHAR(100);
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'promotion audience exclusion members are retained'
            USING ERRCODE = '55000';
    END IF;

    SELECT revision
    INTO current_revision
    FROM promotion_audience_exclusion_state
    WHERE promotion_id = NEW.promotion_id;

    IF current_revision IS NULL OR NEW.revision <> current_revision THEN
        RAISE EXCEPTION
            'member revision % must equal current promotion revision %',
            NEW.revision, current_revision
            USING ERRCODE = '23514';
    END IF;

    SELECT project_id, promotion_id
    INTO target_project_id, target_promotion_id
    FROM promotion_target_segments
    WHERE analysis_id = NEW.target_analysis_id
      AND segment_id = NEW.segment_id;

    IF ROW(NEW.project_id, NEW.promotion_id)
       IS DISTINCT FROM ROW(target_project_id, target_promotion_id) THEN
        RAISE EXCEPTION 'exclusion member target scope mismatch'
            USING ERRCODE = '23514';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.state <> 'reserved' THEN
            RAISE EXCEPTION 'new exclusion member must start reserved'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    IF ROW(OLD.project_id, OLD.promotion_id, OLD.user_id)
       IS DISTINCT FROM ROW(NEW.project_id, NEW.promotion_id, NEW.user_id) THEN
        RAISE EXCEPTION 'exclusion member identity is immutable'
            USING ERRCODE = '55000';
    END IF;

    IF NEW.revision <= OLD.revision THEN
        RAISE EXCEPTION 'exclusion member revision must increase'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.state = 'reserved'
       AND NEW.state IN ('consumed', 'released') THEN
        IF ROW(
            OLD.target_analysis_id,
            OLD.segment_id,
            OLD.allocation_plan_id,
            OLD.final_snapshot_id,
            OLD.reserved_at
        ) IS DISTINCT FROM ROW(
            NEW.target_analysis_id,
            NEW.segment_id,
            NEW.allocation_plan_id,
            NEW.final_snapshot_id,
            NEW.reserved_at
        ) THEN
            RAISE EXCEPTION 'active reservation binding is immutable'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    IF OLD.state = 'released' AND NEW.state = 'reserved' THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'invalid exclusion transition: % -> %',
        OLD.state, NEW.state
        USING ERRCODE = '55000';
END
$$;

CREATE TRIGGER trg_promotion_audience_exclusion_member_lifecycle
BEFORE INSERT OR UPDATE OR DELETE
ON promotion_audience_exclusion_members
FOR EACH ROW EXECUTE FUNCTION enforce_promotion_audience_exclusion_member_lifecycle();

CREATE OR REPLACE FUNCTION prevent_final_audience_member_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_snapshot_id VARCHAR(100);
BEGIN
    affected_snapshot_id := CASE
        WHEN TG_OP = 'DELETE' THEN OLD.snapshot_id
        ELSE NEW.snapshot_id
    END;

    IF EXISTS (
        SELECT 1
        FROM promotion_target_segments
        WHERE audience_snapshot_id = affected_snapshot_id
          AND allocation_plan_id IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'final audience members are immutable after target binding'
            USING ERRCODE = '55000';
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$$;

CREATE TRIGGER trg_final_audience_member_mutation
BEFORE INSERT OR UPDATE OR DELETE
ON segment_audience_members
FOR EACH ROW EXECUTE FUNCTION prevent_final_audience_member_mutation();

CREATE OR REPLACE FUNCTION assert_final_audience_snapshot(
    p_snapshot_id VARCHAR(100)
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    snapshot_row segment_audience_snapshots%ROWTYPE;
    source_kind VARCHAR(50);
    actual_member_count BIGINT;
BEGIN
    SELECT *
    INTO snapshot_row
    FROM segment_audience_snapshots
    WHERE snapshot_id = p_snapshot_id;

    IF NOT FOUND OR snapshot_row.snapshot_kind <> 'final' THEN
        RETURN;
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(snapshot_row.allocation_plan_id::text, 0)
    );

    SELECT snapshot_kind
    INTO source_kind
    FROM segment_audience_snapshots
    WHERE snapshot_id = snapshot_row.source_snapshot_id;

    IF source_kind <> 'source' THEN
        RAISE EXCEPTION 'final snapshot source must be a source snapshot'
            USING ERRCODE = '23514';
    END IF;

    SELECT count(*)
    INTO actual_member_count
    FROM segment_audience_members
    WHERE snapshot_id = snapshot_row.snapshot_id;

    IF actual_member_count <> snapshot_row.final_user_count THEN
        RAISE EXCEPTION
            'final snapshot member count mismatch: expected %, found %',
            snapshot_row.final_user_count, actual_member_count
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT member.user_id
        FROM segment_audience_snapshots AS snapshot
        JOIN segment_audience_members AS member
          ON member.snapshot_id = snapshot.snapshot_id
        WHERE snapshot.allocation_plan_id = snapshot_row.allocation_plan_id
          AND snapshot.snapshot_kind = 'final'
        GROUP BY member.user_id
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'final snapshots in one plan may not overlap'
            USING ERRCODE = '23505';
    END IF;

    RETURN;
END
$$;

CREATE OR REPLACE FUNCTION validate_final_audience_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_TABLE_NAME = 'segment_audience_members' THEN
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
            PERFORM assert_final_audience_snapshot(OLD.snapshot_id);
        END IF;
        IF TG_OP IN ('INSERT', 'UPDATE')
           AND (TG_OP = 'INSERT' OR NEW.snapshot_id <> OLD.snapshot_id) THEN
            PERFORM assert_final_audience_snapshot(NEW.snapshot_id);
        END IF;
    ELSE
        PERFORM assert_final_audience_snapshot(NEW.snapshot_id);
    END IF;

    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER trg_validate_final_audience_snapshot
AFTER INSERT OR UPDATE
ON segment_audience_snapshots
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_final_audience_snapshot();

DROP TRIGGER IF EXISTS trg_validate_final_audience_member
ON segment_audience_members;

CREATE CONSTRAINT TRIGGER trg_validate_final_audience_member
AFTER INSERT OR UPDATE OR DELETE
ON segment_audience_members
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_final_audience_snapshot();

CREATE OR REPLACE FUNCTION assert_segment_audience_allocation_plan(
    p_allocation_plan_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    plan_row segment_audience_allocation_plans%ROWTYPE;
    stored_segment_ids JSONB;
BEGIN
    SELECT *
    INTO plan_row
    FROM segment_audience_allocation_plans
    WHERE allocation_plan_id = p_allocation_plan_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT jsonb_agg(to_jsonb(segment_id) ORDER BY segment_id COLLATE "C")
    INTO stored_segment_ids
    FROM promotion_target_segments
    WHERE allocation_plan_id = p_allocation_plan_id;

    IF stored_segment_ids IS DISTINCT FROM plan_row.selected_segment_ids_json THEN
        RAISE EXCEPTION 'allocation plan target set does not match selected segments'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_target_segments AS target
        JOIN segment_audience_snapshots AS snapshot
          ON snapshot.snapshot_id = target.audience_snapshot_id
        WHERE target.allocation_plan_id = p_allocation_plan_id
          AND (
              target.analysis_id <> plan_row.target_analysis_id
              OR target.promotion_id <> plan_row.promotion_id
              OR target.project_id <> snapshot.project_id
              OR target.campaign_id <> snapshot.campaign_id
              OR target.promotion_id <> snapshot.promotion_id
              OR target.segment_id <> snapshot.segment_id
              OR snapshot.snapshot_kind <> 'final'
              OR snapshot.allocation_plan_id <> p_allocation_plan_id
          )
    ) THEN
        RAISE EXCEPTION 'allocation plan target identity mismatch'
            USING ERRCODE = '23514';
    END IF;

    IF plan_row.status = 'finalized' THEN
        IF EXISTS (
            SELECT 1
            FROM promotion_target_segments
            WHERE allocation_plan_id = p_allocation_plan_id
              AND audience_reservation_state <> 'reserved'
        ) OR EXISTS (
            SELECT 1
            FROM promotion_run_target_bindings
            WHERE allocation_plan_id = p_allocation_plan_id
        ) THEN
            RAISE EXCEPTION 'finalized plan must contain only reserved targets'
                USING ERRCODE = '23514';
        END IF;
    ELSIF plan_row.status = 'locked' THEN
        IF NOT EXISTS (
            SELECT 1
            FROM promotion_run_target_bindings
            WHERE allocation_plan_id = p_allocation_plan_id
        ) OR EXISTS (
            SELECT 1
            FROM promotion_target_segments AS target
            WHERE target.allocation_plan_id = p_allocation_plan_id
              AND target.audience_reservation_state <>
                  CASE
                      WHEN EXISTS (
                          SELECT 1
                          FROM promotion_run_target_bindings AS binding
                          WHERE binding.target_analysis_id = target.analysis_id
                            AND binding.segment_id = target.segment_id
                      ) THEN 'consumed'
                      ELSE 'reserved'
                  END
        ) THEN
            RAISE EXCEPTION 'locked plan target states must match run bindings'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        IF EXISTS (
            SELECT 1
            FROM promotion_run_target_bindings
            WHERE allocation_plan_id = p_allocation_plan_id
        ) OR EXISTS (
            SELECT 1
            FROM promotion_target_segments
            WHERE allocation_plan_id = p_allocation_plan_id
              AND audience_reservation_state <> 'released'
        ) THEN
            RAISE EXCEPTION 'released plan must release every unbound target'
                USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM promotion_audience_exclusion_members
            WHERE allocation_plan_id = p_allocation_plan_id
              AND state IN ('reserved', 'consumed')
        ) THEN
            RAISE EXCEPTION 'released plan may not retain active exclusions'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF plan_row.status <> 'released' AND EXISTS (
        SELECT 1
        FROM promotion_target_segments AS target
        JOIN segment_audience_snapshots AS snapshot
          ON snapshot.snapshot_id = target.audience_snapshot_id
        WHERE target.allocation_plan_id = p_allocation_plan_id
          AND (
              SELECT count(*)
              FROM promotion_audience_exclusion_members AS excluded
              WHERE excluded.allocation_plan_id = p_allocation_plan_id
                AND excluded.segment_id = target.segment_id
                AND excluded.final_snapshot_id = target.audience_snapshot_id
                AND excluded.state = target.audience_reservation_state
          ) <> snapshot.final_user_count
    ) THEN
        RAISE EXCEPTION 'allocation plan exclusion member count mismatch'
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION validate_allocation_plan_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_plan_id UUID;
BEGIN
    affected_plan_id := CASE
        WHEN TG_TABLE_NAME = 'segment_audience_allocation_plans' THEN
            CASE WHEN TG_OP = 'DELETE' THEN OLD.allocation_plan_id
                 ELSE NEW.allocation_plan_id END
        ELSE
            CASE WHEN TG_OP = 'DELETE' THEN OLD.allocation_plan_id
                 ELSE NEW.allocation_plan_id END
    END;

    IF affected_plan_id IS NOT NULL THEN
        PERFORM assert_segment_audience_allocation_plan(affected_plan_id);
    END IF;
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER trg_validate_allocation_plan
AFTER INSERT OR UPDATE
ON segment_audience_allocation_plans
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_allocation_plan_trigger();

CREATE CONSTRAINT TRIGGER trg_validate_allocation_target
AFTER INSERT OR UPDATE
ON promotion_target_segments
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_allocation_plan_trigger();

CREATE OR REPLACE FUNCTION prevent_promotion_run_target_binding_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'promotion run target bindings are immutable'
        USING ERRCODE = '55000';
END
$$;

CREATE TRIGGER trg_promotion_run_target_binding_immutable
BEFORE UPDATE OR DELETE
ON promotion_run_target_bindings
FOR EACH ROW EXECUTE FUNCTION prevent_promotion_run_target_binding_mutation();

CREATE OR REPLACE FUNCTION assert_promotion_run_target_bindings(
    p_promotion_run_id VARCHAR(100)
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    run_row promotion_runs%ROWTYPE;
    bound_segment_ids JSONB;
    v2_target_count INT;
BEGIN
    SELECT *
    INTO run_row
    FROM promotion_runs
    WHERE promotion_run_id = p_promotion_run_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT count(*)
    INTO v2_target_count
    FROM promotion_target_segments AS target
    WHERE target.analysis_id = run_row.analysis_id
      AND target.segment_id IN (
          SELECT value #>> '{}'
          FROM jsonb_array_elements(run_row.segment_scope_json) AS items(value)
      )
      AND target.allocation_plan_id IS NOT NULL;

    IF v2_target_count = 0
       AND NOT EXISTS (
           SELECT 1
           FROM promotion_run_target_bindings
           WHERE promotion_run_id = p_promotion_run_id
       ) THEN
        RETURN;
    END IF;

    SELECT jsonb_agg(to_jsonb(segment_id) ORDER BY segment_id COLLATE "C")
    INTO bound_segment_ids
    FROM promotion_run_target_bindings
    WHERE promotion_run_id = p_promotion_run_id;

    IF bound_segment_ids IS DISTINCT FROM run_row.segment_scope_json THEN
        RAISE EXCEPTION 'run binding set must match the run segment scope'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_run_target_bindings AS binding
        JOIN promotion_target_segments AS target
          ON target.analysis_id = binding.target_analysis_id
         AND target.segment_id = binding.segment_id
        JOIN segment_audience_allocation_plans AS plan
          ON plan.allocation_plan_id = binding.allocation_plan_id
        JOIN segment_audience_snapshots AS snapshot
          ON snapshot.snapshot_id = binding.final_snapshot_id
        JOIN generation_runs AS generation
          ON generation.generation_id = run_row.generation_id
        WHERE binding.promotion_run_id = p_promotion_run_id
          AND (
              binding.target_analysis_id <> run_row.analysis_id
              OR target.project_id <> run_row.project_id
              OR target.campaign_id <> run_row.campaign_id
              OR target.promotion_id <> run_row.promotion_id
              OR target.allocation_plan_id <> binding.allocation_plan_id
              OR target.audience_snapshot_id <> binding.final_snapshot_id
              OR target.audience_reservation_state <> 'consumed'
              OR plan.status <> 'locked'
              OR plan.target_analysis_id <> run_row.analysis_id
              OR plan.promotion_id <> run_row.promotion_id
              OR snapshot.snapshot_kind <> 'final'
              OR generation.analysis_id <> run_row.analysis_id
              OR generation.project_id <> run_row.project_id
              OR generation.campaign_id <> run_row.campaign_id
              OR generation.promotion_id <> run_row.promotion_id
          )
    ) THEN
        RAISE EXCEPTION 'run binding identity or lifecycle mismatch'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM promotion_run_target_bindings AS binding
        JOIN segment_audience_snapshots AS snapshot
          ON snapshot.snapshot_id = binding.final_snapshot_id
        WHERE binding.promotion_run_id = p_promotion_run_id
          AND (
              SELECT count(*)
              FROM promotion_audience_exclusion_members AS excluded
              WHERE excluded.target_analysis_id = binding.target_analysis_id
                AND excluded.segment_id = binding.segment_id
                AND excluded.allocation_plan_id = binding.allocation_plan_id
                AND excluded.final_snapshot_id = binding.final_snapshot_id
                AND excluded.state = 'consumed'
          ) <> snapshot.final_user_count
    ) THEN
        RAISE EXCEPTION 'run binding consumed member count mismatch'
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION validate_promotion_run_target_bindings_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_run_id VARCHAR(100);
BEGIN
    affected_run_id := CASE
        WHEN TG_OP = 'DELETE' THEN OLD.promotion_run_id
        ELSE NEW.promotion_run_id
    END;
    PERFORM assert_promotion_run_target_bindings(affected_run_id);
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER trg_validate_promotion_run_binding
AFTER INSERT
ON promotion_run_target_bindings
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_promotion_run_target_bindings_trigger();

CREATE CONSTRAINT TRIGGER trg_validate_promotion_run_scope
AFTER INSERT OR UPDATE
ON promotion_runs
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_promotion_run_target_bindings_trigger();



DO $$
DECLARE
    required_relations TEXT[] := ARRAY[
        'segment_audience_allocation_plans',
        'promotion_audience_exclusion_state',
        'promotion_audience_exclusion_members',
        'promotion_run_target_bindings'
    ];
    missing_relations TEXT[];
BEGIN
    SELECT array_agg(relation_name ORDER BY relation_name)
    INTO missing_relations
    FROM unnest(required_relations) AS required(relation_name)
    WHERE to_regclass(relation_name) IS NULL;

    IF missing_relations IS NOT NULL THEN
        RAISE EXCEPTION
            'lean allocation expansion is incomplete; missing relations: %',
            missing_relations;
    END IF;
END
$$;

COMMIT;
