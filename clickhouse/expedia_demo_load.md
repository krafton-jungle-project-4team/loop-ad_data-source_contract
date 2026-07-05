# Expedia Demo Load

이 문서는 Kaggle Expedia Hotel Recommendations `train.csv`를 로컬 ClickHouse에 적재하고, Decision 분석용 `user_behavior_vectors`를 생성하는 절차를 설명합니다.

Kaggle 원본 CSV는 크고 별도 라이선스가 있으므로 이 repository에 커밋하지 않습니다. 로컬 파일을 직접 적재한 뒤, 이 repo의 SQL만 실행합니다.

## 전제

1. Docker Compose로 local DB가 떠 있어야 합니다.
2. `clickhouse/schema.sql`이 적용되어 있어야 합니다.
3. ClickHouse `loopad.expedia_hotel_events` 테이블이 있어야 합니다.
4. Kaggle `train.csv`가 로컬에 있어야 합니다.

예시 로컬 경로:

```text
~/Downloads/expedia-hotel-recommendations/train.csv
```

## DB 실행

```bash
docker compose --env-file environments/local.env up -d
```

깨끗한 DB에서 처음부터 다시 확인하려면 기존 local volume을 삭제한 뒤 올립니다.

```bash
docker compose --env-file environments/local.env down -v
docker compose --env-file environments/local.env up -d
```

## train.csv 적재

`environments/local.env` 기준 local ClickHouse 접속값은 다음과 같습니다.

```text
host: localhost
native port: 19000
database: loopad
user: loopad_app
password: loopad_local_password
```

로컬에 `clickhouse-client`가 설치되어 있으면 아래 명령으로 적재합니다.

```bash
clickhouse-client \
  --host localhost \
  --port 19000 \
  --user loopad_app \
  --password loopad_local_password \
  --database loopad \
  --input_format_with_names_use_header 1 \
  --input_format_csv_empty_as_default 1 \
  --query "INSERT INTO expedia_hotel_events FORMAT CSVWithNames" \
  < ~/Downloads/expedia-hotel-recommendations/train.csv
```

로컬에 `clickhouse-client`가 없다면 Compose의 ClickHouse 컨테이너 안에 있는 client를 사용할 수 있습니다.

```bash
docker compose --env-file environments/local.env exec -T clickhouse \
  clickhouse-client \
  --user loopad_app \
  --password loopad_local_password \
  --database loopad \
  --input_format_with_names_use_header 1 \
  --input_format_csv_empty_as_default 1 \
  --query "INSERT INTO expedia_hotel_events FORMAT CSVWithNames" \
  < ~/Downloads/expedia-hotel-recommendations/train.csv
```

## 적재 확인

```bash
clickhouse-client \
  --host localhost \
  --port 19000 \
  --user loopad_app \
  --password loopad_local_password \
  --database loopad \
  --query "SELECT count() AS events, uniqExact(user_id) AS users FROM expedia_hotel_events"
```

컨테이너 client를 사용할 때는 다음과 같이 확인합니다.

```bash
docker compose --env-file environments/local.env exec -T clickhouse \
  clickhouse-client \
  --user loopad_app \
  --password loopad_local_password \
  --database loopad \
  --query "SELECT count() AS events, uniqExact(user_id) AS users FROM expedia_hotel_events"
```

## user_behavior_vectors 생성

`train.csv` 적재 후 아래 SQL을 실행합니다.

```bash
clickhouse-client \
  --host localhost \
  --port 19000 \
  --user loopad_app \
  --password loopad_local_password \
  --database loopad \
  --multiquery \
  --queries-file clickhouse/build_user_behavior_vectors_from_expedia.sql
```

컨테이너 client를 사용할 때는 SQL 파일을 표준 입력으로 전달합니다.

```bash
docker compose --env-file environments/local.env exec -T clickhouse \
  clickhouse-client \
  --user loopad_app \
  --password loopad_local_password \
  --database loopad \
  --multiquery \
  < clickhouse/build_user_behavior_vectors_from_expedia.sql
```

생성 SQL은 다음 계약을 따릅니다.

```text
project_id = demo_project
user_id = toString(expedia_hotel_events.user_id)
vector_dim = 64
vector_values = Array(Float32), length 64
vector_version = v1
source = batch_profile
window_start = 해당 user_id의 min(date_time)
window_end = 해당 user_id의 max(date_time)
```

`project_id`는 PostgreSQL demo seed의 `projects.project_id`와 같은 `demo_project`로 고정합니다.

## 벡터 생성 확인

```bash
clickhouse-client \
  --host localhost \
  --port 19000 \
  --user loopad_app \
  --password loopad_local_password \
  --database loopad \
  --query "SELECT count() AS vector_count, uniqExact(user_id) AS user_count, min(length(vector_values)) AS min_vector_length, max(length(vector_values)) AS max_vector_length FROM user_behavior_vectors WHERE project_id = 'demo_project' AND vector_version = 'v1'"
```

기대값:

```text
min_vector_length = 64
max_vector_length = 64
```

## 사용하지 않는 Kaggle 파일

이번 demo flow의 필수 입력은 `train.csv`입니다.

- `test.csv`: Kaggle 제출용 평가 데이터이며 `hotel_cluster`, `is_booking` 정답이 없습니다.
- `sample_submission.csv`: Kaggle 제출 형식 예시입니다.
- `destinations.csv`: `srch_destination_id`별 149차원 feature이며, 후속 vector 고도화에서 선택적으로 사용할 수 있습니다.
