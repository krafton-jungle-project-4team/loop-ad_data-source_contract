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

Dashboard에서 manual next-loop를 확인하려면 기본 Compose와 분리된 local fixture 환경을 사용합니다. 기본 PostgreSQL과 동시에 실행할 수 있도록 fixture PostgreSQL 포트는 `15433`을 사용합니다.

```bash
docker compose \
  --env-file environments/dashboard.env \
  -f docker-compose.yml \
  -f docker-compose.local-fixture.yml \
  up -d postgres
```

기본 Compose는 PostgreSQL 16.13 Alpine 이미지를 사용합니다. Local fixture는 PostgreSQL 16 계열과 pgvector 0.8.0이 포함된 `pgvector/pgvector:0.8.0-pg16` 이미지를 선택적으로 사용합니다. 따라서 fixture 이미지의 PostgreSQL patch version을 16.13으로 간주하지 않습니다.

## 현재 계약 요약

PostgreSQL은 `Campaign -> Promotion -> Segment -> Ad Experiment` 실행 상태를 저장하며, ANN segment matching을 위해 `pgvector` extension을 사용합니다. 핵심 테이블은 `campaigns`, `promotions`, `promotion_analyses`, `promotion_target_segments`, `generation_runs`, `content_candidates`, `promotion_runs`, `ad_experiments`, `promotion_evaluations`, `next_loop_preparations`, `user_segment_assignments`, `segment_query_previews`, `segment_definitions`입니다.

Manual next-loop는 `next_loop_preparations`에 source run별 승인 attempt와 activation 결과를 저장합니다. Child `ad_experiments`는 nullable `parent_ad_experiment_id`, `source_evaluation_id`로 lineage를 남기며, 기존 A1과 legacy row는 두 값을 모두 `NULL`로 유지합니다. 두 lineage 값이 같은 segment와 promotion을 가리키는지, source evaluation이 parent의 올바른 평가인지 확인하는 책임은 Decision activation transaction에 있습니다.

`active_ad_serving_assignments`는 실행 상태인 `approved`, `running`과 함께 legacy evaluation-result 상태인 `goal_met`, `goal_not_met`, `insufficient_data`를 호환합니다. Legacy row는 종료되지 않았고 현재 experiment status와 일치하는 historical individual `promotion_evaluations` row가 실제로 존재할 때만 serving 대상입니다. 최신 evaluation 결과는 Dashboard 표시와 next-loop 판단에 사용하며, 재평가 결과가 legacy experiment status와 달라져도 serving 여부를 바꾸지 않습니다. Provenance가 없는 assignment-origin `insufficient_data`는 serving 대상이 아닙니다.

이 repo의 schema 변경 merge는 기존 dev 또는 운영 DB에 DDL을 적용하지 않습니다. Dashboard/Decision의 manual cutover, 기존 데이터 audit, 별도 DB 운영 검증이 완료된 뒤 DB/Infra owner가 실제 환경에 적용해야 하며, 이 repo에는 migration history를 추가하지 않습니다.

Dashboard의 SDK Tracking Plan은 기존 `projects.write_key`를 공개 connection ID 겸 write key로 사용합니다. `tracking_plans`와 `tracking_plan_events`가 편집 가능한 draft를, `tracking_plan_revisions`가 게시 시점의 immutable JSON snapshot을, `project_sdk_settings`가 허용 Origin과 활성 게시 revision을 보관합니다. 게시 처리는 애플리케이션에서 revision insert와 활성 revision 변경을 같은 transaction으로 실행해야 합니다.

ClickHouse는 `raw_events`를 원천으로 두고 `promotion_touch_events`, `booking_outcome_events`, `hotel_detail_events`, `funnel_step_events`, `hotel_marketing_profiles`, `user_behavior_vectors`를 제공합니다. 이벤트 이름은 호텔 예약 도메인 기준의 `hotel_search`, `hotel_click`, `hotel_detail_view`, `booking_start`, `booking_complete`, `booking_cancel`, `promotion_impression`, `promotion_click`, `campaign_redirect_click`, `campaign_landing`을 사용합니다.

## Docker Compose

로컬 DB를 올릴 때는 Compose에 local env 파일을 넘깁니다.

```bash
docker compose --env-file environments/local.env up -d
```

기본 Compose에서는 PostgreSQL의 `postgres/schema.sql`, ClickHouse의 `clickhouse/schema.sql`을 컨테이너 최초 초기화 시점에 실행합니다. 기본 Compose는 운영·공용 계약용 환경이므로 dummy 데이터를 자동 적재하지 않습니다.

Local fixture Compose에서는 `postgres/schema.sql` 다음에 `postgres/dummy.sql`을 실행합니다. fixture 데이터는 새 local fixture 볼륨을 최초 초기화할 때만 적재되며, 이미 사용 중인 볼륨을 다시 시작한다고 데이터가 덮어써지지 않습니다.

Fixture 데이터를 초기화하려면 반드시 local fixture 설정을 함께 지정합니다.

```bash
docker compose \
  --env-file environments/dashboard.env \
  -f docker-compose.yml \
  -f docker-compose.local-fixture.yml \
  down -v
```

위 명령은 `loop-ad_data-source_contract-local-fixture` 프로젝트의 컨테이너와 볼륨만 삭제합니다. 기본 Compose의 `15432` PostgreSQL 데이터와는 별개입니다.

Local fixture에는 다음 Dashboard 확인 시나리오가 포함됩니다.

| 시나리오 | 확인할 내용 |
|---|---|
| Email reactivation | A2 승인 대기 중 A1 serving 유지, generation별 후보 조회 |
| Onsite last-minute | A1 종료 후 parent/source lineage가 있는 A2만 serving |
| SMS near check-in | preparation 거절 유지, provenance 없는 `insufficient_data` 제외 |

Fixture의 evaluation row는 최신 individual evaluation을 결정적으로 선택할 수 있는 데이터를 제공합니다. 실제 `ORDER BY created_at DESC, evaluation_id DESC` 사용 여부는 Dashboard 저장소 테스트 책임입니다.

### Dashboard 담당자용 실행 순서

1. `environments/dashboard.env`의 PostgreSQL URL을 사용해 Dashboard를 `localhost:15433`에 연결합니다.
2. 위의 local fixture `up -d postgres` 명령으로 DB를 실행합니다.
3. 아래 테스트 사용자를 순서대로 조회합니다.

| 테스트 사용자 | 기대 결과 |
|---|---|
| `demo_user_email_awaiting` | `exp_email_a1_mobile`만 조회되고, A2 후보는 승인 대기 상태 |
| `demo_user_onsite_cutover` | A1은 보이지 않고 `exp_onsite_a2_near`만 조회 |
| `demo_user_sms_rejected` | 거절된 preparation과 A1 serving 확인 |
| `demo_user_sms_no_provenance` | serving 결과 없음. 평가 provenance 없는 `insufficient_data` 사례 |

4. preparation 화면에서는 다음 ID를 사용합니다.

| preparation | 상태 | 용도 |
|---|---|---|
| `prep_email_next_loop_01` | `awaiting_content_approval` | generation별 후보 승인 화면 |
| `prep_onsite_next_loop_01` | `activated` | A1→A2 전환 결과 화면 |
| `prep_sms_next_loop_01` | `rejected` | 거절 및 A1 유지 화면 |

5. fixture를 다시 처음 상태로 만들 때만 다음 초기화 명령을 실행합니다.

```bash
docker compose \
  --env-file environments/dashboard.env \
  -f docker-compose.yml \
  -f docker-compose.local-fixture.yml \
  down -v
```

이 명령은 Dashboard local fixture 데이터만 삭제합니다. 기본 Compose의 PostgreSQL `15432` 데이터는 삭제하지 않습니다.

## 실제 DB 적용 전 확인 사항

아래 항목은 Contract PR merge 조건이 아닙니다. 실제 dev DB에 DDL을 적용하고 manual next-loop 기능을 켜기 전에 Dashboard·Decision·DB/Infra 담당자가 함께 확인해야 합니다.

- [ ] **[Dashboard] 후보를 같은 generation에서만 승인**
  - preparation의 `generation_id`와 후보의 `generation_id`가 같은지 확인합니다.
  - 다른 generation의 후보를 섞은 승인 요청은 거절되어야 합니다.

- [ ] **[Dashboard] preparation ID로 요청·새로고침·재시도**
  - 활성화 요청에 `next_loop_preparation_id`를 보냅니다.
  - 응답이 끊겨 재시도할 때 새 preparation이나 A2를 만들지 않고 같은 ID로 다시 조회합니다.

- [ ] **[Dashboard] 최신 개별 평가를 항상 같은 방식으로 조회**
  - aggregate 평가(`ad_experiment_id IS NULL`)는 제외합니다.
  - `ORDER BY created_at DESC, evaluation_id DESC`로 최신 row를 선택합니다.
  - 최신 평가 status와 experiment status가 달라도 화면에 표시할 수 있어야 합니다.

- [ ] **[Decision] preparation과 A1→A2 관계 저장**
  - preparation row가 저장되어야 합니다.
  - A2의 `parent_ad_experiment_id`, `source_evaluation_id`가 함께 저장되어야 합니다.
  - Dashboard는 응답과 재조회에서 이 ID들을 잃지 않아야 합니다.

- [ ] **[공동] A2 준비·A1 종료·preparation 활성화를 한 번에 처리**
  - 성공하면 A1은 종료되고 A2만 serving되어야 합니다.
  - 실패하면 A2 변경은 모두 취소되고 A1만 계속 serving되어야 합니다.

- [ ] **[Decision/DB] 기존 evaluation·assignment 데이터 출처 점검**
  - 기존 `insufficient_data`가 실제 개별 평가에서 나온 것인지 확인합니다.
  - 평가 기록이 없는 assignment-origin row가 새 view에 노출되지 않아야 합니다.

- [ ] **[DB/Dashboard] 실제 dev 데이터 크기로 조회 성능 확인**
  - Dashboard serving 조회에 `EXPLAIN (ANALYZE, BUFFERS)`를 실행합니다.
  - evaluation 전체 scan이나 assignment 수에 따른 비정상 반복 조회가 없어야 합니다.

- [ ] **[공동] A1과 A2가 동시에 serving되지 않는지 확인**
  - A2 준비 전에는 A1만 조회됩니다.
  - 활성화 성공 후에는 A2만 조회됩니다.
  - 활성화 실패·재시도·동시 요청에서도 A1/A2 중복과 child 중복이 없어야 합니다.

- [ ] **[DB/Infra] 운영 DDL 적용 순서와 책임 확인**
  - DB/Infra owner가 별도 운영 DDL을 리뷰하고 dev DB에 적용합니다.
  - 이 Contract repo의 merge나 git revert만으로 운영 DB가 변경·복구된다고 가정하지 않습니다.

모든 항목이 확인되기 전까지 manual next-loop 기능은 OFF로 유지합니다.

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
