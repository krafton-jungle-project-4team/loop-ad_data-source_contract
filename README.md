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
│   └── schema.sql
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

Promotion run은 `project_id + promotion_id + analysis_id + generation_id + normalized segment_ids + loop_count` 범위로 유일합니다. 기존 DB는 `expand → Decision dual-write(flag OFF) → backfill → finalize → Dashboard scope reader → flag ON` 순서로 전환합니다. 세부 검증과 재실행 절차는 `postgres/*_promotion_run_segment_scope.sql`을 따릅니다.

Dashboard의 SDK Tracking Plan은 기존 `projects.write_key`를 공개 connection ID 겸 write key로 사용합니다. `tracking_plans`와 `tracking_plan_events`가 편집 가능한 draft를, `tracking_plan_revisions`가 게시 시점의 immutable JSON snapshot을, `project_sdk_settings`가 허용 Origin과 활성 게시 revision을 보관합니다. 게시 처리는 애플리케이션에서 revision insert와 활성 revision 변경을 같은 transaction으로 실행해야 합니다.

ClickHouse는 `raw_events`를 원천으로 두고 `promotion_touch_events`, `booking_outcome_events`, `hotel_detail_events`, `funnel_step_events`, `hotel_marketing_profiles`, `user_behavior_vectors`를 제공합니다. 이벤트 이름은 호텔 예약 도메인 기준의 `hotel_search`, `hotel_click`, `hotel_detail_view`, `booking_start`, `booking_complete`, `booking_cancel`, `promotion_impression`, `promotion_click`, `campaign_redirect_click`, `campaign_landing`을 사용합니다.

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
