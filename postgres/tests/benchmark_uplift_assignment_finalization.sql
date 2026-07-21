\set ON_ERROR_STOP on

CREATE TEMP TABLE benchmark_final_members (
    user_id TEXT PRIMARY KEY,
    segment_id TEXT NOT NULL,
    snapshot_id TEXT NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE TEMP TABLE benchmark_experiment_units (
    user_id TEXT PRIMARY KEY,
    segment_id TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    experiment_id TEXT NOT NULL,
    arm TEXT NOT NULL,
    treatment_probability NUMERIC(12, 9) NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE TEMP TABLE benchmark_serving_assignments (
    user_id TEXT PRIMARY KEY,
    segment_id TEXT NOT NULL,
    experiment_id TEXT NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE TEMP TABLE benchmark_allocation_manifest (
    experiment_id TEXT PRIMARY KEY,
    segment_id TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    unit_count INTEGER NOT NULL,
    treatment_count INTEGER NOT NULL,
    control_count INTEGER NOT NULL,
    actual_treatment_ratio NUMERIC(12, 9) NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE TEMP TABLE benchmark_results (
    fixture_size INTEGER PRIMARY KEY,
    commit_latency_ms NUMERIC NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE OR REPLACE PROCEDURE pg_temp.run_uplift_finalization_benchmark(
    p_fixture_size INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    started_at TIMESTAMPTZ;
    elapsed_ms NUMERIC;
BEGIN
    TRUNCATE
        benchmark_final_members,
        benchmark_experiment_units,
        benchmark_serving_assignments,
        benchmark_allocation_manifest;

    started_at := clock_timestamp();

    INSERT INTO benchmark_final_members (user_id, segment_id, snapshot_id)
    SELECT
        'benchmark_user_' || lpad(value::TEXT, 6, '0'),
        'benchmark_segment',
        'benchmark_snapshot'
    FROM generate_series(1, p_fixture_size) AS value;

    INSERT INTO benchmark_experiment_units (
        user_id,
        segment_id,
        snapshot_id,
        experiment_id,
        arm,
        treatment_probability
    )
    SELECT
        user_id,
        segment_id,
        snapshot_id,
        'benchmark_experiment',
        CASE
            WHEN row_number() OVER (ORDER BY user_id) <= p_fixture_size / 2
            THEN 'treatment'
            ELSE 'control'
        END,
        0.5
    FROM benchmark_final_members;

    INSERT INTO benchmark_serving_assignments (
        user_id,
        segment_id,
        experiment_id
    )
    SELECT user_id, segment_id, experiment_id
    FROM benchmark_experiment_units
    WHERE arm = 'treatment';

    INSERT INTO benchmark_allocation_manifest (
        experiment_id,
        segment_id,
        snapshot_id,
        unit_count,
        treatment_count,
        control_count,
        actual_treatment_ratio
    ) VALUES (
        'benchmark_experiment',
        'benchmark_segment',
        'benchmark_snapshot',
        p_fixture_size,
        p_fixture_size / 2,
        p_fixture_size - (p_fixture_size / 2),
        0.5
    );

    IF EXISTS (
        (SELECT * FROM benchmark_final_members
         EXCEPT
         SELECT user_id, segment_id, snapshot_id
         FROM benchmark_experiment_units)
    ) OR EXISTS (
        (SELECT user_id, segment_id, snapshot_id
         FROM benchmark_experiment_units
         EXCEPT
         SELECT * FROM benchmark_final_members)
    ) THEN
        RAISE EXCEPTION 'benchmark final audience differs from units';
    END IF;

    IF EXISTS (
        (SELECT user_id, segment_id, experiment_id
         FROM benchmark_experiment_units
         WHERE arm = 'treatment'
         EXCEPT
         SELECT * FROM benchmark_serving_assignments)
    ) OR EXISTS (
        (SELECT * FROM benchmark_serving_assignments
         EXCEPT
         SELECT user_id, segment_id, experiment_id
         FROM benchmark_experiment_units
         WHERE arm = 'treatment')
    ) THEN
        RAISE EXCEPTION 'benchmark treatment units differ from serving';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM benchmark_allocation_manifest AS manifest
        LEFT JOIN (
            SELECT
                experiment_id,
                segment_id,
                snapshot_id,
                count(*)::INTEGER AS unit_count,
                count(*) FILTER (WHERE arm = 'treatment')::INTEGER
                    AS treatment_count,
                count(*) FILTER (WHERE arm = 'control')::INTEGER
                    AS control_count,
                min(treatment_probability) AS min_probability,
                max(treatment_probability) AS max_probability
            FROM benchmark_experiment_units
            GROUP BY experiment_id, segment_id, snapshot_id
        ) AS actual
          USING (experiment_id, segment_id, snapshot_id)
        WHERE manifest.unit_count <> actual.unit_count
           OR manifest.treatment_count <> actual.treatment_count
           OR manifest.control_count <> actual.control_count
           OR manifest.actual_treatment_ratio <> actual.min_probability
           OR manifest.actual_treatment_ratio <> actual.max_probability
    ) THEN
        RAISE EXCEPTION 'benchmark manifest quota differs from units';
    END IF;

    COMMIT;

    elapsed_ms := extract(
        epoch FROM clock_timestamp() - started_at
    ) * 1000;
    INSERT INTO benchmark_results (fixture_size, commit_latency_ms)
    VALUES (p_fixture_size, elapsed_ms);
    COMMIT;
END
$$;

CALL pg_temp.run_uplift_finalization_benchmark(1000);
CALL pg_temp.run_uplift_finalization_benchmark(10000);

DO $$
DECLARE
    small_ms NUMERIC;
    large_ms NUMERIC;
BEGIN
    SELECT commit_latency_ms
    INTO small_ms
    FROM benchmark_results
    WHERE fixture_size = 1000;

    SELECT commit_latency_ms
    INTO large_ms
    FROM benchmark_results
    WHERE fixture_size = 10000;

    RAISE NOTICE
        'uplift finalization commit latency: 1000 users=% ms, 10000 users=% ms',
        round(small_ms, 2),
        round(large_ms, 2);

    IF small_ms > 10000 OR large_ms > 30000 THEN
        RAISE EXCEPTION
            'uplift finalization commit latency exceeded the safety ceiling';
    END IF;

    IF large_ms > greatest(small_ms, 1000) * 30 THEN
        RAISE EXCEPTION
            'uplift finalization latency shows a non-linear regression';
    END IF;
END
$$;
