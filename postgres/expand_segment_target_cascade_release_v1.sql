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

COMMIT;
