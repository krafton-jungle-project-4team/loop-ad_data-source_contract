# loop-ad_data-source_contract

LoopAd의 로컬 데이터 소스 계약을 공유하는 최소 repo입니다.

이 repo는 운영 migration history를 관리하지 않습니다. 현재 기준 파일은 호텔 예약 프로모션 도메인의 PostgreSQL 운영 스키마와 ClickHouse `hotel_rec_promo.v1` 분석 스키마입니다.

## 구조

```text
.
├── clickhouse/
│   ├── backfill_user_behavior_vector_revisions.sql
│   ├── build_user_behavior_vectors_from_expedia.sql
│   ├── database.sql
│   ├── drop.sql
│   ├── expand_user_behavior_vector_revisions.sql
│   ├── load_train_csv.sh
│   ├── named-collection.example.sql
│   ├── tests/
│   │   └── verify_user_behavior_vector_revisions.sql
│   └── schema.sql
├── postgres/
│   ├── dummy.sql
│   ├── expand_generation_v1.sql
│   ├── backfill_generation_v1.sql
│   ├── finalize_generation_v1.sql
│   ├── expand_segment_assignment_execution_provenance.sql
│   ├── expand_promotion_automation_v1.sql
│   ├── expand_promotion_run_segment_scope.sql
│   ├── backfill_promotion_run_segment_scope.sql
│   ├── finalize_promotion_run_segment_scope.sql
│   ├── tests/
│   │   ├── repair_legacy_fixture_fallbacks.sql
│   │   ├── verify_generation_v1.sql
│   │   ├── verify_promotion_automation_v1.sql
│   │   ├── verify_promotion_run_segment_scope.sql
│   │   └── verify_segment_assignment_execution_provenance.sql
│   └── schema.sql
├── scripts/
│   ├── verify_clickhouse_contract.sh
│   └── verify_postgres_contract.sh
├── environments/
│   ├── dashboard.env
│   └── local.env
├── docker-compose.local-fixture.yml
├── docker-compose.yml
└── README.md
```

## 로컬 환경

팀 공통 로컬 환경변수는 `environments/local.env`에 둡니다. 개인 환경에서 port나 계정을 바꿔야 하면, 각자 로컬 실행 환경에서만 조정합니다.

로컬 endpoint:

| Service | URL |
|---|---|
| PostgreSQL | `localhost:15432` |
| ClickHouse HTTP | `http://localhost:18123` |
| ClickHouse Native | `localhost:19000` |

앱 repo에서 사용할 수 있는 추천 환경변수:

```bash
LOOPAD_POSTGRES_URL=postgresql://loopad:loopad@localhost:15432/loopad
LOOPAD_CLICKHOUSE_URL=http://localhost:18123
LOOPAD_CLICKHOUSE_DATABASE=loopad
LOOPAD_CLICKHOUSE_USERNAME=loopad_app
LOOPAD_CLICKHOUSE_PASSWORD=loopad_local_password
```

`loopad`, `loopad_local_password`는 로컬 개발용 값입니다. 운영 secret이나 실제 password를 이 repo에 넣지 않습니다.

Dashboard local fixture는 기본 Compose와 분리된 PostgreSQL `15433`, ClickHouse HTTP `18124`, Native `19001` 포트를 사용합니다.

```bash
docker compose \
  --env-file environments/dashboard.env \
  -f docker-compose.yml \
  -f docker-compose.local-fixture.yml \
  up -d postgres clickhouse
```

기본 Compose와 운영 환경은 변경하지 않으며, fixture에서만 pgvector 이미지를 사용합니다.

### 실험 평가 시연 fixture

이미영 기획자가 과거에 운영한 이력처럼 확인할 수 있도록 기존 캠페인을 수정하지 않고 `demo_project`에 `여름 성수기 지역 숙박 예약 전환 캠페인` 전체 계층을 별도로 생성합니다. 캠페인 아래에는 고객군 분석, 광고 소재, 배정, 실험, 이벤트, 평가가 연결된 세 가지 프로모션이 포함됩니다.

| 프로모션 | 실험 | 평가 | 고정 퍼널 | 변경 내용/주요 관측 이탈 |
|---|---:|---|---|---|
| 부산 주중 2박 연박 할인 | 1차 | 목표 달성 | 184 → 157 → 129 → 71 → 29명 | 목표 달성 후 전략 유지 |
| 강릉 가족여행 조식 패키지 | 1차 | 목표 미달 | 156 → 63 → 52 → 27 → 11명 | 광고 랜딩 → 숙소 탐색 이탈 |
| 강릉 가족여행 조식 패키지 | 2차 | 목표 달성 | 152 → 121 → 101 → 65 → 24명 | 조식 조건과 강릉 검색 CTA를 랜딩 첫 화면에 일치시킴 |
| 여수 오션뷰 주말 얼리버드 | 1차 | 목표 미달 | 173 → 151 → 126 → 79 → 12명 | 예약 시작 → 예약 완료 이탈 |
| 여수 오션뷰 주말 얼리버드 | 2차 | 목표 미달 | 168 → 148 → 124 → 83 → 18명 | 최종 금액·무료 취소 기한을 표시했으나 목표 미달 |
| 여수 오션뷰 주말 얼리버드 | 3차 | 목표 달성 | 165 → 147 → 127 → 91 → 25명 | 객실·가격 사전 안내와 결제 입력 단계 축소 |

Dashboard fixture DB를 시작한 다음 아래 명령으로 전용 캠페인을 생성합니다. 목표 미달 평가는 다음 회차의 `parent_ad_experiment_id`, `source_evaluation_id`, `next_loop_preparations`와 연결되어 Dashboard에서 개선 전후 실험을 순서대로 확인할 수 있습니다. 시드는 고정 ID를 사용해 재실행할 수 있고, 삭제·갱신 범위는 해당 캠페인의 assignment와 fixture event로 한정됩니다.

```bash
./scripts/seed_demo_experiment_funnel.sh
```

AWS dev는 먼저 읽기 전용 preflight를 실행한 뒤 명시적으로 적용합니다. 대상 AWS 계정, Aurora cluster, ClickHouse instance를 코드에서 검증하며 secret 값은 출력하지 않습니다.

```bash
python3 scripts/seed_demo_historical_campaign.py
python3 scripts/seed_demo_historical_campaign.py --apply
```

PostgreSQL의 `assignment_source = 'fixture'`, ClickHouse의 `source = 'fixture'`, 평가의 `diagnosis.data_origin.kind = 'demo_fixture'`로 실제 운영 데이터와 구분합니다. 이 시드는 local/AWS dev 시연 전용이며 운영 migration 목록에는 포함하지 않습니다.

## 현재 계약 요약

PostgreSQL은 `Campaign -> Promotion -> Segment -> Ad Experiment` 실행 상태를 저장하며, ANN segment matching을 위해 `pgvector` extension을 사용합니다. 핵심 테이블은 `campaigns`, `promotions`, `promotion_analyses`, `promotion_target_segments`, `generation_runs`, `content_candidates`, `promotion_runs`, `ad_experiments`, `promotion_evaluations`, `next_loop_preparations`, `user_segment_assignments`, `segment_query_previews`, `segment_definitions`입니다.

Fallback 식별자인 `seg_existing_all`은 특정 프로젝트에 속하지 않는 전역 `system_default` 세그먼트입니다. `postgres/schema.sql`이 fresh DB에서도 이 행을 생성하며, 이 행에 한해서만 `segment_definitions.project_id`가 `NULL`일 수 있습니다. 그 밖의 모든 세그먼트는 기존처럼 프로젝트 ID가 필수입니다. Dashboard와 Decision은 fallback 여부를 계속 `segment_id = 'seg_existing_all'`로 판별합니다.

Manual next-loop 관련 preparation·child lineage·legacy serving provenance 계약은 `postgres/schema.sql`에 정의합니다. 실제 dev/운영 DB 적용은 별도 운영 절차로 수행하며 migration history는 관리하지 않습니다.

프로모션 실행 방식은 `manual`과 `automatic`을 지원합니다. 예약 시작·종료 시각과 반복 평가 간격은 `promotions`에 저장하고, 자동 실행 작업은 `promotion_automation_jobs`에서 run별 `launch_run`·`evaluate_run` 작업으로 관리합니다. 프로모션의 명시적 실행 기간은 상위 캠페인 기간 안에 있어야 하며, 프로모션 일정이 깨지는 캠페인 기간 축소도 DB에서 차단합니다. 캠페인 날짜 경계는 `Asia/Seoul` 기준으로 시작일 00:00부터 종료일 다음 날 00:00 직전까지입니다. 기존 프로모션은 migration 이후에도 `manual`, 1일 간격 기본값을 유지하며 자동 작업은 생성되지 않습니다.

기존 dev/운영 PostgreSQL에는 애플리케이션 배포 전에 다음 additive migration을 먼저 적용합니다. `schema.sql`은 fresh DB 기준 파일이며 기존 Docker volume에서는 `/docker-entrypoint-initdb.d`가 다시 실행되지 않습니다.

```bash
psql -X -v ON_ERROR_STOP=1 \
  "$LOOPAD_POSTGRES_URL" \
  -f postgres/expand_promotion_automation_v1.sql
```

migration은 재실행할 수 있습니다. 적용 후 `promotions.execution_mode`, 예약·반복 간격 컬럼, 캠페인-프로모션 일정 트리거와 `promotion_automation_jobs` 테이블·인덱스를 확인한 다음 Dashboard를 배포합니다.

Promotion run의 full composite identity는 `project_id + promotion_id + analysis_id + generation_id + segment_scope_fingerprint + loop_count`입니다. `segment_scope_fingerprint`는 fallback `seg_existing_all`을 제외하고 C collation으로 정렬·중복 제거한 segment ID 배열의 compact JSON SHA-256입니다. 따라서 다른 `analysis_id` 또는 `generation_id`는 같은 promotion·loop·scope라도 별도 실행 identity입니다. Dashboard 문서에서 쓰는 `promotion_id + loop_count + segment_scope_fingerprint`는 조회 맥락을 설명하는 축약 표현이며 실제 unique key를 뜻하지 않습니다.

Dashboard의 SDK Tracking Plan은 기존 `projects.write_key`를 공개 connection ID 겸 write key로 사용합니다. `tracking_plans`와 `tracking_plan_events`가 편집 가능한 draft를, `tracking_plan_revisions`가 게시 시점의 immutable JSON snapshot을, `project_sdk_settings`가 허용 Origin과 활성 게시 revision을 보관합니다. 게시 처리는 애플리케이션에서 revision insert와 활성 revision 변경을 같은 transaction으로 실행해야 합니다.

ClickHouse는 `raw_events`를 원천으로 두고 `promotion_touch_events`, `booking_outcome_events`, `hotel_detail_events`, `funnel_step_events`, `hotel_marketing_profiles`, `user_behavior_vectors`를 제공합니다. 이벤트 이름은 호텔 예약 도메인 기준의 `hotel_search`, `hotel_click`, `hotel_detail_view`, `booking_start`, `booking_complete`, `booking_cancel`, `promotion_impression`, `promotion_click`, `campaign_redirect_click`, `campaign_landing`을 사용합니다.

## Segment assignment execution provenance

`segment_assignment_executions`는 비동기 build lifecycle이 아니라 한 번의 matcher
실행에 사용한 요청, 입력, matcher와 cutoff를 기록하는 최소 provenance table입니다.
`user_segment_assignments.segment_assignment_execution_id`는 nullable FK이므로 기존
assignment row는 모두 `NULL`을 유지합니다. 기존 producer는 이 컬럼을 생략할 수
있으며 `active_ad_serving_assignments` 정의와 hot path는 변경하지 않습니다.
Assignment와 execution을 연결할 때 두 row의 `promotion_run_id`는 반드시 같아야
하며 DB composite FK가 이를 보장합니다.

실행 row의 `request_fingerprint`와 `input_fingerprint`는 lowercase SHA-256이고,
`input_manifest_json`은 JSON object입니다. 동일 run에서 같은 request fingerprint는
한 execution만 허용합니다. Matcher 전략 이름은 Decision이 소유하므로 DB에서 enum
CHECK로 닫지 않습니다. 새 assignment를 provenance에 연결할 때는 execution insert와
assignment write를 같은 애플리케이션 transaction에서 수행합니다.

기준 schema에 additive expand를 적용하려면 다음 파일을 사용합니다.

```bash
psql -v ON_ERROR_STOP=1 \
  -f postgres/expand_segment_assignment_execution_provenance.sql
```

이 계약에는 status, lifecycle 함수, staging result, publication pointer, trigger 또는
신규 serving view가 없습니다.

## Deterministic user behavior vector revisions

기존 `user_behavior_vectors`는 ingestion과 기존 consumer를 위해 그대로 유지합니다.
`mv_user_behavior_vectors_to_revisions`는 이후 INSERT를 append-only
`user_behavior_vector_revisions`에 복제합니다. `vector_row_id`는 random UUID가
아니며 다음 순서의 canonical JSON tuple을 SHA-256한 lowercase hex 문자열입니다.

```text
project_id
user_id
vector_version
toUnixTimestamp64Milli(updated_at)
vector_dim
vector_values
source as String
toUnixTimestamp64Milli(window_start)
toUnixTimestamp64Milli(window_end)
```

기존 visible vector는 MV 생성 뒤 자동 복제되지 않으므로 expand 이후 backfill을
실행합니다. Backfill은 `user_behavior_vectors FINAL`의 실행 시점 visible state만
initial baseline으로 취급합니다. 기존 `ReplacingMergeTree`가 이미 제거한 historical
row를 복구한다고 주장하지 않습니다. 동일 payload의 반복 backfill은 같은
`vector_row_id`를 생성하므로 physical duplicate가 생겨도 canonical latest payload는
달라지지 않습니다.

```bash
clickhouse-client --multiquery \
  < clickhouse/expand_user_behavior_vector_revisions.sql
clickhouse-client --multiquery \
  < clickhouse/backfill_user_behavior_vector_revisions.sql
```

Decision의 `list_by_user_ids()`와 `list_for_project()`는 아래 aggregation을 공유해야
합니다. 두 메서드는 user selection predicate만 다르며 `source`가 지정되면 반드시
`argMax` 이전 `WHERE`에 추가합니다. Cutoff는 inclusive가 아니라
`ingested_at < source_cutoff_at`입니다.

```sql
SELECT
    project_id,
    user_id,
    vector_version,
    tupleElement(selected_payload, 1) AS vector_dim,
    tupleElement(selected_payload, 2) AS vector_values,
    tupleElement(selected_payload, 3) AS source,
    tupleElement(selected_payload, 4) AS window_start,
    tupleElement(selected_payload, 5) AS window_end,
    tupleElement(selected_payload, 6) AS updated_at,
    tupleElement(selected_payload, 7) AS vector_row_id
FROM (
    SELECT
        project_id,
        user_id,
        vector_version,
        argMax(
            tuple(
                vector_dim,
                vector_values,
                CAST(source, 'String'),
                window_start,
                window_end,
                updated_at,
                vector_row_id
            ),
            tuple(updated_at, vector_row_id)
        ) AS selected_payload
    FROM user_behavior_vector_revisions
    WHERE project_id = {project_id:String}
      AND vector_version = {vector_version:String}
      AND ingested_at < {source_cutoff_at:DateTime64(6, 'UTC')}
      -- source가 지정되면: AND source = {source:String}
      -- explicit list: AND user_id IN {user_ids:Array(String)}
      -- project keyset: AND tuple(user_id, vector_version) > (...)
    GROUP BY project_id, user_id, vector_version
)
ORDER BY user_id, vector_version;
```

Payload 컬럼마다 별도 `argMax`를 사용하면 동일 winner key에서 서로 다른 physical
row의 값이 섞일 수 있으므로 금지합니다. Winner key는 항상
`tuple(updated_at, vector_row_id)`입니다. PostgreSQL execution의
`source_cutoff_at`, `vector_version`, `input_fingerprint`, `input_manifest_json`은 이
canonical input selection을 재현하는 provenance입니다.

격리된 PostgreSQL과 ClickHouse에서 fresh/migrated/backfill 계약을 검증합니다.

```bash
BASE_REF=origin/main \
EXECUTION_BASE_REF=ca4f456f40255ec758937a8c84ea7f5566cc9d0a \
./scripts/verify_postgres_contract.sh

CLICKHOUSE_BASE_REF=ca4f456f40255ec758937a8c84ea7f5566cc9d0a \
./scripts/verify_clickhouse_contract.sh
```

## Promotion run segment scope 전환

Decision의 `LOOPAD_PARTIAL_PROMOTION_RUN_SCOPE_ENABLED` 기본값은 `false`입니다. OFF 상태에서는 다음 계약을 유지합니다.

- `segment_ids`를 포함한 신규 run은 lifecycle write 전에 409를 반환합니다.
- failed-only 자동 next-loop는 write 전에 409를 반환합니다.
- manual preparation 생성과 활성화는 write 전에 409를 반환합니다.
- `segment_ids`를 생략한 run 요청만 전체 generation scope로 처리합니다.

Finalize 전에 flag를 ON으로 바꾸면 기존 `uq_promotion_runs_loop` 때문에 같은 promotion/loop의 다른 scope가 충돌할 수 있습니다. ECS task별 image/revision 또는 flag가 다르면 같은 요청이 task에 따라 200과 409를 오갈 수 있습니다. 기존 run의 scope, target experiment, fallback experiment 중 하나라도 손상됐으면 Decision의 기존 run 재사용 무결성 검사에서 409를 반환합니다. 이 응답은 데이터 무결성 오류이며 JSON 직렬화 문제로 오인하면 안 됩니다.

기존 DB에는 다음 순서를 유지합니다.

1. `expand_promotion_run_segment_scope.sql`로 scope 컬럼을 추가하고 기존 `seg_existing_all`을 전역 fallback으로 정규화
2. Decision dual-write 배포 후 모든 task에서 flag OFF 유지
3. 아래 preflight 확인 후 기존 run backfill과 target/fallback 무결성 검증
4. `finalize_promotion_run_segment_scope.sql`로 composite unique 적용
5. Dashboard의 `segment_ids`와 `is_fallback` 파싱 반영
6. 모든 dev task를 같은 image/revision과 flag ON으로 교체
7. dev smoke test
8. Dashboard/Advertisement 연동과 dispatch 재시도 확인
9. 운영 전체 task에서 flag 일괄 ON

이 migration은 단계적이지만 무중단을 보장하지 않습니다. Backfill은 `promotion_runs`에 `SHARE ROW EXCLUSIVE`, `ad_experiments`에 `SHARE` lock을 잡고 전체 대상 row를 갱신합니다. Finalize의 `SET NOT NULL`, CHECK, UNIQUE 변경도 쓰기를 차단할 수 있는 강한 lock을 사용합니다. 테이블 크기와 현재 transaction을 확인하고, 데이터 규모가 크거나 쓰기 트래픽이 지속되면 maintenance window를 확보합니다.

Backfill 전에 크기, 장기 transaction, scope 원천 누락, fallback 누락, 계산 후 중복을 확인합니다.

```sql
SELECT
    relname,
    n_live_tup,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE relname IN ('promotion_runs', 'ad_experiments')
ORDER BY relname;

SELECT pid, state, xact_start, query_start, wait_event_type, wait_event
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
  AND xact_start IS NOT NULL
ORDER BY xact_start;

SELECT pr.promotion_run_id
FROM promotion_runs AS pr
WHERE NOT EXISTS (
    SELECT 1
    FROM ad_experiments AS ae
    WHERE ae.promotion_run_id = pr.promotion_run_id
      AND ae.segment_id <> 'seg_existing_all'
);

SELECT pr.promotion_run_id
FROM promotion_runs AS pr
WHERE (
    SELECT count(*)
    FROM ad_experiments AS ae
    WHERE ae.promotion_run_id = pr.promotion_run_id
      AND ae.segment_id = 'seg_existing_all'
) <> 1;

WITH distinct_segments AS (
    SELECT DISTINCT promotion_run_id, segment_id
    FROM ad_experiments
    WHERE segment_id <> 'seg_existing_all'
), computed_scopes AS (
    SELECT
        pr.project_id,
        pr.promotion_id,
        pr.analysis_id,
        pr.generation_id,
        pr.loop_count,
        encode(
            digest(
                convert_to(
                    '[' || string_agg(
                        to_json(ds.segment_id)::text,
                        ',' ORDER BY ds.segment_id COLLATE "C"
                    ) || ']',
                    'UTF8'
                ),
                'sha256'
            ),
            'hex'
        ) AS segment_scope_fingerprint
    FROM promotion_runs AS pr
    JOIN distinct_segments AS ds USING (promotion_run_id)
    GROUP BY
        pr.promotion_run_id,
        pr.project_id,
        pr.promotion_id,
        pr.analysis_id,
        pr.generation_id,
        pr.loop_count
)
SELECT
    project_id,
    promotion_id,
    analysis_id,
    generation_id,
    segment_scope_fingerprint,
    loop_count,
    count(*)
FROM computed_scopes
GROUP BY
    project_id,
    promotion_id,
    analysis_id,
    generation_id,
    segment_scope_fingerprint,
    loop_count
HAVING count(*) > 1;
```

Finalize 전에는 아래 쿼리가 모두 0건이어야 합니다.

```sql
SELECT promotion_run_id
FROM promotion_runs
WHERE segment_scope_json IS NULL
   OR segment_scope_fingerprint IS NULL
   OR NOT is_valid_promotion_run_segment_scope(
        segment_scope_json,
        segment_scope_fingerprint
   );

SELECT
    project_id,
    promotion_id,
    analysis_id,
    generation_id,
    segment_scope_fingerprint,
    loop_count,
    count(*)
FROM promotion_runs
GROUP BY
    project_id,
    promotion_id,
    analysis_id,
    generation_id,
    segment_scope_fingerprint,
    loop_count
HAVING count(*) > 1;

SELECT pr.promotion_run_id
FROM promotion_runs AS pr
WHERE jsonb_array_length(pr.segment_scope_json) <> (
        SELECT count(*)
        FROM ad_experiments AS ae
        WHERE ae.promotion_run_id = pr.promotion_run_id
          AND ae.segment_id <> 'seg_existing_all'
    )
   OR (
        SELECT count(*)
        FROM ad_experiments AS ae
        WHERE ae.promotion_run_id = pr.promotion_run_id
          AND ae.segment_id = 'seg_existing_all'
   ) <> 1
   OR EXISTS (
        SELECT scope_segment.segment_id
        FROM jsonb_array_elements_text(
            pr.segment_scope_json
        ) AS scope_segment(segment_id)
        EXCEPT
        SELECT ae.segment_id
        FROM ad_experiments AS ae
        WHERE ae.promotion_run_id = pr.promotion_run_id
          AND ae.segment_id <> 'seg_existing_all'
   )
   OR EXISTS (
        SELECT ae.segment_id
        FROM ad_experiments AS ae
        WHERE ae.promotion_run_id = pr.promotion_run_id
          AND ae.segment_id <> 'seg_existing_all'
        EXCEPT
        SELECT scope_segment.segment_id
        FROM jsonb_array_elements_text(
            pr.segment_scope_json
        ) AS scope_segment(segment_id)
   );
```

세 migration 파일은 각각 하나의 transaction이며 재실행할 수 있습니다. 파일 실행이 실패하면 해당 transaction을 `ROLLBACK`하고 원인 row 또는 lock 경합을 해소한 뒤 같은 단계를 다시 실행합니다. `psql -v ON_ERROR_STOP=1 -f ...`처럼 실패 시 연결을 종료하는 실행 방식은 미완료 transaction을 자동 rollback합니다. 이전 단계가 성공했더라도 적용 순서를 건너뛰지 않습니다.

Dashboard rollout blocker는 별도로 해소해야 합니다. `promotion_id + loop_count + LIMIT 1`로 run을 고르면 동일 loop의 다른 scope를 잘못 연결할 수 있으므로 금지합니다. 단건 run은 `promotion_run_id`로 조회하고, next-loop 연결은 `parent_ad_experiment_id` 또는 preparation/activation lineage로 추적합니다. Dashboard가 `segment_ids`와 `is_fallback`을 파싱하고 모든 dev task가 동일 revision으로 교체되기 전에는 flag를 켜면 안 됩니다.

Fresh schema/dummy 재실행, main 기준 3단계 migration 재실행, 실패 rollback, multi-scope, malformed scope, fixture lineage를 격리된 임시 PostgreSQL에서 검증하려면 다음 명령을 사용합니다. 스크립트는 실행이 끝나면 임시 container를 삭제하며 공유 DB에 접속하지 않습니다.

```bash
BASE_REF=origin/main ./scripts/verify_postgres_contract.sh
```

Scope migration이 main에 병합된 뒤에는 `origin/main` 자체가 이미 최종 scope
schema를 포함합니다. 검증 스크립트는 이 경우 first-parent history를 따라가
`segment_scope_json` 도입 전의 가장 가까운 schema를 legacy 기준으로 자동
선택합니다. 선택한 commit은 로그에 출력되며, pre-scope schema를 찾을 수
없으면 검증을 중단합니다. GitHub Actions는 이 history를 사용할 수 있도록
`fetch-depth: 0` checkout을 유지해야 합니다.

## Generation v1 legacy migration runbook

### 정리 정책

Generation v1 cutover에서는 **미완성 legacy `completed` run을 `failed`로 일회성 재분류**한다. 이는 애플리케이션의 정상 상태 전이가 아니다. `completed`와 `failed`는 모두 terminal이라는 상태 계약을 유지하며, 아래 승인된 migration 절차에서만 과거의 잘못된 완료 판정을 교정한다.

정리 대상은 `input_json`에 `schema_version` key가 없고 Decision dual-write cutover 시각보다 먼저 생성된 run으로 한정한다. `generation.request.v1` row, cutover 이후 row, 알 수 없는 schema version의 불일치는 정리하지 않고 rollout을 중단해 애플리케이션 결함으로 조사한다. 일반 backfill이나 finalize에 ID allowlist, cutoff 예외 또는 자동 `failed` 전환을 넣지 않는다.

이미지나 HTML artifact가 없는 row에 게시 완료 값을 만들어 넣거나 strict serving view에 legacy 예외를 추가하지 않는다. `input_json`, `output_json`, `generation_report_json`, idempotency identity, candidate/artifact/approval 상태와 promotion/experiment/evaluation 이력도 수정하지 않는다. 이 정책은 미완성 광고가 serving되는 것보다 가용성을 낮추는 fail-closed 전환을 우선한다.

콘텐츠가 계속 필요하면 Decision dual-write 배포 후 기존 row를 `requested`로 되돌리지 않고 **새 `generation_id`와 새 idempotency key를 가진 v1 요청**으로 재생성한다. 기존 idempotency key를 재사용하면 기존 terminal run이 반환될 수 있다. 새 run이 `completed`된 뒤 downstream 소유자가 정상 승인 흐름으로 새 promotion run/experiment/assignment를 생성하며, SQL로 기존 FK나 promotion scope/fallback provenance를 갈아끼우지 않는다.

`postgres/dummy.sql`은 로컬 fixture 전용이다. shared dev, staging, production의 legacy 정리에 실행하면 안 된다.

### 적용 순서

아래 순서를 건너뛰지 않는다.

1. 격리 container에서 `./scripts/verify_postgres_contract.sh`를 통과시킨다. 이 검증은 공유 DB에 연결하지 않는다.
2. DB snapshot/PITR 복구 가능 여부, change ticket, maintenance window와 담당자를 확정한다. 대상 generation/candidate/downstream baseline은 보안 저장소에 export하고 manifest checksum을 ticket에 기록한다.
3. 장기 transaction, lock 대기와 대상 table 크기를 확인한 뒤 `expand_generation_v1.sql`을 적용한다.
4. 신규 요청·candidate가 v1 컬럼을 명시적으로 쓰고 expanded/final schema를 모두 읽을 수 있는 Decision revision을 모든 task에 배포한 뒤 이전 task를 drain한다.
5. drain 뒤 snapshot을 격리 preflight DB로 복원한다. 실제 DB와 snapshot의 writer를 고정한 상태에서 raw fingerprint를 수집하고, 격리 DB에서 backfill을 rehearsal한 뒤 아래 finalizer-parity blocker 목록을 만든다.
6. `LEGACY_FAILED_CANDIDATE`만 명시적 ID manifest로 만들고 전체 downstream 영향, export, checksum과 change approval을 완료한다. v1 또는 post-cutover blocker가 하나라도 있으면 중단한다.
7. Generation/candidate, analysis target, downstream writer와 serving/dispatch traffic을 중지하고, 승인 manifest만 실제 DB에서 `failed`로 일회성 재분류한다.
8. traffic을 재개하지 않은 채 실제 DB에 `backfill_generation_v1.sql`을 적용한다.
9. 실제 DB에서 blocker query가 0건인지 다시 확인한 뒤 곧바로 `finalize_generation_v1.sql`을 적용한다.
10. production용 read-only postflight와 serving smoke test를 통과한 뒤 writer/traffic을 재개한다. 필요한 콘텐츠는 정상 API로 새 v1 request를 접수한다.

즉 실제 DB의 순서는 다음과 같다.

```text
expand
→ Decision dual-write 배포 및 이전 worker drain
→ legacy preflight/영향 확인/failed 전환
→ backfill
→ post-backfill preflight 0건 확인
→ finalize
```

Cleanup commit과 finalize 성공 사이에는 Generation, candidate, promotion target 및 downstream writer와 serving/dispatch traffic을 재개하지 않는다. 기준 legacy view는 generation status gate가 없을 수 있어 finalize가 실패한 부분 배포 상태에서 `failed` row가 계속 노출될 수 있다. 이 경우 maintenance를 유지하고 원인을 해결한 뒤 finalize를 재실행한다.

`postgres/tests/verify_generation_v1.sql`은 fixture를 transaction 안에서 변경하므로 운영 DB에서 실행하지 않는다. 운영에서는 이 runbook의 read-only preflight/postflight만 사용한다.

세 migration은 `psql -X -v ON_ERROR_STOP=1`로 실행한다.

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f postgres/expand_generation_v1.sql
```

### Dual-write 확인

DB query만으로 이전 task가 종료됐음을 증명할 수 없다. 배포 control plane에서 새 revision의 desired/running task가 일치하고 이전 revision task와 in-flight 작업이 0인지 확인한다. 그 확인 시각을 immutable `dual_write_cutover_at`으로 ticket에 기록한다. 아래 두 쿼리는 cutover 이후 write가 v1 계약을 지키는지 확인하는 별도 data gate이며 모두 0건이어야 한다.

```sql
\set dual_write_cutover_at '2026-07-14 00:00:00+09'

SELECT generation_id
FROM public.generation_runs
WHERE created_at >= :'dual_write_cutover_at'::timestamptz
  AND (
      idempotency_key IS NULL
      OR request_fingerprint IS NULL
      OR input_json ->> 'schema_version' IS DISTINCT FROM
          'generation.request.v1'
      OR retry_count < 0
      OR (
          status = 'running'
          AND (
              started_at IS NULL
              OR worker_id IS NULL
              OR lease_token IS NULL
              OR heartbeat_at IS NULL
              OR lease_expires_at IS NULL
          )
      )
  );

SELECT generation_id
FROM public.generation_runs AS run
WHERE run.created_at >= :'dual_write_cutover_at'::timestamptz
  AND run.status = 'completed'
  AND (
      NOT EXISTS (
          SELECT 1
          FROM public.content_candidates AS candidate
          WHERE candidate.generation_id = run.generation_id
      )
      OR EXISTS (
          SELECT 1
          FROM public.content_candidates AS candidate
          WHERE candidate.generation_id = run.generation_id
            AND (
                (
                    candidate.channel = 'sms'
                    AND candidate.creative_format = 'sms_text'
                    AND candidate.message IS NOT NULL
                    AND candidate.image_generation_status = 'not_required'
                    AND candidate.artifact_status = 'not_required'
                )
                OR (
                    candidate.channel IN ('email', 'onsite_banner')
                    AND candidate.creative_format = CASE candidate.channel
                        WHEN 'email' THEN 'email_html'
                        ELSE 'banner_html'
                    END
                    AND candidate.image_generation_status = 'completed'
                    AND candidate.image_url IS NOT NULL
                    AND candidate.artifact_status = 'published'
                    AND candidate.artifact_storage_key IS NOT NULL
                    AND candidate.artifact_public_url IS NOT NULL
                    AND candidate.artifact_sha256 IS NOT NULL
                    AND candidate.artifact_content_type IS NOT NULL
                    AND candidate.artifact_published_at IS NOT NULL
                )
            ) IS NOT TRUE
      )
  );
```

### 격리 DB preflight

실제 DB에서 cleanup 전에 backfill을 먼저 실행하지 않는다. dual-write 배포와 이전 worker drain 뒤에 snapshot을 복원한 격리 DB에서, **backfill 전에** 아래 raw fingerprint를 보안 저장소로 export한다. 이 값은 승인 manifest와 실제 전환 transaction의 optimistic gate로 사용한다.

```sql
\set dual_write_cutover_at '2026-07-14 00:00:00+09'
SET TIME ZONE 'UTC';

SELECT
    run.generation_id,
    run.updated_at AS expected_updated_at,
    encode(
        digest(to_jsonb(run)::text, 'sha256'),
        'hex'
    ) AS expected_run_fingerprint,
    candidate_set.expected_candidate_fingerprint,
    target_set.expected_target_fingerprint
FROM public.generation_runs AS run
CROSS JOIN LATERAL (
    SELECT encode(
        digest(
            COALESCE(
                jsonb_agg(
                    to_jsonb(candidate)
                    ORDER BY candidate.content_id
                ) FILTER (WHERE candidate.content_id IS NOT NULL),
                '[]'::jsonb
            )::text,
            'sha256'
        ),
        'hex'
    ) AS expected_candidate_fingerprint
    FROM public.content_candidates AS candidate
    WHERE candidate.generation_id = run.generation_id
) AS candidate_set
CROSS JOIN LATERAL (
    SELECT encode(
        digest(
            COALESCE(
                jsonb_agg(
                    to_jsonb(target)
                    ORDER BY target.id
                ) FILTER (WHERE target.id IS NOT NULL),
                '[]'::jsonb
            )::text,
            'sha256'
        ),
        'hex'
    ) AS expected_target_fingerprint
    FROM public.promotion_target_segments AS target
    WHERE target.analysis_id = run.analysis_id
) AS target_set
WHERE run.status = 'completed'
  AND run.created_at < :'dual_write_cutover_at'::timestamptz
  AND NOT (run.input_json ? 'schema_version')
ORDER BY run.generation_id;
```

같은 격리 DB에서 다음 rehearsal을 수행한다.

```bash
psql "$PREFLIGHT_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f postgres/expand_generation_v1.sql
psql "$PREFLIGHT_DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f postgres/backfill_generation_v1.sql
```

Backfill이 `[request_identity]`, `[job_lifecycle]`, `[candidate_lifecycle]` 중 하나로 실패하면 출력된 ID부터 원인을 확인하고 실제 DB를 변경하지 않는다. Backfill이 성공하면 격리 DB에서 아래 query를 실행한다. 이 query는 finalize가 첫 오류에서 멈추는 것과 달리 네 완료 위반 범주를 모든 run에 대해 한 번에 출력한다.

```sql
\set dual_write_cutover_at '2026-07-14 00:00:00+09'
SET TIME ZONE 'UTC';

WITH completed_runs AS (
    SELECT
        generation_id,
        analysis_id,
        content_option_count,
        input_json,
        created_at,
        updated_at,
        finished_at,
        input_json ? 'target_segments' AS has_target_snapshot,
        COALESCE(
            input_json ->> 'schema_version' = 'generation.request.v1',
            false
        ) AS requires_target_snapshot
    FROM public.generation_runs
    WHERE status = 'completed'
), snapshot_damage AS (
    SELECT run.generation_id
    FROM completed_runs AS run
    WHERE (
          run.requires_target_snapshot
          AND NOT run.has_target_snapshot
      )
       OR (
          run.has_target_snapshot
          AND (
              jsonb_typeof(run.input_json -> 'target_segments')
                  IS DISTINCT FROM 'array'
              OR jsonb_array_length(
                  CASE
                      WHEN jsonb_typeof(
                          run.input_json -> 'target_segments'
                      ) = 'array'
                      THEN run.input_json -> 'target_segments'
                      ELSE '[]'::jsonb
                  END
              ) = 0
              OR EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements(
                      CASE
                          WHEN jsonb_typeof(
                              run.input_json -> 'target_segments'
                          ) = 'array'
                          THEN run.input_json -> 'target_segments'
                          ELSE '[]'::jsonb
                      END
                  ) AS target(value)
                  WHERE jsonb_typeof(target.value) <> 'object'
                     OR NULLIF(
                         btrim(target.value ->> 'segment_id'),
                         ''
                     ) IS NULL
              )
              OR (
                  SELECT count(*) <> count(
                      DISTINCT btrim(target.value ->> 'segment_id')
                  )
                  FROM jsonb_array_elements(
                      CASE
                          WHEN jsonb_typeof(
                              run.input_json -> 'target_segments'
                          ) = 'array'
                          THEN run.input_json -> 'target_segments'
                          ELSE '[]'::jsonb
                      END
                  ) AS target(value)
              )
          )
      )
), snapshot_segments AS (
    SELECT
        run.generation_id,
        btrim(target.value ->> 'segment_id') AS segment_id
    FROM completed_runs AS run
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE
            WHEN jsonb_typeof(run.input_json -> 'target_segments') = 'array'
            THEN run.input_json -> 'target_segments'
            ELSE '[]'::jsonb
        END
    ) AS target(value)
    WHERE run.has_target_snapshot
), expected_segments AS (
    SELECT generation_id, segment_id
    FROM snapshot_segments

    UNION

    SELECT run.generation_id, target.segment_id
    FROM completed_runs AS run
    JOIN public.promotion_target_segments AS target
      ON target.analysis_id = run.analysis_id
    WHERE NOT run.has_target_snapshot
      AND NOT run.requires_target_snapshot
), count_damage AS (
    SELECT run.generation_id
    FROM completed_runs AS run
    WHERE NOT EXISTS (
            SELECT 1
            FROM expected_segments AS expected
            WHERE expected.generation_id = run.generation_id
        )
       OR EXISTS (
            SELECT 1
            FROM expected_segments AS expected
            WHERE expected.generation_id = run.generation_id
              AND (
                  SELECT count(*)
                  FROM public.content_candidates AS candidate
                  WHERE candidate.generation_id = run.generation_id
                    AND candidate.segment_id = expected.segment_id
              ) <> run.content_option_count
        )
       OR EXISTS (
            SELECT 1
            FROM public.content_candidates AS candidate
            WHERE candidate.generation_id = run.generation_id
              AND NOT EXISTS (
                  SELECT 1
                  FROM expected_segments AS expected
                  WHERE expected.generation_id = run.generation_id
                    AND expected.segment_id = candidate.segment_id
              )
        )
), readiness_damage AS (
    SELECT run.generation_id
    FROM completed_runs AS run
    WHERE NOT EXISTS (
            SELECT 1
            FROM public.content_candidates AS candidate
            WHERE candidate.generation_id = run.generation_id
        )
       OR EXISTS (
            SELECT 1
            FROM public.content_candidates AS candidate
            WHERE candidate.generation_id = run.generation_id
              AND (
                  (
                      candidate.channel = 'sms'
                      AND candidate.creative_format = 'sms_text'
                      AND candidate.message IS NOT NULL
                      AND candidate.image_generation_status = 'not_required'
                      AND candidate.artifact_status = 'not_required'
                  )
                  OR (
                      candidate.channel IN ('email', 'onsite_banner')
                      AND candidate.creative_format = CASE candidate.channel
                          WHEN 'email' THEN 'email_html'
                          ELSE 'banner_html'
                      END
                      AND candidate.image_generation_status = 'completed'
                      AND candidate.image_url IS NOT NULL
                      AND candidate.artifact_status = 'published'
                      AND candidate.artifact_storage_key IS NOT NULL
                      AND candidate.artifact_public_url IS NOT NULL
                      AND candidate.artifact_sha256 IS NOT NULL
                      AND candidate.artifact_content_type IS NOT NULL
                      AND candidate.artifact_published_at IS NOT NULL
                  )
              ) IS NOT TRUE
        )
), timeline_damage AS (
    SELECT DISTINCT run.generation_id
    FROM completed_runs AS run
    JOIN public.content_candidates AS candidate
      USING (generation_id)
    WHERE candidate.artifact_status = 'published'
      AND (
          candidate.created_at > candidate.artifact_published_at
          OR candidate.artifact_published_at > run.finished_at
      )
), damage AS (
    SELECT
        generation_id,
        1 AS reason_rank,
        'completed_target_snapshot'::TEXT AS reason
    FROM snapshot_damage
    UNION ALL
    SELECT generation_id, 2, 'completed_candidate_count'
    FROM count_damage
    UNION ALL
    SELECT generation_id, 3, 'completed_candidate_readiness'
    FROM readiness_damage
    UNION ALL
    SELECT generation_id, 4, 'completed_candidate_timeline'
    FROM timeline_damage
)
SELECT
    damage.generation_id,
    CASE
        WHEN run.input_json ->> 'schema_version' =
             'generation.request.v1'
        THEN 'STOP_V1_DEFECT'
        WHEN run.created_at >=
             :'dual_write_cutover_at'::timestamptz
        THEN 'STOP_POST_CUTOVER_WRITE'
        WHEN NOT (run.input_json ? 'schema_version')
        THEN 'LEGACY_FAILED_CANDIDATE'
        ELSE 'STOP_UNKNOWN_SCHEMA'
    END AS disposition,
    run.created_at,
    run.updated_at AS expected_updated_at,
    min(damage.reason_rank) AS first_reason_rank,
    array_agg(
        damage.reason
        ORDER BY damage.reason_rank, damage.reason
    ) AS reasons
FROM damage
JOIN completed_runs AS run USING (generation_id)
GROUP BY
    damage.generation_id,
    run.input_json,
    run.created_at,
    run.updated_at
ORDER BY min(damage.reason_rank), damage.generation_id;
```

`LEGACY_FAILED_CANDIDATE`만 raw fingerprint와 join해 manifest에 넣는다. 다른 disposition이 한 건이라도 있으면 rollout을 중단한다. 각 manifest row에는 ID, expected timestamp, run/candidate/promotion-target fingerprint, 전체 reason 배열을 고정한다. Transaction에서 검증할 canonical target JSON hash와 export 파일 자체의 checksum은 구분해 둘 다 승인 change ticket에 기록한다. `reason_rank`는 finalize의 검사 순서와 같으며 첫 row의 첫 reason은 `finalize_generation_v1.sql`의 첫 실패 marker와 일치해야 한다. 불일치하면 실제 DB cleanup으로 진행하지 않는다.

격리 preflight DB에서 승인 target으로 아래 transaction의 downstream 집계 CTE만 먼저 실행한다. 정렬된 집계 row의 canonical JSON hash를 `expected_impact_sha256`으로 기록한 뒤 context+targets operation hash를 계산한다. Actual transaction은 두 hash를 모두 lock 안에서 재계산하므로 승인된 영향도와 달라진 row가 있으면 `COMMIT` 전에 중단된다.

요구된 실제 순서가 cleanup 다음 backfill이므로 actual DB에서는 cleanup 전에 normalized finalizer query를 실행할 수 없다. 대신 동일 snapshot의 raw run/candidate/promotion-target 전체 fingerprint, 승인된 migration 파일 checksum과 writer drain을 고정한다. Transaction이 세 fingerprint를 lock 안에서 다시 계산해 exact match를 강제하므로, 격리 DB에서 결정적으로 재현한 backfill/finalizer reason과 actual 입력 사이의 차이가 있으면 전환 전에 중단된다.

### Downstream 영향 확인과 `failed` 전환

아래 transaction은 maintenance window에 한 세션에서 실행한다. 고정된 cutover context와 승인 manifest를 `VALUES`에 넣는다. `expected_impact_sha256`은 preflight의 canonical downstream 집계 hash이고, `manifest_sha256`은 impact hash를 포함한 context와 target row 전체를 canonical JSON으로 묶은 operation hash다. 기본 마지막 문장은 안전하게 `ROLLBACK`이다. 먼저 그대로 rehearsal하고, 같은 context/manifest로 다시 실행해 모든 gate가 통과한 경우에만 마지막 문장을 `COMMIT`으로 바꾼다.

```sql
BEGIN;

SET LOCAL lock_timeout = '30s';
SET LOCAL TIME ZONE 'UTC';

-- Backfill과 같은 선행 lock 순서를 사용하고 downstream 신규 참조도 막는다.
LOCK TABLE public.generation_runs IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.content_candidates IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.promotion_target_segments IN SHARE MODE;
LOCK TABLE public.promotion_runs IN SHARE MODE;
LOCK TABLE public.ad_experiments IN SHARE MODE;
LOCK TABLE public.promotion_evaluations IN SHARE MODE;
LOCK TABLE public.next_loop_preparations IN SHARE MODE;
LOCK TABLE public.user_segment_assignments IN SHARE MODE;
LOCK TABLE public.ad_dispatch_jobs IN SHARE MODE;
LOCK TABLE public.redirect_links IN SHARE MODE;

CREATE TEMP TABLE generation_v1_cleanup_context (
    cutover_id TEXT PRIMARY KEY,
    dual_write_cutover_at TIMESTAMPTZ NOT NULL,
    cleanup_at TIMESTAMPTZ NOT NULL,
    approval_ref TEXT NOT NULL CHECK (
        btrim(approval_ref) <> ''
        AND approval_ref <> 'CHG-REPLACE-ME'
    ),
    expected_target_count INT NOT NULL CHECK (expected_target_count > 0),
    expected_impact_sha256 CHAR(64) NOT NULL CHECK (
        expected_impact_sha256 ~ '^[0-9a-f]{64}$'
    ),
    manifest_sha256 CHAR(64) NOT NULL CHECK (
        manifest_sha256 ~ '^[0-9a-f]{64}$'
    ),
    CHECK (cleanup_at >= dual_write_cutover_at)
) ON COMMIT DROP;

-- 모든 값은 승인 ticket의 고정값으로 교체한다. 재실행할 때도 바꾸지 않는다.
INSERT INTO generation_v1_cleanup_context VALUES (
    'generation-v1-2026-07-14',
    '2026-07-14 00:00:00+09',
    '2026-07-14 01:00:00+09',
    'CHG-REPLACE-ME',
    1,
    repeat('0', 64),
    repeat('0', 64)
);

CREATE TEMP TABLE generation_v1_cleanup_targets (
    generation_id VARCHAR(100) PRIMARY KEY,
    expected_updated_at TIMESTAMPTZ NOT NULL,
    expected_run_fingerprint CHAR(64) NOT NULL CHECK (
        expected_run_fingerprint ~ '^[0-9a-f]{64}$'
    ),
    expected_candidate_fingerprint CHAR(64) NOT NULL CHECK (
        expected_candidate_fingerprint ~ '^[0-9a-f]{64}$'
    ),
    expected_target_fingerprint CHAR(64) NOT NULL CHECK (
        expected_target_fingerprint ~ '^[0-9a-f]{64}$'
    ),
    expected_reasons TEXT[] NOT NULL CHECK (
        cardinality(expected_reasons) > 0
    )
) ON COMMIT DROP;

-- Placeholder를 승인 manifest의 실제 값으로 교체한다.
INSERT INTO generation_v1_cleanup_targets (
    generation_id,
    expected_updated_at,
    expected_run_fingerprint,
    expected_candidate_fingerprint,
    expected_target_fingerprint,
    expected_reasons
)
VALUES
    (
        'replace-with-generation-id',
        '2026-07-14 00:00:00+00',
        repeat('0', 64),
        repeat('0', 64),
        repeat('0', 64),
        ARRAY['completed_candidate_readiness']::TEXT[]
    );

DO $$
DECLARE
    actual_target_count BIGINT;
    actual_manifest_sha256 TEXT;
    expected_target_count INT;
    expected_manifest_sha256 TEXT;
BEGIN
    IF (SELECT count(*) FROM generation_v1_cleanup_context) <> 1 THEN
        RAISE EXCEPTION 'Generation cleanup context must contain one row';
    END IF;

    SELECT
        count(*),
        encode(
            digest(
                convert_to(
                    jsonb_build_object(
                        'context', jsonb_build_object(
                            'cutover_id', context.cutover_id,
                            'dual_write_cutover_at',
                                context.dual_write_cutover_at,
                            'cleanup_at', context.cleanup_at,
                            'approval_ref', context.approval_ref,
                            'expected_target_count',
                                context.expected_target_count,
                            'expected_impact_sha256',
                                btrim(context.expected_impact_sha256)
                        ),
                        'targets', COALESCE(
                            jsonb_agg(
                                jsonb_build_object(
                                    'generation_id', target.generation_id,
                                    'expected_updated_at',
                                        target.expected_updated_at,
                                    'expected_run_fingerprint',
                                        btrim(
                                            target.expected_run_fingerprint
                                        ),
                                    'expected_candidate_fingerprint',
                                        btrim(
                                            target.expected_candidate_fingerprint
                                        ),
                                    'expected_target_fingerprint',
                                        btrim(
                                            target.expected_target_fingerprint
                                        ),
                                    'expected_reasons',
                                        to_jsonb(target.expected_reasons)
                                ) ORDER BY target.generation_id
                            ),
                            '[]'::jsonb
                        )
                    )::text,
                    'UTF8'
                ),
                'sha256'
            ),
            'hex'
        )
    INTO actual_target_count, actual_manifest_sha256
    FROM generation_v1_cleanup_targets AS target
    CROSS JOIN generation_v1_cleanup_context AS context
    GROUP BY
        context.cutover_id,
        context.dual_write_cutover_at,
        context.cleanup_at,
        context.approval_ref,
        context.expected_target_count,
        context.expected_impact_sha256;

    SELECT
        context.expected_target_count,
        btrim(context.manifest_sha256)
    INTO expected_target_count, expected_manifest_sha256
    FROM generation_v1_cleanup_context AS context;

    IF actual_target_count <> expected_target_count
       OR actual_manifest_sha256 <> expected_manifest_sha256 THEN
        RAISE EXCEPTION 'Generation cleanup manifest count/hash mismatch';
    END IF;
END
$$;

-- Raw snapshot이 승인 뒤 바뀌지 않았는지 확인한다. 이미 같은 cutover로
-- 적용된 row는 already_applied로 분류되어 다시 갱신되지 않는다.
CREATE TEMP TABLE generation_v1_cleanup_target_state
ON COMMIT DROP
AS
SELECT
    target.generation_id,
    CASE
        WHEN run.status = 'completed'
         AND run.created_at < context.dual_write_cutover_at
         AND NOT (run.input_json ? 'schema_version')
         AND run.updated_at IS NOT DISTINCT FROM target.expected_updated_at
         AND context.cleanup_at >= run.created_at
         AND context.cleanup_at >= run.updated_at
         AND (
                run.started_at IS NULL
                OR context.cleanup_at >= run.started_at
             )
         AND (
                run.finished_at IS NULL
                OR context.cleanup_at >= run.finished_at
             )
         AND encode(
                digest(to_jsonb(run)::text, 'sha256'),
                'hex'
             ) = btrim(target.expected_run_fingerprint)
         AND candidate_set.fingerprint =
             btrim(target.expected_candidate_fingerprint)
         AND target_set.fingerprint =
             btrim(target.expected_target_fingerprint)
        THEN 'pending'
        WHEN run.status = 'failed'
         AND run.created_at < context.dual_write_cutover_at
         AND NOT (run.input_json ? 'schema_version')
         AND run.last_error_code = 'LEGACY_ARTIFACT_INCOMPLETE'
         AND run.last_error_message = format(
                'Generation v1 legacy cleanup %s; approval=%s; manifest=%s',
                context.cutover_id,
                context.approval_ref,
                btrim(context.manifest_sha256)
             )
         AND run.updated_at = context.cleanup_at
        THEN 'already_applied'
        ELSE 'invalid'
    END AS transition_state,
    run.created_at AS original_created_at,
    run.started_at AS original_started_at,
    run.finished_at AS original_finished_at,
    run.retry_count AS original_retry_count
FROM generation_v1_cleanup_targets AS target
CROSS JOIN generation_v1_cleanup_context AS context
LEFT JOIN public.generation_runs AS run USING (generation_id)
LEFT JOIN LATERAL (
    SELECT encode(
        digest(
            COALESCE(
                jsonb_agg(
                    to_jsonb(candidate)
                    ORDER BY candidate.content_id
                ) FILTER (WHERE candidate.content_id IS NOT NULL),
                '[]'::jsonb
            )::text,
            'sha256'
        ),
        'hex'
    ) AS fingerprint
    FROM public.content_candidates AS candidate
    WHERE candidate.generation_id = target.generation_id
) AS candidate_set ON true
LEFT JOIN LATERAL (
    SELECT encode(
        digest(
            COALESCE(
                jsonb_agg(
                    to_jsonb(promotion_target)
                    ORDER BY promotion_target.id
                ) FILTER (WHERE promotion_target.id IS NOT NULL),
                '[]'::jsonb
            )::text,
            'sha256'
        ),
        'hex'
    ) AS fingerprint
    FROM public.promotion_target_segments AS promotion_target
    WHERE promotion_target.analysis_id = run.analysis_id
) AS target_set ON true;

DO $$
DECLARE
    invalid_generation_id public.generation_runs.generation_id%TYPE;
BEGIN
    SELECT generation_id
    INTO invalid_generation_id
    FROM generation_v1_cleanup_target_state
    WHERE transition_state = 'invalid'
    ORDER BY generation_id
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'Generation cleanup target changed or is not eligible: %',
            invalid_generation_id;
    END IF;

    IF (SELECT count(*) FROM generation_v1_cleanup_target_state) < 1 THEN
        RAISE EXCEPTION 'Generation cleanup manifest is empty';
    END IF;
END
$$;

-- 각 relation을 독립 집계해 one-to-many join의 count 증폭을 피한다.
CREATE TEMP TABLE generation_v1_cleanup_impact
ON COMMIT DROP
AS
WITH targets AS MATERIALIZED (
    SELECT generation_id
    FROM generation_v1_cleanup_targets
), impacted_runs AS MATERIALIZED (
    SELECT
        target.generation_id AS target_generation_id,
        run.promotion_run_id,
        run.status
    FROM targets AS target
    JOIN public.promotion_runs AS run
      ON run.generation_id = target.generation_id
), impacted_candidates AS MATERIALIZED (
    SELECT
        target.generation_id AS target_generation_id,
        candidate.content_id
    FROM targets AS target
    JOIN public.content_candidates AS candidate
      ON candidate.generation_id = target.generation_id
), impacted_experiment_ids AS MATERIALIZED (
    SELECT
        target.generation_id AS target_generation_id,
        experiment.ad_experiment_id
    FROM targets AS target
    JOIN public.ad_experiments AS experiment
      ON experiment.generation_id = target.generation_id

    UNION

    SELECT
        run.target_generation_id,
        experiment.ad_experiment_id
    FROM impacted_runs AS run
    JOIN public.ad_experiments AS experiment
      ON experiment.promotion_run_id = run.promotion_run_id
), impacted_experiments AS MATERIALIZED (
    SELECT
        edge.target_generation_id,
        experiment.ad_experiment_id,
        experiment.status
    FROM impacted_experiment_ids AS edge
    JOIN public.ad_experiments AS experiment
      ON experiment.ad_experiment_id = edge.ad_experiment_id
), impact AS (
    SELECT
        target_generation_id,
        'promotion_runs'::TEXT AS relation_name,
        status::TEXT AS impact_state,
        count(*)::BIGINT AS row_count
    FROM impacted_runs
    GROUP BY target_generation_id, status

    UNION ALL

    SELECT target_generation_id, 'ad_experiments', status, count(*)
    FROM impacted_experiments
    GROUP BY target_generation_id, status

    UNION ALL

    SELECT
        target.generation_id,
        'next_loop_preparations',
        preparation.status,
        count(*)
    FROM targets AS target
    JOIN public.next_loop_preparations AS preparation
      ON preparation.generation_id = target.generation_id
      OR preparation.source_promotion_run_id IN (
            SELECT run.promotion_run_id
            FROM impacted_runs AS run
            WHERE run.target_generation_id = target.generation_id
         )
      OR preparation.activated_promotion_run_id IN (
            SELECT run.promotion_run_id
            FROM impacted_runs AS run
            WHERE run.target_generation_id = target.generation_id
         )
    GROUP BY target.generation_id, preparation.status

    UNION ALL

    SELECT
        target.generation_id,
        'promotion_evaluations',
        evaluation.status || CASE
            WHEN evaluation.next_loop_required
            THEN ':next_loop_required'
            ELSE ''
        END,
        count(*)
    FROM targets AS target
    JOIN public.promotion_evaluations AS evaluation
      ON evaluation.promotion_run_id IN (
            SELECT run.promotion_run_id
            FROM impacted_runs AS run
            WHERE run.target_generation_id = target.generation_id
         )
      OR evaluation.ad_experiment_id IN (
            SELECT experiment.ad_experiment_id
            FROM impacted_experiments AS experiment
            WHERE experiment.target_generation_id = target.generation_id
         )
      OR evaluation.content_id IN (
            SELECT candidate.content_id
            FROM impacted_candidates AS candidate
            WHERE candidate.target_generation_id = target.generation_id
         )
    GROUP BY
        target.generation_id,
        evaluation.status,
        evaluation.next_loop_required

    UNION ALL

    SELECT
        target.generation_id,
        'user_segment_assignments',
        CASE
            WHEN assignment.expires_at IS NULL
              OR assignment.expires_at > now()
            THEN 'active'
            ELSE 'expired'
        END || CASE
            WHEN assignment.fallback THEN ':fallback'
            ELSE ':direct'
        END,
        count(*)
    FROM targets AS target
    JOIN public.user_segment_assignments AS assignment
      ON assignment.promotion_run_id IN (
            SELECT run.promotion_run_id
            FROM impacted_runs AS run
            WHERE run.target_generation_id = target.generation_id
         )
      OR assignment.ad_experiment_id IN (
            SELECT experiment.ad_experiment_id
            FROM impacted_experiments AS experiment
            WHERE experiment.target_generation_id = target.generation_id
         )
      OR assignment.content_id IN (
            SELECT candidate.content_id
            FROM impacted_candidates AS candidate
            WHERE candidate.target_generation_id = target.generation_id
         )
    GROUP BY
        target.generation_id,
        (assignment.expires_at IS NULL OR assignment.expires_at > now()),
        assignment.fallback

    UNION ALL

    SELECT
        target.generation_id,
        'ad_dispatch_jobs',
        dispatch.status,
        count(*)
    FROM targets AS target
    JOIN public.ad_dispatch_jobs AS dispatch
      ON dispatch.promotion_run_id IN (
            SELECT run.promotion_run_id
            FROM impacted_runs AS run
            WHERE run.target_generation_id = target.generation_id
         )
      OR dispatch.ad_experiment_id IN (
            SELECT experiment.ad_experiment_id
            FROM impacted_experiments AS experiment
            WHERE experiment.target_generation_id = target.generation_id
         )
    GROUP BY target.generation_id, dispatch.status

    UNION ALL

    SELECT
        target.generation_id,
        'redirect_links',
        CASE
            WHEN redirect.expires_at IS NULL OR redirect.expires_at > now()
            THEN 'active'
            ELSE 'expired'
        END,
        count(*)
    FROM targets AS target
    JOIN public.redirect_links AS redirect
      ON redirect.promotion_run_id IN (
            SELECT run.promotion_run_id
            FROM impacted_runs AS run
            WHERE run.target_generation_id = target.generation_id
         )
      OR redirect.ad_experiment_id IN (
            SELECT experiment.ad_experiment_id
            FROM impacted_experiments AS experiment
            WHERE experiment.target_generation_id = target.generation_id
         )
      OR redirect.content_id IN (
            SELECT candidate.content_id
            FROM impacted_candidates AS candidate
            WHERE candidate.target_generation_id = target.generation_id
         )
    GROUP BY
        target.generation_id,
        (redirect.expires_at IS NULL OR redirect.expires_at > now())

    UNION ALL

    SELECT
        candidate.target_generation_id,
        'active_ad_serving_assignments',
        CASE
            WHEN serving.fallback THEN 'exposed:fallback'
            ELSE 'exposed:direct'
        END,
        count(*)
    FROM impacted_candidates AS candidate
    JOIN public.active_ad_serving_assignments AS serving
      ON serving.content_id = candidate.content_id
    GROUP BY candidate.target_generation_id, serving.fallback
)
SELECT
    target.generation_id,
    impact.relation_name,
    impact.impact_state,
    impact.row_count
FROM targets AS target
LEFT JOIN impact
  ON impact.target_generation_id = target.generation_id
ORDER BY
    target.generation_id,
    impact.relation_name,
    impact.impact_state;

SELECT
    generation_id,
    relation_name,
    impact_state,
    row_count
FROM generation_v1_cleanup_impact
ORDER BY generation_id, relation_name, impact_state;

DO $$
DECLARE
    actual_impact_sha256 TEXT;
    expected_impact_sha256 TEXT;
BEGIN
    SELECT encode(
        digest(
            convert_to(
                COALESCE(
                    jsonb_agg(
                        jsonb_build_object(
                            'generation_id', impact.generation_id,
                            'relation_name', impact.relation_name,
                            'impact_state', impact.impact_state,
                            'row_count', impact.row_count
                        ) ORDER BY
                            impact.generation_id,
                            impact.relation_name,
                            impact.impact_state
                    ),
                    '[]'::jsonb
                )::text,
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    )
    INTO actual_impact_sha256
    FROM generation_v1_cleanup_impact AS impact;

    SELECT btrim(context.expected_impact_sha256)
    INTO expected_impact_sha256
    FROM generation_v1_cleanup_context AS context;

    IF actual_impact_sha256 <> expected_impact_sha256 THEN
        RAISE EXCEPTION 'Generation cleanup downstream impact hash mismatch';
    END IF;
END
$$;

-- 활성 downstream이 있으면 SQL로 고치지 않는다. 소유 애플리케이션의 정상
-- pause/cancel/expire/replacement 흐름을 완료한 뒤 새 snapshot으로 다시 승인한다.
DO $$
BEGIN
    IF EXISTS (
        WITH targets AS MATERIALIZED (
            SELECT generation_id
            FROM generation_v1_cleanup_targets
        ), impacted_runs AS MATERIALIZED (
            SELECT
                target.generation_id AS target_generation_id,
                run.promotion_run_id,
                run.status
            FROM targets AS target
            JOIN public.promotion_runs AS run
              ON run.generation_id = target.generation_id
        ), impacted_candidates AS MATERIALIZED (
            SELECT
                target.generation_id AS target_generation_id,
                candidate.content_id
            FROM targets AS target
            JOIN public.content_candidates AS candidate
              ON candidate.generation_id = target.generation_id
        ), impacted_experiment_ids AS MATERIALIZED (
            SELECT
                target.generation_id AS target_generation_id,
                experiment.ad_experiment_id
            FROM targets AS target
            JOIN public.ad_experiments AS experiment
              ON experiment.generation_id = target.generation_id

            UNION

            SELECT
                run.target_generation_id,
                experiment.ad_experiment_id
            FROM impacted_runs AS run
            JOIN public.ad_experiments AS experiment
              ON experiment.promotion_run_id = run.promotion_run_id
        ), impacted_experiments AS MATERIALIZED (
            SELECT
                edge.target_generation_id,
                experiment.ad_experiment_id,
                experiment.status
            FROM impacted_experiment_ids AS edge
            JOIN public.ad_experiments AS experiment
              ON experiment.ad_experiment_id = edge.ad_experiment_id
        )
        SELECT 1
        FROM impacted_runs
        WHERE status IN ('planned', 'approved', 'running', 'evaluating')

        UNION ALL

        SELECT 1
        FROM impacted_experiments
        WHERE status IN ('planned', 'approved', 'running', 'evaluating')

        UNION ALL

        SELECT 1
        FROM targets AS target
        JOIN public.next_loop_preparations AS preparation
          ON preparation.generation_id = target.generation_id
          OR preparation.source_promotion_run_id IN (
                SELECT run.promotion_run_id
                FROM impacted_runs AS run
                WHERE run.target_generation_id = target.generation_id
             )
          OR preparation.activated_promotion_run_id IN (
                SELECT run.promotion_run_id
                FROM impacted_runs AS run
                WHERE run.target_generation_id = target.generation_id
             )
        WHERE preparation.status IN ('awaiting_content_approval', 'activated')

        UNION ALL

        SELECT 1
        FROM targets AS target
        JOIN public.user_segment_assignments AS assignment
          ON assignment.promotion_run_id IN (
                SELECT run.promotion_run_id
                FROM impacted_runs AS run
                WHERE run.target_generation_id = target.generation_id
             )
          OR assignment.ad_experiment_id IN (
                SELECT experiment.ad_experiment_id
                FROM impacted_experiments AS experiment
                WHERE experiment.target_generation_id = target.generation_id
             )
          OR assignment.content_id IN (
                SELECT candidate.content_id
                FROM impacted_candidates AS candidate
                WHERE candidate.target_generation_id = target.generation_id
             )
        WHERE assignment.expires_at IS NULL
           OR assignment.expires_at > now()

        UNION ALL

        SELECT 1
        FROM targets AS target
        JOIN public.ad_dispatch_jobs AS dispatch
          ON dispatch.promotion_run_id IN (
                SELECT run.promotion_run_id
                FROM impacted_runs AS run
                WHERE run.target_generation_id = target.generation_id
             )
          OR dispatch.ad_experiment_id IN (
                SELECT experiment.ad_experiment_id
                FROM impacted_experiments AS experiment
                WHERE experiment.target_generation_id = target.generation_id
             )
        WHERE dispatch.status IN ('queued', 'scheduled', 'running')

        UNION ALL

        SELECT 1
        FROM targets AS target
        JOIN public.redirect_links AS redirect
          ON redirect.promotion_run_id IN (
                SELECT run.promotion_run_id
                FROM impacted_runs AS run
                WHERE run.target_generation_id = target.generation_id
             )
          OR redirect.ad_experiment_id IN (
                SELECT experiment.ad_experiment_id
                FROM impacted_experiments AS experiment
                WHERE experiment.target_generation_id = target.generation_id
             )
          OR redirect.content_id IN (
                SELECT candidate.content_id
                FROM impacted_candidates AS candidate
                WHERE candidate.target_generation_id = target.generation_id
             )
        WHERE redirect.expires_at IS NULL OR redirect.expires_at > now()

        UNION ALL

        SELECT 1
        FROM impacted_candidates AS candidate
        JOIN public.active_ad_serving_assignments AS serving
          ON serving.content_id = candidate.content_id

        LIMIT 1
    ) THEN
        RAISE EXCEPTION
            'Generation cleanup blocked by active downstream state';
    END IF;
END
$$;

CREATE TEMP TABLE generation_v1_cleanup_applied
ON COMMIT DROP
AS
WITH updated AS (
    UPDATE public.generation_runs AS run
    SET status = 'failed',
    started_at = COALESCE(run.started_at, run.created_at),
    finished_at = CASE
        WHEN run.finished_at IS NULL
          OR run.finished_at < COALESCE(run.started_at, run.created_at)
        THEN GREATEST(
            COALESCE(run.started_at, run.created_at),
            run.updated_at
        )
        ELSE run.finished_at
    END,
    next_retry_at = NULL,
    last_error_code = 'LEGACY_ARTIFACT_INCOMPLETE',
    last_error_message = format(
        'Generation v1 legacy cleanup %s; approval=%s; manifest=%s',
        context.cutover_id,
        context.approval_ref,
        btrim(context.manifest_sha256)
    ),
    worker_id = NULL,
    lease_token = NULL,
    heartbeat_at = NULL,
    lease_expires_at = NULL,
    updated_at = context.cleanup_at
    FROM generation_v1_cleanup_target_state AS state
    CROSS JOIN generation_v1_cleanup_context AS context
    WHERE run.generation_id = state.generation_id
      AND state.transition_state = 'pending'
    RETURNING run.generation_id
)
SELECT generation_id FROM updated;

DO $$
DECLARE
    pending_count BIGINT;
    already_applied_count BIGINT;
    applied_count BIGINT;
BEGIN
    SELECT count(*) FILTER (WHERE transition_state = 'pending'),
           count(*) FILTER (WHERE transition_state = 'already_applied')
    INTO pending_count, already_applied_count
    FROM generation_v1_cleanup_target_state;

    SELECT count(*) INTO applied_count
    FROM generation_v1_cleanup_applied;

    IF applied_count <> pending_count
       OR pending_count + already_applied_count < 1
       OR pending_count + already_applied_count <>
          (SELECT count(*) FROM generation_v1_cleanup_targets) THEN
        RAISE EXCEPTION 'Generation cleanup transition count mismatch';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM generation_v1_cleanup_target_state AS state
        JOIN public.generation_runs AS run USING (generation_id)
        CROSS JOIN generation_v1_cleanup_context AS context
        WHERE run.status <> 'failed'
           OR run.last_error_code <> 'LEGACY_ARTIFACT_INCOMPLETE'
           OR run.last_error_message <> format(
                'Generation v1 legacy cleanup %s; approval=%s; manifest=%s',
                context.cutover_id,
                context.approval_ref,
                btrim(context.manifest_sha256)
              )
           OR run.updated_at <> context.cleanup_at
           OR run.started_at IS NULL
           OR run.finished_at IS NULL
           OR run.finished_at < run.started_at
           OR run.next_retry_at IS NOT NULL
           OR run.worker_id IS NOT NULL
           OR run.lease_token IS NOT NULL
           OR run.heartbeat_at IS NOT NULL
           OR run.lease_expires_at IS NOT NULL
           OR run.retry_count IS DISTINCT FROM state.original_retry_count
           OR (
                state.transition_state = 'pending'
                AND state.original_finished_at IS NOT NULL
                AND state.original_finished_at >= COALESCE(
                    state.original_started_at,
                    state.original_created_at
                )
                AND run.finished_at IS DISTINCT FROM
                    state.original_finished_at
           )
    ) THEN
        RAISE EXCEPTION 'Generation cleanup postcondition failed';
    END IF;
END
$$;

ROLLBACK;
```

위 SQL은 `generation_runs`의 상태/lifecycle/error 필드만 바꾼다. retry count, request identity, 세 JSON payload, candidate/artifact/approval 및 downstream row는 그대로 둔다. 따라서 과거 `output_json.status` 값이 남을 수 있지만 serving/작업 상태의 authoritative 값은 `generation_runs.status`이며 payload는 당시 결과의 감사 기록으로 취급한다. 유효한 기존 `finished_at`도 보존하고 교정 시각은 고정 `cleanup_at`과 외부 ticket/export에 남긴다. 동일한 cutover context와 manifest로 재실행하면 `already_applied`만 남아 추가 update 없이 성공한다.

승인된 실제 전환에서는 전체 block을 처음부터 다시 실행하고 마지막 `ROLLBACK;`만 `COMMIT;`으로 바꾼다. Finalize 후 strict serving view는 `generation_runs.status = 'completed'`만 허용하므로 이 run의 assignment는 노출되지 않는다.

### Backfill, finalize, rollback 기준

실제 DB cleanup이 commit된 뒤에만 다음을 실행한다.

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f postgres/backfill_generation_v1.sql
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -f postgres/finalize_generation_v1.sql
```

Backfill 뒤에는 격리 DB에서 사용한 blocker query를 실제 DB에서 다시 실행해 반드시 0건을 확인한다. Finalize가 `[completed_target_snapshot]`, `[completed_candidate_count]`, `[completed_candidate_readiness]`, `[completed_candidate_timeline]` 또는 constraint validation 오류로 실패하면 transaction 전체가 rollback된다. 원인 row를 정리한 뒤 finalize를 다시 실행한다.

#### Production read-only postflight

먼저 finalizer-parity blocker query와 dual-write data gate를 실제 DB에서 다시 실행해 모두 0건인지 확인한다. 이어 승인 manifest ID와 고정 context를 아래 `VALUES`/변수에 넣고 read-only postflight를 실행한다.

```sql
\set cutover_id 'generation-v1-2026-07-14'
\set approval_ref 'CHG-REPLACE-ME'
\set manifest_sha256 'replace-with-approved-operation-sha256'
\set cleanup_at '2026-07-14 01:00:00+09'

WITH targets(generation_id) AS MATERIALIZED (
    VALUES ('replace-with-generation-id'::VARCHAR(100))
), impacted_runs AS MATERIALIZED (
    SELECT
        target.generation_id AS target_generation_id,
        run.promotion_run_id,
        run.status
    FROM targets AS target
    JOIN public.promotion_runs AS run USING (generation_id)
), impacted_candidates AS MATERIALIZED (
    SELECT
        target.generation_id AS target_generation_id,
        candidate.content_id
    FROM targets AS target
    JOIN public.content_candidates AS candidate USING (generation_id)
), impacted_experiment_ids AS MATERIALIZED (
    SELECT
        target.generation_id AS target_generation_id,
        experiment.ad_experiment_id
    FROM targets AS target
    JOIN public.ad_experiments AS experiment USING (generation_id)

    UNION

    SELECT
        run.target_generation_id,
        experiment.ad_experiment_id
    FROM impacted_runs AS run
    JOIN public.ad_experiments AS experiment USING (promotion_run_id)
), impacted_experiments AS MATERIALIZED (
    SELECT
        edge.target_generation_id,
        experiment.ad_experiment_id,
        experiment.status
    FROM impacted_experiment_ids AS edge
    JOIN public.ad_experiments AS experiment USING (ad_experiment_id)
)
SELECT
    target.generation_id,
    run.status = 'failed'
      AND run.last_error_code = 'LEGACY_ARTIFACT_INCOMPLETE'
      AND run.last_error_message = format(
            'Generation v1 legacy cleanup %s; approval=%s; manifest=%s',
            :'cutover_id',
            :'approval_ref',
            :'manifest_sha256'
          )
      AND run.updated_at = :'cleanup_at'::timestamptz
      AND run.started_at IS NOT NULL
      AND run.finished_at >= run.started_at
      AND run.next_retry_at IS NULL
      AND run.worker_id IS NULL
      AND run.lease_token IS NULL
      AND run.heartbeat_at IS NULL
      AND run.lease_expires_at IS NULL
        AS status_contract_ok,
    (SELECT count(*)
     FROM impacted_runs AS item
     WHERE item.target_generation_id = target.generation_id
       AND item.status IN ('planned', 'approved', 'running', 'evaluating'))
        AS active_promotion_run_count,
    (SELECT count(*)
     FROM impacted_experiments AS item
     WHERE item.target_generation_id = target.generation_id
       AND item.status IN ('planned', 'approved', 'running', 'evaluating'))
        AS active_experiment_count,
    (SELECT count(*)
     FROM public.next_loop_preparations AS preparation
     WHERE preparation.status IN ('awaiting_content_approval', 'activated')
       AND (
            preparation.generation_id = target.generation_id
            OR preparation.source_promotion_run_id IN (
                SELECT item.promotion_run_id
                FROM impacted_runs AS item
                WHERE item.target_generation_id = target.generation_id
            )
            OR preparation.activated_promotion_run_id IN (
                SELECT item.promotion_run_id
                FROM impacted_runs AS item
                WHERE item.target_generation_id = target.generation_id
            )
       )) AS active_next_loop_count,
    (SELECT count(*)
     FROM public.user_segment_assignments AS assignment
     WHERE (assignment.expires_at IS NULL OR assignment.expires_at > now())
       AND (
            assignment.promotion_run_id IN (
                SELECT item.promotion_run_id
                FROM impacted_runs AS item
                WHERE item.target_generation_id = target.generation_id
            )
            OR assignment.ad_experiment_id IN (
                SELECT item.ad_experiment_id
                FROM impacted_experiments AS item
                WHERE item.target_generation_id = target.generation_id
            )
            OR assignment.content_id IN (
                SELECT item.content_id
                FROM impacted_candidates AS item
                WHERE item.target_generation_id = target.generation_id
            )
       )) AS active_assignment_count,
    (SELECT count(*)
     FROM public.ad_dispatch_jobs AS dispatch
     WHERE dispatch.status IN ('queued', 'scheduled', 'running')
       AND (
            dispatch.promotion_run_id IN (
                SELECT item.promotion_run_id
                FROM impacted_runs AS item
                WHERE item.target_generation_id = target.generation_id
            )
            OR dispatch.ad_experiment_id IN (
                SELECT item.ad_experiment_id
                FROM impacted_experiments AS item
                WHERE item.target_generation_id = target.generation_id
            )
       )) AS active_dispatch_job_count,
    (SELECT count(*)
     FROM public.redirect_links AS redirect
     WHERE (redirect.expires_at IS NULL OR redirect.expires_at > now())
       AND (
            redirect.promotion_run_id IN (
                SELECT item.promotion_run_id
                FROM impacted_runs AS item
                WHERE item.target_generation_id = target.generation_id
            )
            OR redirect.ad_experiment_id IN (
                SELECT item.ad_experiment_id
                FROM impacted_experiments AS item
                WHERE item.target_generation_id = target.generation_id
            )
            OR redirect.content_id IN (
                SELECT item.content_id
                FROM impacted_candidates AS item
                WHERE item.target_generation_id = target.generation_id
            )
       )) AS active_redirect_count,
    (SELECT count(*)
     FROM impacted_candidates AS candidate
     JOIN public.active_ad_serving_assignments AS serving
       ON serving.content_id = candidate.content_id
     WHERE candidate.target_generation_id = target.generation_id)
        AS serving_row_count
FROM targets AS target
LEFT JOIN public.generation_runs AS run USING (generation_id)
ORDER BY target.generation_id;

SELECT conrelid::regclass AS relation_name, conname
FROM pg_constraint
WHERE conrelid IN (
        'public.generation_runs'::regclass,
        'public.content_candidates'::regclass,
        'generation_rag.retrieval_documents'::regclass
      )
  AND NOT convalidated
ORDER BY conrelid::regclass::TEXT, conname;
```

결과 row 수는 승인 manifest target 수와 같아야 하고 `status_contract_ok`는 모두 `true`, 모든 `*_count`는 0이어야 한다. 미검증 constraint query도 0건이어야 한다. Preflight export와 비교해 cleanup 대상 밖의 promotion scope fingerprint, fallback flag/reason/source 및 historical evaluation provenance가 그대로인지 확인하고, 정상 non-target 광고의 serving smoke test까지 통과한 뒤에만 traffic을 재개한다.

- Expand 실패: transaction rollback 후 같은 파일을 재실행한다.
- Cleanup gate/count/update 오류: transaction 전체를 `ROLLBACK`한다. Snapshot과 fingerprint가 달라졌다면 기존 manifest를 수정하지 말고 새 snapshot/export/approval로 다시 시작한다.
- Cleanup `COMMIT` 후: 해당 run을 `completed`로 되돌리거나 legacy allowlist를 추가하거나 strict view를 완화하지 않는다. 재생성이 필요하면 새 ID의 v1 요청을 만든다.
- Backfill/finalize 실패: 각 migration transaction의 rollback을 확인하고, cleanup으로 이미 재분류된 `failed` row는 유지한다. Writer/serving/dispatch maintenance도 유지한 채 원인을 해결하고 같은 단계를 재실행한다.
- Snapshot/PITR 복원은 개별 status 재분류의 rollback 수단이 아니라 Generation v1 rollout 전체의 재해 복구 절차다. Cleanup 이후 write가 없는지 확인하고 별도 복구 승인을 받은 경우에만 수행한다.

### Commit 누락 방지 체크리스트

Generation v1 변경 commit에는 다음 8개 파일이 모두 포함되어야 한다.

```text
README.md
postgres/schema.sql
postgres/dummy.sql
postgres/expand_generation_v1.sql
postgres/backfill_generation_v1.sql
postgres/finalize_generation_v1.sql
postgres/tests/verify_generation_v1.sql
scripts/verify_postgres_contract.sh
```

커밋 준비 전에 파일 존재 여부와 working tree를 확인한다.

```bash
for file in \
  README.md \
  postgres/schema.sql \
  postgres/dummy.sql \
  postgres/expand_generation_v1.sql \
  postgres/backfill_generation_v1.sql \
  postgres/finalize_generation_v1.sql \
  postgres/tests/verify_generation_v1.sql \
  scripts/verify_postgres_contract.sh; do
  test -f "$file" || exit 1
done

git status --short
./scripts/verify_postgres_contract.sh
```

실제 commit을 만드는 사람이 staging한 뒤에는 `git diff --cached --name-only` 결과를 위 목록과 대조하고, 신규 SQL이 `??`로 남아 있지 않은지 확인한다. 이 runbook 작성 작업에서는 로컬 전용 요청에 따라 staging, commit, push를 수행하지 않는다.

## Docker Compose

로컬 DB를 올릴 때는 Compose에 local env 파일을 넘깁니다.

```bash
docker compose --env-file environments/local.env up -d
```

기본 Compose는 schema만 실행하며 dummy를 자동 적재하지 않습니다. Local fixture Compose는 PostgreSQL·ClickHouse schema 다음에 각각의 dummy를 실행합니다.

```bash
docker compose \
  --env-file environments/dashboard.env \
  -f docker-compose.yml \
  -f docker-compose.local-fixture.yml \
  down -v
```

위 명령은 local fixture 프로젝트의 PostgreSQL·ClickHouse 볼륨만 삭제합니다. fixture는 manual next-loop와 ClickHouse funnel/booking을 확인하는 로컬 전용 데이터입니다.

## Expedia train.csv 적재

Kaggle Expedia `train.csv`는 repo에 커밋하지 않고 로컬 파일로만 둡니다. 기본 위치는 `clickhouse/train.csv`입니다.

로컬 DB를 띄운 뒤 아래 스크립트를 실행하면 `train.csv`를 `expedia_hotel_events`에 적재하고, 기본값으로 `user_behavior_vectors`까지 생성합니다.

```bash
docker compose --env-file environments/local.env up -d
bash clickhouse/load_train_csv.sh
```

다른 위치의 CSV를 쓰려면 `TRAIN_CSV`를 넘깁니다.

```bash
TRAIN_CSV=/path/to/train.csv bash clickhouse/load_train_csv.sh
```

벡터 생성을 건너뛰고 CSV 적재만 하려면 다음처럼 실행합니다.

```bash
BUILD_USER_BEHAVIOR_VECTORS=0 bash clickhouse/load_train_csv.sh
```

## ClickHouse SQL

- [clickhouse/drop.sql](clickhouse/drop.sql): dev ClickHouse를 깨끗하게 다시 만들 때 `loopad` database와 Kafka named collection을 제거합니다.
- [clickhouse/database.sql](clickhouse/database.sql): ClickHouse `loopad` database를 생성합니다.
- [clickhouse/named-collection.example.sql](clickhouse/named-collection.example.sql): `loopad_events_kafka` named collection 생성 예시입니다.
- [clickhouse/schema.sql](clickhouse/schema.sql): `hotel_rec_promo.v1` 원천 이벤트 테이블과 호텔 프로모션 분석 view/materialized view를 생성합니다.
- [clickhouse/build_user_behavior_vectors_from_expedia.sql](clickhouse/build_user_behavior_vectors_from_expedia.sql): `expedia_hotel_events`에서 64차원 `user_behavior_vectors`를 생성합니다.
- [clickhouse/load_train_csv.sh](clickhouse/load_train_csv.sh): 로컬 `train.csv`를 ClickHouse에 적재하고 벡터 생성 SQL을 실행합니다.

스키마 변경 후 깨끗한 로컬 DB가 필요하면 Docker volume을 지운 뒤 다시 올립니다.

```bash
docker compose --env-file environments/local.env down -v
docker compose --env-file environments/local.env up -d
```

## 원칙

- 이 repo에는 schema contract와 로컬 실행 설정만 둡니다.
- 운영 seed와 backfill은 repo 공통 계약에 포함하지 않습니다.
- `postgres/dummy.sql`과 local fixture Compose는 Dashboard를 포함한 서비스의 로컬 계약 테스트 전용입니다.
- 추가 데이터 소스나 운영용 seed가 필요해지면 별도 합의 후 파일을 추가합니다.
