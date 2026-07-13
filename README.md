# loop-ad_data-source_contract

LoopAd의 로컬 데이터 소스 계약을 공유하는 최소 repo입니다.

이 repo는 운영 migration history를 관리하지 않습니다. 현재 기준 파일은 호텔 예약 프로모션 도메인의 PostgreSQL 운영 스키마와 ClickHouse `hotel_rec_promo.v1` 분석 스키마입니다.

## 구조

```text
.
├── clickhouse/
│   ├── build_user_behavior_vectors_from_expedia.sql
│   ├── database.sql
│   ├── drop.sql
│   ├── load_train_csv.sh
│   ├── named-collection.example.sql
│   └── schema.sql
├── postgres/
│   ├── dummy.sql
│   ├── expand_promotion_run_segment_scope.sql
│   ├── backfill_promotion_run_segment_scope.sql
│   ├── finalize_promotion_run_segment_scope.sql
│   ├── tests/
│   │   ├── repair_legacy_fixture_fallbacks.sql
│   │   └── verify_promotion_run_segment_scope.sql
│   └── schema.sql
├── scripts/
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

## 현재 계약 요약

PostgreSQL은 `Campaign -> Promotion -> Segment -> Ad Experiment` 실행 상태를 저장하며, ANN segment matching을 위해 `pgvector` extension을 사용합니다. 핵심 테이블은 `campaigns`, `promotions`, `promotion_analyses`, `promotion_target_segments`, `generation_runs`, `content_candidates`, `promotion_runs`, `ad_experiments`, `promotion_evaluations`, `next_loop_preparations`, `user_segment_assignments`, `segment_query_previews`, `segment_definitions`입니다.

Manual next-loop 관련 preparation·child lineage·legacy serving provenance 계약은 `postgres/schema.sql`에 정의합니다. 실제 dev/운영 DB 적용은 별도 운영 절차로 수행하며 migration history는 관리하지 않습니다.

Promotion run의 full composite identity는 `project_id + promotion_id + analysis_id + generation_id + segment_scope_fingerprint + loop_count`입니다. `segment_scope_fingerprint`는 fallback `seg_existing_all`을 제외하고 C collation으로 정렬·중복 제거한 segment ID 배열의 compact JSON SHA-256입니다. 따라서 다른 `analysis_id` 또는 `generation_id`는 같은 promotion·loop·scope라도 별도 실행 identity입니다. Dashboard 문서에서 쓰는 `promotion_id + loop_count + segment_scope_fingerprint`는 조회 맥락을 설명하는 축약 표현이며 실제 unique key를 뜻하지 않습니다.

Dashboard의 SDK Tracking Plan은 기존 `projects.write_key`를 공개 connection ID 겸 write key로 사용합니다. `tracking_plans`와 `tracking_plan_events`가 편집 가능한 draft를, `tracking_plan_revisions`가 게시 시점의 immutable JSON snapshot을, `project_sdk_settings`가 허용 Origin과 활성 게시 revision을 보관합니다. 게시 처리는 애플리케이션에서 revision insert와 활성 revision 변경을 같은 transaction으로 실행해야 합니다.

ClickHouse는 `raw_events`를 원천으로 두고 `promotion_touch_events`, `booking_outcome_events`, `hotel_detail_events`, `funnel_step_events`, `hotel_marketing_profiles`, `user_behavior_vectors`를 제공합니다. 이벤트 이름은 호텔 예약 도메인 기준의 `hotel_search`, `hotel_click`, `hotel_detail_view`, `booking_start`, `booking_complete`, `booking_cancel`, `promotion_impression`, `promotion_click`, `campaign_redirect_click`, `campaign_landing`을 사용합니다.

## Promotion run segment scope 전환

Decision은 `segment_ids`를 포함한 신규 run과 failed-only 자동 next-loop를 항상
처리합니다. 이 Decision 버전을 배포하기 전에 기존 DB의 segment scope
expand, backfill, finalize와 Dashboard의 scope 응답 파싱이 완료되어야 합니다.

Finalize 전에 새 Decision 버전을 배포하면 기존 `uq_promotion_runs_loop` 때문에
같은 promotion/loop의 다른 scope가 충돌할 수 있습니다. ECS task별
image/revision이 다르면 요청 결과가 task에 따라 달라질 수 있습니다. 기존 run의
scope, target experiment, fallback experiment 중 하나라도 손상됐으면 Decision의
기존 run 재사용 무결성 검사에서 409를 반환합니다. 이 응답은 데이터 무결성
오류이며 JSON 직렬화 문제로 오인하면 안 됩니다.

기존 DB에는 다음 순서를 유지합니다.

1. `expand_promotion_run_segment_scope.sql`
2. 아래 preflight 확인 후 기존 run backfill과 target/fallback 무결성 검증
3. `finalize_promotion_run_segment_scope.sql`로 composite unique 적용
4. Dashboard의 `segment_ids`와 `is_fallback` 파싱 반영
5. 모든 dev task를 같은 Decision image/revision으로 교체
6. dev smoke test
7. Dashboard/Advertisement 연동과 dispatch 재시도 확인
8. 운영 전체 task를 같은 검증 완료 revision으로 교체

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
