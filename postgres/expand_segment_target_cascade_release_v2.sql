BEGIN;

-- Immutable run bindings remain as execution history after a target is
-- stopped. In that state, the target and its exclusion members are released
-- instead of consumed.
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
              OR target.audience_reservation_state <>
                  CASE
                      WHEN target.status = 'stopped' THEN 'released'
                      ELSE 'consumed'
                  END
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
        JOIN promotion_target_segments AS target
          ON target.analysis_id = binding.target_analysis_id
         AND target.segment_id = binding.segment_id
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
                AND excluded.state =
                    CASE
                        WHEN target.status = 'stopped' THEN 'released'
                        ELSE 'consumed'
                    END
          ) <> snapshot.final_user_count
    ) THEN
        RAISE EXCEPTION 'run binding member count mismatch'
            USING ERRCODE = '23514';
    END IF;
END
$$;

COMMIT;
