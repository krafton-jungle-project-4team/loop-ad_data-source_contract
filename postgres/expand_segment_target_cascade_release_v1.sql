BEGIN;

-- A deleted snapshot-backed target keeps its historical rows, but it no longer
-- owns an active promotion audience reservation. This is the soft-delete
-- boundary used by Dashboard target deletion and Decision confirmation repair.
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

    IF OLD.status = 'locked' AND NEW.status = 'released' THEN
        IF EXISTS (
            SELECT 1
            FROM promotion_target_segments target
            WHERE target.allocation_plan_id = NEW.allocation_plan_id
              AND (
                  target.status <> 'stopped'
                  OR target.audience_reservation_state <> 'released'
              )
        ) THEN
            RAISE EXCEPTION
                'locked allocation plan still has an active target'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'invalid allocation plan transition: % -> %',
        OLD.status, NEW.status
        USING ERRCODE = '55000';
END
$$;

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

    IF OLD.audience_reservation_state = 'consumed'
       AND NEW.audience_reservation_state = 'released'
       AND NEW.status = 'stopped' THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'invalid target reservation transition: % -> %',
        OLD.audience_reservation_state,
        NEW.audience_reservation_state
        USING ERRCODE = '55000';
END
$$;

CREATE OR REPLACE FUNCTION enforce_promotion_audience_exclusion_member_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_revision BIGINT;
    target_project_id VARCHAR(100);
    target_promotion_id VARCHAR(100);
    target_status VARCHAR(50);
    previous_target_status VARCHAR(50);
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

    SELECT project_id, promotion_id, status
    INTO target_project_id, target_promotion_id, target_status
    FROM promotion_target_segments
    WHERE analysis_id = NEW.target_analysis_id
      AND segment_id = NEW.segment_id
      AND allocation_plan_id = NEW.allocation_plan_id
      AND audience_snapshot_id = NEW.final_snapshot_id;

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

    IF OLD.state = 'consumed' AND NEW.state = 'released' THEN
        IF target_status <> 'stopped' THEN
            RAISE EXCEPTION
                'consumed exclusion can be released only for a stopped target'
                USING ERRCODE = '55000';
        END IF;
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
            RAISE EXCEPTION 'consumed reservation binding is immutable'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    IF OLD.state = 'released' AND NEW.state = 'reserved' THEN
        RETURN NEW;
    END IF;

    IF OLD.state IN ('reserved', 'consumed') AND NEW.state = 'reserved' THEN
        SELECT status
        INTO previous_target_status
        FROM promotion_target_segments
        WHERE analysis_id = OLD.target_analysis_id
          AND segment_id = OLD.segment_id
          AND allocation_plan_id = OLD.allocation_plan_id
          AND audience_snapshot_id = OLD.final_snapshot_id;

        IF previous_target_status = 'stopped' THEN
            RETURN NEW;
        END IF;
    END IF;

    RAISE EXCEPTION 'invalid exclusion transition: % -> %',
        OLD.state, NEW.state
        USING ERRCODE = '55000';
END
$$;

-- A locked plan may keep immutable run bindings after its target is stopped.
-- The target and exclusion members are released while the plan remains locked
-- as historical execution provenance.
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
                      WHEN target.status = 'stopped' THEN 'released'
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

COMMIT;
