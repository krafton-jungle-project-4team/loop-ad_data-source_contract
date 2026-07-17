-- =========================================================
-- Build Demo User Behavior Vectors From Expedia Train Data
--
-- Input:
-- - expedia_hotel_events loaded from Kaggle train.csv
--
-- Output:
-- - user_behavior_vectors rows for Decision analysis clustering
--
-- Vector contract:
-- - project_id: demo_project
-- - vector_dim: 64
-- - vector_version: v1
-- - source: batch_profile
--
-- Vector layout:
-- - 0..5: user behavior summary features
-- - 6..37: hotel_cluster preference distribution, 32 buckets
-- - 38..53: destination preference distribution, 16 buckets
-- - 54..63: channel distribution, 10 buckets
--
-- This file intentionally does not use destinations.csv.
-- destinations.csv can be added later for richer destination embeddings.
-- =========================================================

INSERT INTO user_behavior_vectors (
    project_id,
    user_id,
    vector_dim,
    vector_values,
    vector_version,
    source,
    window_start,
    window_end
)
WITH grouped AS (
    SELECT
        toString(user_id) AS user_id,
        count() AS event_count,
        avg(toFloat64(is_mobile)) AS mobile_ratio,
        avg(toFloat64(is_package)) AS package_ratio,
        avg(toFloat64(is_booking)) AS booking_rate,
        avg(if(srch_children_cnt > 0, 1.0, 0.0)) AS family_ratio,
        avg(
            if(
                isNull(srch_ci) OR isNull(srch_co),
                0.0,
                least(greatest(dateDiff('day', srch_ci, srch_co), 0), 14) / 14.0
            )
        ) AS stay_nights_score,
        avg(
            if(
                isNull(srch_ci),
                0.5,
                1.0 - (least(greatest(dateDiff('day', toDate(date_time), srch_ci), 0), 60) / 60.0)
            )
        ) AS near_checkin_score,
        groupArray(toUInt64(hotel_cluster) % 32) AS hotel_cluster_buckets,
        groupArray(cityHash64(toString(srch_destination_id)) % 16) AS destination_buckets,
        groupArray(toUInt64(channel) % 10) AS channel_buckets,
        min(date_time) AS window_start,
        max(date_time) AS window_end
    FROM expedia_hotel_events
    GROUP BY user_id
)
SELECT
    'demo_project' AS project_id,
    user_id,
    toUInt16(64) AS vector_dim,
    arrayConcat(
        [
            toFloat32(mobile_ratio),
            toFloat32(package_ratio),
            toFloat32(booking_rate),
            toFloat32(family_ratio),
            toFloat32(stay_nights_score),
            toFloat32(near_checkin_score)
        ],
        arrayMap(
            bucket -> toFloat32(arrayCount(value -> value = bucket, hotel_cluster_buckets) / event_count),
            range(32)
        ),
        arrayMap(
            bucket -> toFloat32(arrayCount(value -> value = bucket, destination_buckets) / event_count),
            range(16)
        ),
        arrayMap(
            bucket -> toFloat32(arrayCount(value -> value = bucket, channel_buckets) / event_count),
            range(10)
        )
    ) AS vector_values,
    'v1' AS vector_version,
    'batch_profile' AS source,
    toDateTime64(window_start, 3, 'UTC') AS window_start,
    toDateTime64(window_end, 3, 'UTC') AS window_end
FROM grouped
WHERE user_id NOT IN (
    SELECT user_id
    FROM user_behavior_vectors
    WHERE project_id = 'demo_project'
      AND vector_version = 'v1'
);

SELECT
    count() AS vector_count,
    uniqExact(user_id) AS user_count,
    min(length(vector_values)) AS min_vector_length,
    max(length(vector_values)) AS max_vector_length
FROM user_behavior_vectors
WHERE project_id = 'demo_project'
  AND vector_version = 'v1';
