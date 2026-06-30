# loop-ad_data-source_contract

LoopAd의 로컬 데이터 소스 계약을 공유하는 최소 repo입니다.

이 repo는 운영 migration history나 seed data를 관리하지 않습니다. 현재 기준 파일은 PostgreSQL과 ClickHouse의 schema뿐입니다.

## 구조

```text
.
├── clickhouse/
│   └── schema.sql
├── postgres/
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
LOOPAD_CLICKHOUSE_USERNAME=loopad_app
LOOPAD_CLICKHOUSE_PASSWORD=loopad_local_password
```

`loopad`, `loopad_local_password`는 로컬 개발용 값입니다. 운영 secret이나 실제 password를 이 repo에 넣지 않습니다.

## Docker Compose

로컬 DB를 올릴 때는 Compose에 local env 파일을 넘깁니다.

```bash
docker compose --env-file environments/local.env up -d
```

PostgreSQL은 `postgres/schema.sql`, ClickHouse는 `clickhouse/schema.sql`을 컨테이너 최초 초기화 시점에 실행합니다.

스키마 변경 후 깨끗한 로컬 DB가 필요하면 Docker volume을 지운 뒤 다시 올립니다.

```bash
docker compose --env-file environments/local.env down -v
docker compose --env-file environments/local.env up -d
```

## 원칙

- 이 repo에는 schema contract와 로컬 실행 설정만 둡니다.
- shell script, dummy data, 팀원별 자동화는 repo 공통 계약에 포함하지 않습니다.
- 추가 데이터 소스나 seed가 필요해지면 별도 합의 후 파일을 추가합니다.
- 광고 serving 앱은 `active_ad_serving_rules` view를 읽습니다. 이 view는 렌더링 필드와 함께 ClickHouse 추적용 `mapping_id`, `action_id`, `experiment_id`, `experiment_variant_id`, `generated_content_id`를 제공합니다.
