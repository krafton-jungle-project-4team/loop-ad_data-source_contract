# loop-ad_data-source_contract

LoopAd의 로컬 데이터 소스 계약을 공유하는 repo입니다.

이 repo는 운영 migration history를 관리하지 않습니다. 현재 기준 파일은 PostgreSQL schema/demo seed와 ClickHouse schema/Kafka ingest 계약입니다.

## 구조

```text
.
├── clickhouse/
│   └── schema.sql
├── kafka/
│   └── server.properties
├── postgres/
│   ├── schema.sql
│   └── dummy.sql
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
| Kafka bootstrap | `localhost:9094` |

앱 repo에서 사용할 수 있는 추천 환경변수:

```bash
LOOPAD_POSTGRES_URL=postgresql://loopad:loopad@localhost:15432/loopad
LOOPAD_CLICKHOUSE_URL=http://localhost:18123
LOOPAD_CLICKHOUSE_USERNAME=loopad_app
LOOPAD_CLICKHOUSE_PASSWORD=loopad_local_password
LOOPAD_KAFKA_BOOTSTRAP_BROKERS=localhost:9094
LOOPAD_KAFKA_SECURITY_PROTOCOL=SASL_PLAINTEXT
LOOPAD_KAFKA_SASL_MECHANISM=SCRAM-SHA-512
LOOPAD_KAFKA_USERNAME=event-collector
LOOPAD_KAFKA_PASSWORD=event-collector-local-password
LOOPAD_EVENT_TOPIC=loop-ad.events.raw
```

`loopad`, `loopad_local_password`는 로컬 개발용 값입니다. 운영 secret이나 실제 password를 이 repo에 넣지 않습니다.

## Kafka to ClickHouse

ClickHouse schema는 Event Collector가 Kafka topic `loop-ad.events.raw`에 넣는
SDK payload 원문 JSON을 직접 pull합니다.

Kafka message 계약:

- `key`: 사용하지 않습니다.
- `value`: SDK flat payload JSON입니다.
- `event_time`: SDK가 보낸 시간 문자열을 그대로 저장합니다.
- `properties_json`: JSON object를 stringify한 string입니다.

ClickHouse ingest 구조:

- `events_raw_kafka`: Kafka Engine source table입니다. `events`와 같은 이벤트 컬럼
  타입을 사용하지만 데이터를 저장하지 않습니다.
- `events_raw_kafka_to_events`: `events_raw_kafka`에서 읽은 JSON을 `events`에
  전달하는 materialized view입니다.
- `events`: 행동 로그와 reward 계산의 원천 테이블입니다.

Kafka Engine table은 ClickHouse 저장 테이블이 아니므로 ClickHouse TTL로 지워지는
대상이 아닙니다. Kafka 메시지 보존/삭제는 Kafka topic retention이 담당하고,
`events`에 적재된 데이터는 `events` 테이블에 TTL을 별도로 정의하지 않는 한
ClickHouse에 계속 남습니다.

로컬 Event Collector는 `localhost:9094`의 SASL_PLAINTEXT listener에 붙고,
ClickHouse 컨테이너는 compose 내부 broker인 `kafka:9092`에서 같은 topic을
읽습니다. topic은 `loop-ad.events.raw`, ClickHouse consumer group은
`loop-ad-clickhouse-events-local`입니다. Kafka 위치나 topic을 바꿔야 하면
`clickhouse/schema.sql`의 `events_raw_kafka` 설정을 함께 바꿉니다.

## Docker Compose

로컬 DB를 올릴 때는 Compose에 local env 파일을 넘깁니다.

```bash
docker compose --env-file environments/local.env up -d
```

Compose는 Kafka, PostgreSQL, ClickHouse를 함께 올립니다. PostgreSQL은
컨테이너 최초 초기화 시점에 `postgres/schema.sql` 이후 `postgres/dummy.sql`을
실행합니다. ClickHouse는 `clickhouse/schema.sql`을 실행하며 `events` 테이블,
Kafka source table, materialized view를 함께 생성합니다.

스키마 변경 후 깨끗한 로컬 DB가 필요하면 Docker volume을 지운 뒤 다시 올립니다.

```bash
docker compose --env-file environments/local.env down -v
docker compose --env-file environments/local.env up -d
```

## 원칙

- 이 repo에는 schema/Kafka ingest contract, 로컬 실행 설정, 로컬 demo seed만 둡니다.
- shell script나 팀원별 자동화는 repo 공통 계약에 포함하지 않습니다.
- 추가 데이터 소스나 seed가 필요해지면 별도 합의 후 파일을 추가합니다.
