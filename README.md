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
│   ├── expedia_demo_load.md
│   ├── named-collection.example.sql
│   └── schema.sql
├── postgres/
│   ├── demo_seed.sql
│   └── schema.sql
├── environments/
│   └── local.env
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

## 현재 계약 요약

PostgreSQL은 `Campaign -> Promotion -> Segment -> Ad Experiment` 실행 상태를 저장합니다. 핵심 테이블은 `campaigns`, `promotions`, `promotion_analyses`, `promotion_target_segments`, `generation_runs`, `content_candidates`, `promotion_runs`, `ad_experiments`, `promotion_evaluations`, `user_segment_assignments`, `segment_query_previews`, `segment_definitions`입니다.

ClickHouse는 `raw_events`를 원천으로 두고 `promotion_touch_events`, `booking_outcome_events`, `hotel_detail_events`, `funnel_step_events`, `hotel_marketing_profiles`, `user_behavior_vectors`를 제공합니다. 이벤트 이름은 호텔 예약 도메인 기준의 `hotel_search`, `hotel_click`, `hotel_detail_view`, `booking_start`, `booking_complete`, `booking_cancel`, `promotion_impression`, `promotion_click`, `campaign_redirect_click`, `campaign_landing`을 사용합니다.

## Docker Compose

로컬 DB를 올릴 때는 Compose에 local env 파일을 넘깁니다.

```bash
docker compose --env-file environments/local.env up -d
```

PostgreSQL은 `postgres/schema.sql`, ClickHouse는 `clickhouse/schema.sql`을 컨테이너 최초 초기화 시점에 실행합니다.

## Expedia demo data flow

Loop-Ad 전체 데모는 서비스 운영 객체와 사용자 행동 데이터를 분리해서 준비합니다.

```text
PostgreSQL demo seed
-> demo_project / campaign / promotions / system_default segments

Kaggle train.csv
-> ClickHouse expedia_hotel_events
-> ClickHouse user_behavior_vectors
-> Decision analysis API
-> PostgreSQL promotion_segment_suggestions
```

PostgreSQL demo seed는 Decision 분석 API가 조회할 최소 업무 계층만 만듭니다.

```text
projects
-> campaigns
-> promotions
-> segment_definitions
```

`promotion_analyses`, `promotion_segment_suggestions`, `promotion_target_segments`, `generation_runs`, `promotion_runs`, `ad_experiments`, `user_segment_assignments` 같은 실행 결과 row는 seed하지 않습니다. 이 row들은 각 서비스 API가 실제 실행되면서 생성합니다.

### 실행 순서

1. 로컬 DB를 실행합니다.

```bash
docker compose --env-file environments/local.env up -d
```

깨끗한 DB에서 스키마부터 다시 확인하려면 volume을 삭제하고 올립니다.

```bash
docker compose --env-file environments/local.env down -v
docker compose --env-file environments/local.env up -d
```

2. PostgreSQL demo seed를 실행합니다.

```bash
docker compose --env-file environments/local.env exec -T postgres \
  psql -U loopad -d loopad \
  < postgres/demo_seed.sql
```

3. Kaggle Expedia `train.csv`를 ClickHouse `expedia_hotel_events`에 적재합니다.

자세한 명령은 [clickhouse/expedia_demo_load.md](clickhouse/expedia_demo_load.md)를 따릅니다. 기본 로컬 경로 예시는 다음과 같습니다.

```text
~/Downloads/expedia-hotel-recommendations/train.csv
```

4. `expedia_hotel_events`에서 Decision 군집화용 `user_behavior_vectors`를 생성합니다.

```bash
docker compose --env-file environments/local.env exec -T clickhouse \
  clickhouse-client \
  --user loopad_app \
  --password loopad_local_password \
  --database loopad \
  --multiquery \
  < clickhouse/build_user_behavior_vectors_from_expedia.sql
```

5. Decision API를 호출합니다.

```http
POST /decision/v1/promotions/promo_expedia_email_reactivation/analysis
```

예시 body:

```json
{
  "project_id": "demo_project",
  "campaign_id": "camp_expedia_hotel_demo",
  "promotion_id": "promo_expedia_email_reactivation"
}
```

6. 분석 완료 후 PostgreSQL `promotion_segment_suggestions`에서 추천 세그먼트 후보를 확인합니다.

### Kaggle 파일 사용 범위

이번 데모의 필수 입력은 `train.csv`입니다. `train.csv`에는 `is_booking`과 `hotel_cluster`가 포함되어 있어 예약 성향 집계와 사용자 행동 벡터 생성을 위한 입력으로 사용할 수 있습니다.

`test.csv`와 `sample_submission.csv`는 Kaggle 제출용이라 이번 demo flow에서는 사용하지 않습니다. `destinations.csv`는 `srch_destination_id`별 149차원 feature를 담고 있어 destination feature 고도화 때 후속으로 사용할 수 있습니다.

Kaggle 원본 CSV는 이 repo에 커밋하지 않습니다.

## ClickHouse SQL

- [clickhouse/drop.sql](clickhouse/drop.sql): dev ClickHouse를 깨끗하게 다시 만들 때 `loopad` database와 Kafka named collection을 제거합니다.
- [clickhouse/database.sql](clickhouse/database.sql): ClickHouse `loopad` database를 생성합니다.
- [clickhouse/named-collection.example.sql](clickhouse/named-collection.example.sql): `loopad_events_kafka` named collection 생성 예시입니다.
- [clickhouse/schema.sql](clickhouse/schema.sql): `hotel_rec_promo.v1` 원천 이벤트 테이블과 호텔 프로모션 분석 view/materialized view를 생성합니다.
- [clickhouse/expedia_demo_load.md](clickhouse/expedia_demo_load.md): Kaggle Expedia `train.csv`를 로컬 ClickHouse에 적재하고 벡터 생성 SQL을 실행하는 절차입니다.
- [clickhouse/build_user_behavior_vectors_from_expedia.sql](clickhouse/build_user_behavior_vectors_from_expedia.sql): `expedia_hotel_events`에서 64차원 `user_behavior_vectors`를 생성합니다.

스키마 변경 후 깨끗한 로컬 DB가 필요하면 Docker volume을 지운 뒤 다시 올립니다.

```bash
docker compose --env-file environments/local.env down -v
docker compose --env-file environments/local.env up -d
```

## 원칙

- 이 repo에는 schema contract와 로컬 실행 설정만 둡니다.
- shell script, dummy data, 팀원별 자동화는 repo 공통 계약에 포함하지 않습니다.
- 추가 데이터 소스나 seed가 필요해지면 별도 합의 후 파일을 추가합니다.
