#!/usr/bin/env python3
"""Create a self-contained historical campaign for the LoopAd AWS dev demo."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
from dataclasses import dataclass, replace
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from typing import Any
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

import clickhouse_connect
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb


AWS_ACCOUNT_ID = "742711170910"
AWS_REGION = "ap-northeast-2"
PROJECT_ID = "demo_project"
CAMPAIGN_ID = "camp_demo_summer_peak_history"
CAMPAIGN_NAME = "여름 성수기 지역 숙박 예약 전환 캠페인"
AURORA_CLUSTER_ID = "dev-loop-ad-aurora-postgres"
CLICKHOUSE_INSTANCE_NAME = "dev-loop-ad-clickhouse"
AURORA_SECRET_NAME = "/loop-ad/dev/aurora/credentials"
CLICKHOUSE_SECRET_NAME = "/loop-ad/dev/clickhouse/credentials"
CLICKHOUSE_DATABASE = "loopad"
FIXTURE_ID = "demo_historical_campaign_funnel_v1"
FIXTURE_EVENT_PREFIX = "evt_demo_historical_campaign_v1_"
TARGET_VALUE = Decimal("0.120000")
MIN_SAMPLE_SIZE = 100
ELIGIBLE_USER_COUNT = 613
KST = ZoneInfo("Asia/Seoul")


@dataclass(frozen=True)
class Scenario:
    key: str
    promotion_id: str
    analysis_id: str
    generation_id: str
    promotion_run_id: str
    segment_id: str
    content_id: str
    content_option_id: str
    ad_experiment_id: str
    evaluation_id: str
    promotion_name: str
    segment_name: str
    natural_language_query: str
    rule_json: dict[str, Any]
    message_brief: str
    offer_type: str
    landing_url: str
    subject: str
    preheader: str
    title: str
    body: str
    cta: str
    destination: str
    hotel_id: str
    stage_counts: tuple[int, int, int, int, int]
    loop_count: int
    expected_status: str
    improvement_directions: tuple[str, ...]
    schedule_start_days_ago: int
    schedule_end_days_ago: int
    change_summary: str | None = None


BASE_SCENARIOS = (
    Scenario(
        key="busan_weekday",
        promotion_id="promo_demo_busan_weekday_stay",
        analysis_id="analysis_demo_busan_weekday_stay",
        generation_id="generation_demo_busan_weekday_stay",
        promotion_run_id="prun_demo_busan_weekday_stay_loop_1",
        segment_id="seg_demo_busan_weekday_interest",
        content_id="content_demo_busan_weekday_email",
        content_option_id="option_demo_busan_weekday_email_1",
        ad_experiment_id="adexp_demo_busan_weekday_stay",
        evaluation_id="eval_demo_busan_weekday_stay",
        promotion_name="부산 주중 2박 연박 할인",
        segment_name="부산 주중 숙박 관심 고객",
        natural_language_query=(
            "최근 부산 숙소를 탐색했고 주중 2박 이상 여행을 고려한 고객"
        ),
        rule_json={
            "type": "all",
            "conditions": [
                {"event": "hotel_search", "property": "destination", "value": "busan"},
                {"property": "stay_nights", "operator": "gte", "value": 2},
                {"property": "checkin_day_type", "operator": "eq", "value": "weekday"},
            ],
        },
        message_brief=(
            "부산 주중 숙박을 비교한 고객에게 2박 예약 시 20% 할인과 "
            "레이트 체크아웃 혜택을 안내합니다."
        ),
        offer_type="weekday_long_stay_discount",
        landing_url=(
            "https://demo-shoppingmall.dev.loop-ad.org/search?destination=busan"
            "&deal=weekday-long-stay"
        ),
        subject="부산에서 하루 더, 주중 2박은 20% 할인",
        preheader="연박 할인과 레이트 체크아웃 혜택을 확인해 보세요.",
        title="부산 주중 2박, 여유까지 챙기세요",
        body=(
            "최근 살펴본 부산 숙소를 주중 2박으로 예약하면 20% 할인과 "
            "레이트 체크아웃 혜택을 받을 수 있어요."
        ),
        cta="부산 숙소 다시 보기",
        destination="busan",
        hotel_id="busan-haeundae-ocean-011",
        stage_counts=(184, 157, 129, 71, 29),
        loop_count=1,
        expected_status="goal_met",
        improvement_directions=(
            "부산 주중 연박 고객군과 2박 할인 메시지 조합을 다음 캠페인에도 유지",
            "예약 완료 고객의 재방문 시점을 확인해 후속 지역 추천에 활용",
        ),
        schedule_start_days_ago=115,
        schedule_end_days_ago=100,
    ),
    Scenario(
        key="gangneung_family",
        promotion_id="promo_demo_gangneung_family_breakfast",
        analysis_id="analysis_demo_gangneung_family_breakfast",
        generation_id="generation_demo_gangneung_family_breakfast",
        promotion_run_id="prun_demo_gangneung_family_breakfast_loop_1",
        segment_id="seg_demo_gangneung_family_search",
        content_id="content_demo_gangneung_family_email",
        content_option_id="option_demo_gangneung_family_email_1",
        ad_experiment_id="adexp_demo_gangneung_family_breakfast",
        evaluation_id="eval_demo_gangneung_family_breakfast",
        promotion_name="강릉 가족여행 조식 패키지",
        segment_name="강릉 가족 숙박 탐색 고객",
        natural_language_query=(
            "최근 강릉 가족 숙소를 검색했지만 예약을 시작하지 않은 고객"
        ),
        rule_json={
            "type": "all",
            "conditions": [
                {"event": "hotel_search", "property": "destination", "value": "gangneung"},
                {"property": "children_count", "operator": "gte", "value": 1},
                {"event": "booking_start", "operator": "not_exists"},
            ],
        },
        message_brief=(
            "강릉 가족 숙소를 찾던 고객에게 성인 2인 조식과 아동 1인 조식이 "
            "포함된 패키지를 소개합니다."
        ),
        offer_type="family_breakfast_package",
        landing_url=(
            "https://demo-shoppingmall.dev.loop-ad.org/search?destination=gangneung"
            "&deal=family-breakfast"
        ),
        subject="강릉 가족여행, 아이 조식까지 한 번에",
        preheader="가족 조식 패키지 객실을 모아봤어요.",
        title="아침 걱정 없는 강릉 가족여행",
        body=(
            "성인 2인과 아동 1인 조식이 포함된 강릉 숙소를 확인하고 "
            "가족여행 준비를 가볍게 시작해 보세요."
        ),
        cta="가족 패키지 확인하기",
        destination="gangneung",
        hotel_id="gangneung-gyeongpo-family-007",
        stage_counts=(156, 63, 52, 27, 11),
        loop_count=1,
        expected_status="goal_not_met",
        improvement_directions=(
            "이메일에서 약속한 가족 조식 조건이 랜딩 첫 화면에 바로 보이는지 점검",
            "숙소 검색으로 이어지는 버튼 문구와 강릉 필터 적용 상태를 확인",
        ),
        schedule_start_days_ago=92,
        schedule_end_days_ago=80,
    ),
    Scenario(
        key="yeosu_oceanview",
        promotion_id="promo_demo_yeosu_oceanview_earlybird",
        analysis_id="analysis_demo_yeosu_oceanview_earlybird",
        generation_id="generation_demo_yeosu_oceanview_earlybird",
        promotion_run_id="prun_demo_yeosu_oceanview_earlybird_loop_1",
        segment_id="seg_demo_yeosu_booking_intent",
        content_id="content_demo_yeosu_oceanview_email",
        content_option_id="option_demo_yeosu_oceanview_email_1",
        ad_experiment_id="adexp_demo_yeosu_oceanview_earlybird",
        evaluation_id="eval_demo_yeosu_oceanview_earlybird",
        promotion_name="여수 오션뷰 주말 얼리버드",
        segment_name="여수 오션뷰 예약 관심 고객",
        natural_language_query=(
            "여수 오션뷰 숙소를 상세 조회하고 예약 단계까지 진입한 고객"
        ),
        rule_json={
            "type": "all",
            "conditions": [
                {"event": "hotel_detail_view", "property": "destination", "value": "yeosu"},
                {"property": "view_type", "operator": "eq", "value": "ocean"},
                {"event": "booking_start", "operator": "exists"},
            ],
        },
        message_brief=(
            "여수 오션뷰 객실의 예약 단계까지 진입한 고객에게 주말 얼리버드 "
            "12% 할인과 무료 취소 가능 객실을 안내합니다."
        ),
        offer_type="oceanview_earlybird_discount",
        landing_url=(
            "https://demo-shoppingmall.dev.loop-ad.org/search?destination=yeosu"
            "&deal=oceanview-earlybird"
        ),
        subject="찜한 여수 오션뷰, 얼리버드 12% 할인",
        preheader="무료 취소 가능 객실로 주말 여행을 먼저 준비하세요.",
        title="여수 바다 앞 주말을 미리 예약하세요",
        body=(
            "최근 확인한 여수 오션뷰 객실을 얼리버드 12% 할인으로 예약하고 "
            "무료 취소 가능 여부도 함께 비교해 보세요."
        ),
        cta="예약 이어서 하기",
        destination="yeosu",
        hotel_id="yeosu-ocean-terrace-014",
        stage_counts=(173, 151, 126, 79, 12),
        loop_count=1,
        expected_status="goal_not_met",
        improvement_directions=(
            "예약 시작 이후 결제 실패·가격 변경·객실 소진 이벤트를 추가 수집해 직접 원인을 확인",
            "예약 화면에서 최종 결제 금액과 무료 취소 조건이 일관되게 표시되는지 점검",
        ),
        schedule_start_days_ago=52,
        schedule_end_days_ago=43,
    ),
)

BUSAN_WEEKDAY, GANGNEUNG_FAMILY_1, YEOSU_OCEANVIEW_1 = BASE_SCENARIOS

GANGNEUNG_FAMILY_2 = replace(
    GANGNEUNG_FAMILY_1,
    key="gangneung_family_loop_2",
    analysis_id="analysis_demo_gangneung_family_breakfast_loop_2",
    generation_id="generation_demo_gangneung_family_breakfast_loop_2",
    promotion_run_id="prun_demo_gangneung_family_breakfast_loop_2",
    content_id="content_demo_gangneung_family_email_loop_2",
    content_option_id="option_demo_gangneung_family_email_loop_2",
    ad_experiment_id="adexp_demo_gangneung_family_breakfast_loop_2",
    evaluation_id="eval_demo_gangneung_family_breakfast_loop_2",
    message_brief=(
        "1차 실험의 랜딩 이탈을 반영해 이메일과 랜딩 첫 화면에 가족 조식 "
        "포함 조건을 동일하게 표시하고 강릉 검색 버튼을 바로 노출합니다."
    ),
    subject="강릉 가족 조식 포함 객실, 조건 그대로 확인하세요",
    preheader="이메일에서 본 조식 조건으로 바로 검색할 수 있어요.",
    title="강릉 가족 조식 패키지를 바로 비교하세요",
    body=(
        "성인 2인과 아동 1인 조식 포함 조건을 랜딩 첫 화면에서도 그대로 "
        "확인하고 강릉 가족 객실만 바로 비교해 보세요."
    ),
    cta="강릉 가족 객실 바로 검색",
    stage_counts=(152, 121, 101, 65, 24),
    loop_count=2,
    expected_status="goal_met",
    improvement_directions=(
        "가족 조식 조건과 강릉 검색 CTA를 일치시킨 메시지 조합 유지",
        "예약 완료 고객의 가족여행 시점을 다음 지역 추천에 활용",
    ),
    schedule_start_days_ago=72,
    schedule_end_days_ago=60,
    change_summary=(
        "가족 조식 포함 조건을 이메일과 랜딩에 일치시키고 강릉 검색 CTA를 "
        "첫 화면에 노출"
    ),
)

YEOSU_OCEANVIEW_2 = replace(
    YEOSU_OCEANVIEW_1,
    key="yeosu_oceanview_loop_2",
    analysis_id="analysis_demo_yeosu_oceanview_earlybird_loop_2",
    generation_id="generation_demo_yeosu_oceanview_earlybird_loop_2",
    promotion_run_id="prun_demo_yeosu_oceanview_earlybird_loop_2",
    content_id="content_demo_yeosu_oceanview_email_loop_2",
    content_option_id="option_demo_yeosu_oceanview_email_loop_2",
    ad_experiment_id="adexp_demo_yeosu_oceanview_earlybird_loop_2",
    evaluation_id="eval_demo_yeosu_oceanview_earlybird_loop_2",
    message_brief=(
        "1차 실험의 예약 완료 이탈을 반영해 최종 결제 금액과 무료 취소 "
        "기한을 예약 화면에 고정 표시합니다."
    ),
    subject="여수 오션뷰 12% 할인, 결제 금액까지 미리 확인",
    preheader="무료 취소 기한과 최종 금액을 예약 전에 확인하세요.",
    title="가격과 취소 조건이 분명한 여수 얼리버드",
    body=(
        "여수 오션뷰 얼리버드 12% 할인 객실의 최종 결제 금액과 무료 취소 "
        "기한을 예약 전에 한 번에 확인하세요."
    ),
    cta="조건 확인하고 예약하기",
    stage_counts=(168, 148, 124, 83, 18),
    loop_count=2,
    expected_status="goal_not_met",
    improvement_directions=(
        "객실 소진과 가격 변경 여부를 예약 시작 전에 확인할 수 있도록 안내 강화",
        "결제 단계 입력 항목과 오류 발생 지점을 추가로 점검",
    ),
    schedule_start_days_ago=37,
    schedule_end_days_ago=28,
    change_summary="최종 결제 금액과 무료 취소 기한을 예약 화면에 고정 표시",
)

YEOSU_OCEANVIEW_3 = replace(
    YEOSU_OCEANVIEW_1,
    key="yeosu_oceanview_loop_3",
    analysis_id="analysis_demo_yeosu_oceanview_earlybird_loop_3",
    generation_id="generation_demo_yeosu_oceanview_earlybird_loop_3",
    promotion_run_id="prun_demo_yeosu_oceanview_earlybird_loop_3",
    content_id="content_demo_yeosu_oceanview_email_loop_3",
    content_option_id="option_demo_yeosu_oceanview_email_loop_3",
    ad_experiment_id="adexp_demo_yeosu_oceanview_earlybird_loop_3",
    evaluation_id="eval_demo_yeosu_oceanview_earlybird_loop_3",
    message_brief=(
        "2차 실험의 결제 이탈을 반영해 객실 소진·가격 변경 안내를 예약 전에 "
        "제공하고 결제 입력 단계를 줄입니다."
    ),
    subject="여수 오션뷰 객실 확보, 간편 예약으로 마무리하세요",
    preheader="가격 변경 여부를 확인하고 줄어든 단계로 예약하세요.",
    title="여수 오션뷰 얼리버드, 간편 예약으로 완료",
    body=(
        "현재 예약 가능한 여수 오션뷰 객실과 확정 금액을 먼저 확인하고 "
        "간소화된 결제 단계로 예약을 마무리하세요."
    ),
    cta="간편 예약 완료하기",
    stage_counts=(165, 147, 127, 91, 25),
    loop_count=3,
    expected_status="goal_met",
    improvement_directions=(
        "예약 전 객실·가격 확인과 간소화된 결제 흐름을 후속 캠페인에도 유지",
        "예약 완료 고객의 오션뷰 선호를 다음 숙박 추천에 활용",
    ),
    schedule_start_days_ago=22,
    schedule_end_days_ago=12,
    change_summary=(
        "객실 소진·가격 변경 여부를 예약 전에 안내하고 결제 입력 단계를 축소"
    ),
)

SCENARIOS = (
    BUSAN_WEEKDAY,
    GANGNEUNG_FAMILY_1,
    GANGNEUNG_FAMILY_2,
    YEOSU_OCEANVIEW_1,
    YEOSU_OCEANVIEW_2,
    YEOSU_OCEANVIEW_3,
)


STAGES = (
    ("campaign_landing", "광고 랜딩 도달"),
    ("hotel_search", "숙소 탐색"),
    ("hotel_detail_view", "숙소 상세 조회"),
    ("booking_start", "예약 시작"),
    ("booking_complete", "예약 완료"),
)


def _aws_json(*arguments: str) -> Any:
    output = subprocess.check_output(
        ["aws", *arguments, "--region", AWS_REGION, "--output", "json"],
        text=True,
    )
    return json.loads(output)


def _load_secret(secret_name: str) -> dict[str, str]:
    response = _aws_json(
        "secretsmanager", "get-secret-value", "--secret-id", secret_name
    )
    secret = json.loads(response["SecretString"])
    return {"username": str(secret["username"]), "password": str(secret["password"])}


def _resolve_aws_dev() -> tuple[str, str, dict[str, str], dict[str, str]]:
    identity = _aws_json("sts", "get-caller-identity")
    if str(identity["Account"]) != AWS_ACCOUNT_ID:
        raise RuntimeError(
            f"refusing to seed AWS account {identity['Account']}; expected {AWS_ACCOUNT_ID}"
        )

    cluster = _aws_json(
        "rds", "describe-db-clusters", "--db-cluster-identifier", AURORA_CLUSTER_ID
    )["DBClusters"][0]
    reservations = _aws_json(
        "ec2",
        "describe-instances",
        "--filters",
        "Name=instance-state-name,Values=running",
        f"Name=tag:Name,Values={CLICKHOUSE_INSTANCE_NAME}",
    )["Reservations"]
    clickhouse_hosts = [
        instance["PublicDnsName"]
        for reservation in reservations
        for instance in reservation["Instances"]
        if instance.get("PublicDnsName")
    ]
    if len(clickhouse_hosts) != 1:
        raise RuntimeError(
            "expected exactly one running dev ClickHouse instance, "
            f"found {len(clickhouse_hosts)}"
        )
    return (
        str(cluster["Endpoint"]),
        clickhouse_hosts[0],
        _load_secret(AURORA_SECRET_NAME),
        _load_secret(CLICKHOUSE_SECRET_NAME),
    )


def _required_environment(name: str) -> str:
    value = os.environ.get(name)
    if value is None or not value.strip():
        raise RuntimeError(f"required environment variable is missing: {name}")
    return value


def _resolve_local() -> tuple[
    str,
    int,
    str,
    dict[str, str],
    str,
    int,
    str,
    dict[str, str],
]:
    return (
        _required_environment("POSTGRES_HOST"),
        int(_required_environment("POSTGRES_PORT")),
        _required_environment("POSTGRES_DB"),
        {
            "username": _required_environment("POSTGRES_USER"),
            "password": _required_environment("POSTGRES_PASSWORD"),
        },
        _required_environment("CLICKHOUSE_HOST"),
        int(_required_environment("CLICKHOUSE_HTTP_PORT")),
        _required_environment("CLICKHOUSE_DATABASE"),
        {
            "username": _required_environment("CLICKHOUSE_USER"),
            "password": _required_environment("CLICKHOUSE_PASSWORD"),
        },
    )


def _canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _scenario_times(scenario: Scenario, today: date) -> tuple[datetime, datetime]:
    start = datetime.combine(
        today - timedelta(days=scenario.schedule_start_days_ago),
        datetime.min.time(),
        tzinfo=KST,
    ) + timedelta(hours=9)
    end = datetime.combine(
        today - timedelta(days=scenario.schedule_end_days_ago),
        datetime.min.time(),
        tzinfo=KST,
    ) + timedelta(hours=18)
    return start, end


def _promotion_scenarios(promotion_id: str) -> tuple[Scenario, ...]:
    return tuple(
        scenario for scenario in SCENARIOS if scenario.promotion_id == promotion_id
    )


def _promotion_schedule(
    promotion_id: str,
    today: date,
) -> tuple[datetime, datetime]:
    schedules = [
        _scenario_times(scenario, today)
        for scenario in _promotion_scenarios(promotion_id)
    ]
    return min(start for start, _ in schedules), max(end for _, end in schedules)


def _previous_scenario(scenario: Scenario) -> Scenario | None:
    if scenario.loop_count == 1:
        return None
    return next(
        (
            candidate
            for candidate in SCENARIOS
            if candidate.promotion_id == scenario.promotion_id
            and candidate.loop_count == scenario.loop_count - 1
        ),
        None,
    )


def _next_scenario(scenario: Scenario) -> Scenario | None:
    return next(
        (
            candidate
            for candidate in SCENARIOS
            if candidate.promotion_id == scenario.promotion_id
            and candidate.loop_count == scenario.loop_count + 1
        ),
        None,
    )


def _preflight_project(
    connection: psycopg.Connection[Any],
) -> tuple[str, bool]:
    with connection.cursor(row_factory=dict_row) as cursor:
        cursor.execute(
            "SELECT write_key FROM projects WHERE project_id = %s",
            (PROJECT_ID,),
        )
        project = cursor.fetchone()
        if project is None:
            raise RuntimeError(f"required project is missing: {PROJECT_ID}")
        cursor.execute(
            "SELECT name FROM campaigns WHERE campaign_id = %s",
            (CAMPAIGN_ID,),
        )
        existing = cursor.fetchone()
    if existing is not None and existing["name"] != CAMPAIGN_NAME:
        raise RuntimeError(
            f"campaign id collision: {CAMPAIGN_ID} belongs to {existing['name']!r}"
        )
    return str(project["write_key"]), existing is not None


def _upsert_hierarchy(
    connection: psycopg.Connection[Any],
    today: date,
) -> dict[str, dict[str, Any]]:
    campaign_start = today - timedelta(days=120)
    campaign_end = today - timedelta(days=10)
    with connection.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO campaigns (
                campaign_id, project_id, name, objective, target_audience,
                start_date, end_date, primary_metric, status
            ) VALUES (
                %s, %s, %s, %s, 'existing_users', %s, %s,
                'booking_conversion_rate', 'completed'
            )
            ON CONFLICT (campaign_id) DO UPDATE SET
                project_id = EXCLUDED.project_id,
                name = EXCLUDED.name,
                objective = EXCLUDED.objective,
                target_audience = EXCLUDED.target_audience,
                start_date = EXCLUDED.start_date,
                end_date = EXCLUDED.end_date,
                primary_metric = EXCLUDED.primary_metric,
                status = EXCLUDED.status,
                updated_at = now()
            """,
            (
                CAMPAIGN_ID,
                PROJECT_ID,
                CAMPAIGN_NAME,
                (
                    "부산·강릉·여수 숙박에 관심을 보인 기존 고객에게 지역별 "
                    "혜택을 제안해 예약 전환율을 높입니다."
                ),
                campaign_start,
                campaign_end,
            ),
        )

        for scenario in SCENARIOS:
            schedule_start, schedule_end = _scenario_times(scenario, today)
            promotion_schedule_start, promotion_schedule_end = _promotion_schedule(
                scenario.promotion_id,
                today,
            )
            promotion_scenarios = _promotion_scenarios(scenario.promotion_id)
            promotion_max_loop_count = max(
                item.loop_count for item in promotion_scenarios
            )
            promotion_status = max(
                promotion_scenarios,
                key=lambda item: item.loop_count,
            ).expected_status
            result_status = scenario.expected_status
            scope = [scenario.segment_id]
            scope_json = _canonical_json(scope)
            started_at = schedule_start + timedelta(hours=1)
            ended_at = schedule_end - timedelta(hours=1)
            analysis_at = schedule_start - timedelta(days=2)
            generation_started_at = analysis_at + timedelta(hours=2)
            generation_finished_at = generation_started_at + timedelta(minutes=4)
            metadata = {
                "demo_fixture": True,
                "fixture_id": FIXTURE_ID,
                "historical_campaign": True,
                "persona": "이미영",
                "destination": scenario.destination,
                "repeat_experiment_count": promotion_max_loop_count,
            }

            cursor.execute(
                """
                INSERT INTO promotions (
                    promotion_id, project_id, campaign_id, channel,
                    marketing_theme, target_audience, goal_metric,
                    goal_target_value, goal_basis, min_sample_size,
                    max_loop_count, message_brief, offer_type, landing_url,
                    landing_type, budget_json, metadata_json, status,
                    execution_mode, scheduled_start_at, scheduled_end_at,
                    loop_interval_unit, loop_interval_value
                ) VALUES (
                    %s, %s, %s, 'email', %s, 'existing_users',
                    'booking_conversion_rate', %s, 'all_segments', %s, %s,
                    %s, %s, %s, 'search_page', %s, %s, %s,
                    'manual', %s, %s, 'day', 7
                )
                ON CONFLICT (promotion_id) DO UPDATE SET
                    project_id = EXCLUDED.project_id,
                    campaign_id = EXCLUDED.campaign_id,
                    channel = EXCLUDED.channel,
                    marketing_theme = EXCLUDED.marketing_theme,
                    target_audience = EXCLUDED.target_audience,
                    goal_metric = EXCLUDED.goal_metric,
                    goal_target_value = EXCLUDED.goal_target_value,
                    goal_basis = EXCLUDED.goal_basis,
                    min_sample_size = EXCLUDED.min_sample_size,
                    max_loop_count = EXCLUDED.max_loop_count,
                    message_brief = EXCLUDED.message_brief,
                    offer_type = EXCLUDED.offer_type,
                    landing_url = EXCLUDED.landing_url,
                    landing_type = EXCLUDED.landing_type,
                    budget_json = EXCLUDED.budget_json,
                    metadata_json = EXCLUDED.metadata_json,
                    status = EXCLUDED.status,
                    execution_mode = EXCLUDED.execution_mode,
                    scheduled_start_at = EXCLUDED.scheduled_start_at,
                    scheduled_end_at = EXCLUDED.scheduled_end_at,
                    loop_interval_unit = EXCLUDED.loop_interval_unit,
                    loop_interval_value = EXCLUDED.loop_interval_value,
                    updated_at = now()
                """,
                (
                    scenario.promotion_id,
                    PROJECT_ID,
                    CAMPAIGN_ID,
                    scenario.promotion_name,
                    TARGET_VALUE,
                    MIN_SAMPLE_SIZE,
                    promotion_max_loop_count,
                    scenario.message_brief,
                    scenario.offer_type,
                    scenario.landing_url,
                    Jsonb({"currency": "KRW", "max_daily_budget": 350000}),
                    Jsonb(metadata),
                    promotion_status,
                    promotion_schedule_start,
                    promotion_schedule_end,
                ),
            )

            response_count = scenario.stage_counts[0]
            cursor.execute(
                """
                INSERT INTO segment_definitions (
                    segment_id, project_id, campaign_id, promotion_id,
                    segment_name, source, natural_language_query, rule_json,
                    profile_json, sample_size, total_eligible_user_count,
                    sample_ratio, status
                ) VALUES (
                    %s, %s, %s, %s, %s, 'ai_suggested', %s, %s, %s,
                    %s, %s, %s, 'active'
                )
                ON CONFLICT (segment_id) DO UPDATE SET
                    project_id = EXCLUDED.project_id,
                    campaign_id = EXCLUDED.campaign_id,
                    promotion_id = EXCLUDED.promotion_id,
                    segment_name = EXCLUDED.segment_name,
                    source = EXCLUDED.source,
                    natural_language_query = EXCLUDED.natural_language_query,
                    rule_json = EXCLUDED.rule_json,
                    profile_json = EXCLUDED.profile_json,
                    sample_size = EXCLUDED.sample_size,
                    total_eligible_user_count = EXCLUDED.total_eligible_user_count,
                    sample_ratio = EXCLUDED.sample_ratio,
                    status = EXCLUDED.status,
                    updated_at = now()
                """,
                (
                    scenario.segment_id,
                    PROJECT_ID,
                    CAMPAIGN_ID,
                    scenario.promotion_id,
                    scenario.segment_name,
                    scenario.natural_language_query,
                    Jsonb(scenario.rule_json),
                    Jsonb(
                        {
                            "description": scenario.natural_language_query,
                            "fixture_id": FIXTURE_ID,
                            "destination": scenario.destination,
                        }
                    ),
                    response_count,
                    ELIGIBLE_USER_COUNT,
                    Decimal(response_count) / Decimal(ELIGIBLE_USER_COUNT),
                ),
            )

            cursor.execute(
                """
                INSERT INTO promotion_analyses (
                    analysis_id, project_id, campaign_id, promotion_id,
                    focus_segment_ids_json, operator_instruction,
                    input_snapshot_json, profile_summary_json, output_json,
                    status, created_at, updated_at
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s, %s, %s,
                    'completed', %s, %s
                )
                ON CONFLICT (analysis_id) DO UPDATE SET
                    project_id = EXCLUDED.project_id,
                    campaign_id = EXCLUDED.campaign_id,
                    promotion_id = EXCLUDED.promotion_id,
                    focus_segment_ids_json = EXCLUDED.focus_segment_ids_json,
                    operator_instruction = EXCLUDED.operator_instruction,
                    input_snapshot_json = EXCLUDED.input_snapshot_json,
                    profile_summary_json = EXCLUDED.profile_summary_json,
                    output_json = EXCLUDED.output_json,
                    status = EXCLUDED.status,
                    updated_at = EXCLUDED.updated_at
                """,
                (
                    scenario.analysis_id,
                    PROJECT_ID,
                    CAMPAIGN_ID,
                    scenario.promotion_id,
                    Jsonb(scope),
                    f"{scenario.promotion_name}의 적합 고객군과 광고 전략을 분석합니다.",
                    Jsonb({"fixture_id": FIXTURE_ID, "eligible_users": ELIGIBLE_USER_COUNT}),
                    Jsonb(
                        {
                            "segment_name": scenario.segment_name,
                            "estimated_size": response_count,
                        }
                    ),
                    Jsonb({"result": "segment_confirmed", "fixture_id": FIXTURE_ID}),
                    analysis_at,
                    analysis_at + timedelta(minutes=20),
                ),
            )

            cursor.execute(
                """
                INSERT INTO promotion_target_segments (
                    analysis_id, project_id, campaign_id, promotion_id,
                    segment_id, segment_name, rule_json, profile_json,
                    content_brief_json, data_evidence_json, estimated_size,
                    priority, status, confirmed_by, confirmed_at
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                    %s, 'high', %s, 'demo_operator_lee_miyoung', %s
                )
                ON CONFLICT (analysis_id, segment_id) DO UPDATE SET
                    segment_name = EXCLUDED.segment_name,
                    rule_json = EXCLUDED.rule_json,
                    profile_json = EXCLUDED.profile_json,
                    content_brief_json = EXCLUDED.content_brief_json,
                    data_evidence_json = EXCLUDED.data_evidence_json,
                    estimated_size = EXCLUDED.estimated_size,
                    priority = EXCLUDED.priority,
                    status = EXCLUDED.status,
                    confirmed_by = EXCLUDED.confirmed_by,
                    confirmed_at = EXCLUDED.confirmed_at
                """,
                (
                    scenario.analysis_id,
                    PROJECT_ID,
                    CAMPAIGN_ID,
                    scenario.promotion_id,
                    scenario.segment_id,
                    scenario.segment_name,
                    Jsonb(scenario.rule_json),
                    Jsonb({"description": scenario.natural_language_query}),
                    Jsonb({"message_brief": scenario.message_brief, "channel": "email"}),
                    Jsonb(
                        {
                            "source": "historical_demo_fixture",
                            "fixture_id": FIXTURE_ID,
                            "matched_users": response_count,
                        }
                    ),
                    response_count,
                    result_status,
                    analysis_at + timedelta(minutes=30),
                ),
            )

            generation_input = {
                "schema_version": "generation.request.v1",
                "project_id": PROJECT_ID,
                "campaign_id": CAMPAIGN_ID,
                "promotion_id": scenario.promotion_id,
                "analysis_id": scenario.analysis_id,
                "channel": "email",
                "loop_count": scenario.loop_count,
                "content_option_count": 1,
                "operator_instruction": scenario.message_brief,
                "fixture_id": FIXTURE_ID,
            }
            cursor.execute(
                """
                INSERT INTO generation_runs (
                    generation_id, analysis_id, project_id, campaign_id,
                    promotion_id, content_option_count, operator_instruction,
                    input_json, output_json, generation_report_json, status,
                    started_at, finished_at, retry_count, idempotency_key,
                    request_fingerprint, created_at, updated_at
                ) VALUES (
                    %s, %s, %s, %s, %s, 1, %s, %s, %s, %s,
                    'completed', %s, %s, 0, %s, %s, %s, %s
                )
                ON CONFLICT (generation_id) DO UPDATE SET
                    analysis_id = EXCLUDED.analysis_id,
                    project_id = EXCLUDED.project_id,
                    campaign_id = EXCLUDED.campaign_id,
                    promotion_id = EXCLUDED.promotion_id,
                    content_option_count = EXCLUDED.content_option_count,
                    operator_instruction = EXCLUDED.operator_instruction,
                    input_json = EXCLUDED.input_json,
                    output_json = EXCLUDED.output_json,
                    generation_report_json = EXCLUDED.generation_report_json,
                    status = EXCLUDED.status,
                    started_at = EXCLUDED.started_at,
                    finished_at = EXCLUDED.finished_at,
                    retry_count = EXCLUDED.retry_count,
                    next_retry_at = NULL,
                    last_error_code = NULL,
                    last_error_message = NULL,
                    worker_id = NULL,
                    lease_token = NULL,
                    heartbeat_at = NULL,
                    lease_expires_at = NULL,
                    idempotency_key = EXCLUDED.idempotency_key,
                    request_fingerprint = EXCLUDED.request_fingerprint,
                    updated_at = EXCLUDED.updated_at
                """,
                (
                    scenario.generation_id,
                    scenario.analysis_id,
                    PROJECT_ID,
                    CAMPAIGN_ID,
                    scenario.promotion_id,
                    scenario.message_brief,
                    Jsonb(generation_input),
                    Jsonb({"status": "completed", "candidate_count": 1}),
                    Jsonb({"fixture_id": FIXTURE_ID, "guardrail_status": "passed"}),
                    generation_started_at,
                    generation_finished_at,
                    f"fixture:{FIXTURE_ID}:{scenario.generation_id}",
                    _sha256(_canonical_json(generation_input)),
                    generation_started_at,
                    generation_finished_at,
                ),
            )

            cursor.execute(
                """
                INSERT INTO content_candidates (
                    content_id, content_option_id, generation_id, analysis_id,
                    project_id, campaign_id, promotion_id, segment_id, channel,
                    subject, preheader, title, body, cta, landing_url,
                    generation_prompt, reason_summary, data_evidence_json,
                    message_strategy, metadata_json, status, created_at, updated_at
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s, %s, 'email',
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                    'active', %s, %s
                )
                ON CONFLICT (content_id) DO UPDATE SET
                    content_option_id = EXCLUDED.content_option_id,
                    generation_id = EXCLUDED.generation_id,
                    analysis_id = EXCLUDED.analysis_id,
                    project_id = EXCLUDED.project_id,
                    campaign_id = EXCLUDED.campaign_id,
                    promotion_id = EXCLUDED.promotion_id,
                    segment_id = EXCLUDED.segment_id,
                    channel = EXCLUDED.channel,
                    subject = EXCLUDED.subject,
                    preheader = EXCLUDED.preheader,
                    title = EXCLUDED.title,
                    body = EXCLUDED.body,
                    cta = EXCLUDED.cta,
                    landing_url = EXCLUDED.landing_url,
                    generation_prompt = EXCLUDED.generation_prompt,
                    reason_summary = EXCLUDED.reason_summary,
                    data_evidence_json = EXCLUDED.data_evidence_json,
                    message_strategy = EXCLUDED.message_strategy,
                    metadata_json = EXCLUDED.metadata_json,
                    status = EXCLUDED.status,
                    updated_at = EXCLUDED.updated_at
                """,
                (
                    scenario.content_id,
                    scenario.content_option_id,
                    scenario.generation_id,
                    scenario.analysis_id,
                    PROJECT_ID,
                    CAMPAIGN_ID,
                    scenario.promotion_id,
                    scenario.segment_id,
                    scenario.subject,
                    scenario.preheader,
                    scenario.title,
                    scenario.body,
                    scenario.cta,
                    scenario.landing_url,
                    f"{scenario.segment_name}에게 지역 혜택을 명확히 전달하는 이메일",
                    f"{scenario.natural_language_query}의 예약 전환을 위한 맞춤 메시지입니다.",
                    Jsonb(
                        {
                            "fixture_id": FIXTURE_ID,
                            "audience_size": response_count,
                            "loop_count": scenario.loop_count,
                            "change_summary": scenario.change_summary,
                        }
                    ),
                    "destination_offer_match",
                    Jsonb(metadata),
                    generation_finished_at,
                    generation_finished_at,
                ),
            )

            cursor.execute(
                """
                INSERT INTO promotion_runs (
                    promotion_run_id, project_id, campaign_id, promotion_id,
                    analysis_id, generation_id, loop_count, status,
                    goal_snapshot_json, segment_scope_json,
                    segment_scope_fingerprint, started_at, ended_at,
                    created_at, updated_at
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                    %s, %s, %s, %s
                )
                ON CONFLICT (promotion_run_id) DO UPDATE SET
                    project_id = EXCLUDED.project_id,
                    campaign_id = EXCLUDED.campaign_id,
                    promotion_id = EXCLUDED.promotion_id,
                    analysis_id = EXCLUDED.analysis_id,
                    generation_id = EXCLUDED.generation_id,
                    loop_count = EXCLUDED.loop_count,
                    status = EXCLUDED.status,
                    goal_snapshot_json = EXCLUDED.goal_snapshot_json,
                    segment_scope_json = EXCLUDED.segment_scope_json,
                    segment_scope_fingerprint = EXCLUDED.segment_scope_fingerprint,
                    started_at = EXCLUDED.started_at,
                    ended_at = EXCLUDED.ended_at,
                    updated_at = EXCLUDED.updated_at
                """,
                (
                    scenario.promotion_run_id,
                    PROJECT_ID,
                    CAMPAIGN_ID,
                    scenario.promotion_id,
                    scenario.analysis_id,
                    scenario.generation_id,
                    scenario.loop_count,
                    result_status,
                    Jsonb(
                        {
                            "goal_metric": "booking_conversion_rate",
                            "goal_target_value": str(TARGET_VALUE),
                            "goal_basis": "all_segments",
                            "min_sample_size": MIN_SAMPLE_SIZE,
                        }
                    ),
                    Jsonb(scope),
                    _sha256(scope_json),
                    started_at,
                    ended_at,
                    started_at,
                    ended_at,
                ),
            )

            cursor.execute(
                """
                INSERT INTO ad_experiments (
                    ad_experiment_id, project_id, campaign_id, promotion_id,
                    promotion_run_id, analysis_id, generation_id, segment_id,
                    segment_name, content_id, content_option_id, channel,
                    loop_count, status, goal_metric, goal_target_value,
                    goal_basis, started_at, ended_at, created_at, updated_at
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                    'email', %s, %s, 'booking_conversion_rate', %s,
                    'all_segments', %s, %s, %s, %s
                )
                ON CONFLICT (ad_experiment_id) DO UPDATE SET
                    project_id = EXCLUDED.project_id,
                    campaign_id = EXCLUDED.campaign_id,
                    promotion_id = EXCLUDED.promotion_id,
                    promotion_run_id = EXCLUDED.promotion_run_id,
                    analysis_id = EXCLUDED.analysis_id,
                    generation_id = EXCLUDED.generation_id,
                    segment_id = EXCLUDED.segment_id,
                    segment_name = EXCLUDED.segment_name,
                    content_id = EXCLUDED.content_id,
                    content_option_id = EXCLUDED.content_option_id,
                    channel = EXCLUDED.channel,
                    loop_count = EXCLUDED.loop_count,
                    status = EXCLUDED.status,
                    goal_metric = EXCLUDED.goal_metric,
                    goal_target_value = EXCLUDED.goal_target_value,
                    goal_basis = EXCLUDED.goal_basis,
                    started_at = EXCLUDED.started_at,
                    ended_at = EXCLUDED.ended_at,
                    updated_at = EXCLUDED.updated_at
                """,
                (
                    scenario.ad_experiment_id,
                    PROJECT_ID,
                    CAMPAIGN_ID,
                    scenario.promotion_id,
                    scenario.promotion_run_id,
                    scenario.analysis_id,
                    scenario.generation_id,
                    scenario.segment_id,
                    scenario.segment_name,
                    scenario.content_id,
                    scenario.content_option_id,
                    scenario.loop_count,
                    result_status,
                    TARGET_VALUE,
                    started_at,
                    ended_at,
                    started_at,
                    ended_at,
                ),
            )

            cursor.execute(
                """
                DELETE FROM user_segment_assignments
                WHERE project_id = %s
                  AND promotion_run_id = %s
                  AND assignment_source = 'fixture'
                """,
                (PROJECT_ID, scenario.promotion_run_id),
            )
            assignments = [
                (
                    PROJECT_ID,
                    scenario.promotion_run_id,
                    f"demo_history_{scenario.key}_user_{user_no:03d}",
                    scenario.segment_id,
                    scenario.ad_experiment_id,
                    scenario.content_id,
                    scenario.content_option_id,
                    Decimal("0.930000") - Decimal(user_no % 20) / Decimal(1000),
                    started_at,
                    ended_at,
                )
                for user_no in range(response_count)
            ]
            cursor.executemany(
                """
                INSERT INTO user_segment_assignments (
                    project_id, promotion_run_id, user_id, segment_id,
                    ad_experiment_id, content_id, content_option_id,
                    similarity_score, fallback, fallback_reason,
                    assignment_source, assigned_at, expires_at
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s, %s,
                    false, NULL, 'fixture', %s, %s
                )
                ON CONFLICT (promotion_run_id, user_id) DO UPDATE SET
                    project_id = EXCLUDED.project_id,
                    segment_id = EXCLUDED.segment_id,
                    ad_experiment_id = EXCLUDED.ad_experiment_id,
                    content_id = EXCLUDED.content_id,
                    content_option_id = EXCLUDED.content_option_id,
                    similarity_score = EXCLUDED.similarity_score,
                    fallback = EXCLUDED.fallback,
                    fallback_reason = EXCLUDED.fallback_reason,
                    assignment_source = EXCLUDED.assignment_source,
                    assigned_at = EXCLUDED.assigned_at,
                    expires_at = EXCLUDED.expires_at
                """,
                assignments,
            )

    return _load_experiments(connection)


def _load_experiments(
    connection: psycopg.Connection[Any],
) -> dict[str, dict[str, Any]]:
    experiment_ids = [scenario.ad_experiment_id for scenario in SCENARIOS]
    with connection.cursor(row_factory=dict_row) as cursor:
        cursor.execute(
            """
            SELECT
                ad_experiment_id, project_id, campaign_id, promotion_id,
                promotion_run_id, segment_id, content_id, content_option_id,
                channel, goal_target_value, started_at, ended_at
            FROM ad_experiments
            WHERE project_id = %s
              AND campaign_id = %s
              AND ad_experiment_id = ANY(%s)
            """,
            (PROJECT_ID, CAMPAIGN_ID, experiment_ids),
        )
        experiments = {row["ad_experiment_id"]: dict(row) for row in cursor.fetchall()}
    missing = sorted(set(experiment_ids) - set(experiments))
    if missing:
        raise RuntimeError(f"dedicated demo experiments are missing: {missing}")
    return experiments


def _fixture_rows(
    scenario: Scenario,
    experiment: dict[str, Any],
    write_key: str,
) -> list[list[Any]]:
    rows: list[list[Any]] = []
    base_time = experiment["ended_at"] - timedelta(days=1)
    for user_no in range(scenario.stage_counts[0]):
        user_id = f"demo_history_{scenario.key}_user_{user_no:03d}"
        for stage_no, ((event_name, _), stage_count) in enumerate(
            zip(STAGES, scenario.stage_counts)
        ):
            if user_no >= stage_count:
                continue
            properties = {
                "campaign_id": CAMPAIGN_ID,
                "promotion_id": scenario.promotion_id,
                "promotion_run_id": scenario.promotion_run_id,
                "ad_experiment_id": scenario.ad_experiment_id,
                "segment_id": scenario.segment_id,
                "promotion_channel": "email",
                "content_id": scenario.content_id,
                "content_option_id": scenario.content_option_id,
                "booking_id": f"booking_demo_history_{scenario.key}_{user_no:03d}",
                "hotel_id": scenario.hotel_id,
                "destination": scenario.destination,
                "fixture_id": FIXTURE_ID,
            }
            rows.append(
                [
                    PROJECT_ID,
                    write_key,
                    "hotel_rec_promo.v1",
                    (
                        f"{FIXTURE_EVENT_PREFIX}{scenario.key}_{user_no:03d}_"
                        f"{event_name}"
                    ),
                    event_name,
                    base_time + timedelta(minutes=stage_no * 5),
                    "fixture",
                    user_id,
                    f"session_demo_history_{scenario.key}_{user_no:03d}",
                    json.dumps(properties, ensure_ascii=False, separators=(",", ":")),
                    "valid",
                ]
            )
    return rows


def _replace_clickhouse_fixture(client: Any, rows: list[list[Any]]) -> None:
    experiment_ids = [scenario.ad_experiment_id for scenario in SCENARIOS]
    client.command(
        """
        ALTER TABLE raw_events
        DELETE WHERE project_id = {project_id:String}
          AND source = 'fixture'
          AND startsWith(event_id, {event_prefix:String})
        SETTINGS mutations_sync = 1
        """,
        parameters={"project_id": PROJECT_ID, "event_prefix": FIXTURE_EVENT_PREFIX},
    )
    client.command(
        """
        ALTER TABLE promotion_touch_events
        DELETE WHERE project_id = {project_id:String}
          AND source = 'fixture'
          AND JSONExtractString(properties_json, 'fixture_id') = {fixture_id:String}
          AND ad_experiment_id IN {experiment_ids:Array(String)}
        SETTINGS mutations_sync = 1
        """,
        parameters={
            "project_id": PROJECT_ID,
            "fixture_id": FIXTURE_ID,
            "experiment_ids": experiment_ids,
        },
    )
    client.command(
        """
        ALTER TABLE booking_outcome_events
        DELETE WHERE project_id = {project_id:String}
          AND JSONExtractString(properties_json, 'fixture_id') = {fixture_id:String}
          AND ad_experiment_id IN {experiment_ids:Array(String)}
        SETTINGS mutations_sync = 1
        """,
        parameters={
            "project_id": PROJECT_ID,
            "fixture_id": FIXTURE_ID,
            "experiment_ids": experiment_ids,
        },
    )
    client.insert(
        "raw_events",
        rows,
        column_names=[
            "project_id",
            "write_key",
            "schema_version",
            "event_id",
            "event_name",
            "event_time",
            "source",
            "user_id",
            "session_id",
            "properties_json",
            "validation_status",
        ],
    )


def _load_funnel_counts(
    client: Any,
    experiment: dict[str, Any],
    cutoff: datetime,
) -> tuple[int, ...]:
    result = client.query(
        """
        WITH
            toDateTime64(0, 3, 'UTC') AS no_event,
            response_users AS (
                SELECT user_id, min(event_time) AS response_at,
                       max(source = 'fixture') AS fixture_response
                FROM promotion_touch_events
                WHERE project_id = {project_id:String}
                  AND promotion_run_id = {promotion_run_id:String}
                  AND ad_experiment_id = {ad_experiment_id:String}
                  AND event_name = 'campaign_landing'
                  AND event_time <= {evaluation_cutoff_at:DateTime64(3, 'UTC')}
                  AND notEmpty(user_id)
                GROUP BY user_id
            ),
            browsing_users AS (
                SELECT user_id,
                       maxIf(event_time, event_name IN (
                           'hotel_search', 'hotel_click', 'hotel_detail_view'
                       )) AS hotel_search_or_later_at,
                       maxIf(event_time, event_name = 'hotel_detail_view')
                           AS hotel_detail_view_at
                FROM raw_events
                WHERE project_id = {project_id:String}
                  AND validation_status = 'valid'
                  AND JSONExtractString(properties_json, 'promotion_run_id') =
                      {promotion_run_id:String}
                  AND JSONExtractString(properties_json, 'ad_experiment_id') =
                      {ad_experiment_id:String}
                  AND event_name IN ('hotel_search', 'hotel_click', 'hotel_detail_view')
                  AND event_time <= {evaluation_cutoff_at:DateTime64(3, 'UTC')}
                  AND notEmpty(user_id)
                GROUP BY user_id
            ),
            booking_users AS (
                SELECT user_id,
                       maxIf(event_time, event_name = 'booking_start') AS booking_start_at,
                       maxIf(event_time, event_name = 'booking_complete') AS booking_complete_at
                FROM booking_outcome_events
                WHERE project_id = {project_id:String}
                  AND promotion_run_id = {promotion_run_id:String}
                  AND ad_experiment_id = {ad_experiment_id:String}
                  AND event_name IN ('booking_start', 'booking_complete')
                  AND event_time <= {evaluation_cutoff_at:DateTime64(3, 'UTC')}
                  AND notEmpty(user_id)
                GROUP BY user_id
            ),
            progress AS (
                SELECT responses.response_at,
                       responses.fixture_response,
                       greatest(
                           ifNull(browsing.hotel_search_or_later_at, no_event),
                           ifNull(browsing.hotel_detail_view_at, no_event),
                           ifNull(bookings.booking_start_at, no_event),
                           ifNull(bookings.booking_complete_at, no_event)
                       ) AS search_at,
                       greatest(
                           ifNull(browsing.hotel_detail_view_at, no_event),
                           ifNull(bookings.booking_start_at, no_event),
                           ifNull(bookings.booking_complete_at, no_event)
                       ) AS detail_at,
                       greatest(
                           ifNull(bookings.booking_start_at, no_event),
                           ifNull(bookings.booking_complete_at, no_event)
                       ) AS booking_start_at,
                       ifNull(bookings.booking_complete_at, no_event) AS booking_complete_at
                FROM response_users AS responses
                LEFT JOIN browsing_users AS browsing USING (user_id)
                LEFT JOIN booking_users AS bookings USING (user_id)
            )
        SELECT count(),
               countIf(search_at >= response_at),
               countIf(detail_at >= response_at),
               countIf(booking_start_at >= response_at),
               countIf(booking_complete_at >= response_at),
               countIf(fixture_response = 1)
        FROM progress
        """,
        parameters={
            "project_id": PROJECT_ID,
            "promotion_run_id": experiment["promotion_run_id"],
            "ad_experiment_id": experiment["ad_experiment_id"],
            "evaluation_cutoff_at": cutoff,
        },
    )
    return tuple(int(value) for value in result.result_rows[0])


def _ratio(numerator: int, denominator: int) -> float:
    return 0.0 if denominator == 0 else numerator / denominator


def _build_diagnosis(
    scenario: Scenario,
    counts: tuple[int, ...],
) -> tuple[str, str, dict[str, Any]]:
    response, search, detail, booking_start, booking_complete, fixture_response = counts
    stage_counts = (response, search, detail, booking_start, booking_complete)
    stages: list[dict[str, Any]] = []
    dropoffs: list[dict[str, Any]] = []
    for index, ((key, label), count) in enumerate(zip(STAGES, stage_counts)):
        previous = None if index == 0 else stage_counts[index - 1]
        dropoff_count = None if previous is None else previous - count
        dropoff_rate = None if previous is None else _ratio(dropoff_count, previous)
        stages.append(
            {
                "key": key,
                "label": label,
                "user_count": count,
                "conversion_rate_from_previous": (
                    None if previous is None else _ratio(count, previous)
                ),
                "dropoff_count_from_previous": dropoff_count,
                "dropoff_rate_from_previous": dropoff_rate,
            }
        )
        if previous is not None:
            previous_key, previous_label = STAGES[index - 1]
            dropoffs.append(
                {
                    "from_stage_key": previous_key,
                    "from_stage_label": previous_label,
                    "to_stage_key": key,
                    "to_stage_label": label,
                    "from_count": previous,
                    "to_count": count,
                    "dropoff_count": dropoff_count,
                    "dropoff_rate": dropoff_rate,
                }
            )
    largest_dropoff = max(
        dropoffs,
        key=lambda item: (item["dropoff_count"], item["dropoff_rate"]),
    )
    actual_value = Decimal(booking_complete) / Decimal(response)
    previous = _previous_scenario(scenario)
    previous_value = (
        None
        if previous is None
        else Decimal(previous.stage_counts[4]) / Decimal(previous.stage_counts[0])
    )
    improvement_percentage_points = (
        None
        if previous_value is None
        else ((actual_value - previous_value) * Decimal(100)).quantize(
            Decimal("0.01")
        )
    )
    status = "goal_met" if actual_value >= TARGET_VALUE else "goal_not_met"
    gap_percentage_points = max(
        (TARGET_VALUE - actual_value) * Decimal(100), Decimal(0)
    ).quantize(Decimal("0.01"))
    if status == "goal_met":
        if previous is None:
            summary = (
                f"예약 완료율 {actual_value * 100:.2f}%로 "
                f"목표 {TARGET_VALUE * 100:.2f}%를 달성했습니다."
            )
        else:
            summary = (
                f"{scenario.loop_count}번째 실험에서 '{scenario.change_summary}' 변경안을 "
                f"적용했습니다. 예약 완료율은 이전 실험 {previous_value * 100:.2f}%에서 "
                f"{actual_value * 100:.2f}%로 {improvement_percentage_points}%p 개선되어 "
                f"목표 {TARGET_VALUE * 100:.2f}%를 달성했습니다."
            )
        bottleneck = "none"
    else:
        comparison = ""
        if previous is not None:
            comparison = (
                f"{scenario.loop_count}번째 실험에서 '{scenario.change_summary}' 변경안을 "
                f"적용해 이전 실험 {previous_value * 100:.2f}%보다 "
                f"{improvement_percentage_points}%p 개선됐지만, "
            )
        summary = (
            f"{comparison}예약 완료율 {actual_value * 100:.2f}%로 목표 "
            f"{TARGET_VALUE * 100:.2f}%보다 {gap_percentage_points}%p 낮습니다. "
            f"가장 큰 관측 이탈은 {largest_dropoff['from_stage_label']}에서 "
            f"{largest_dropoff['to_stage_label']} 단계로 넘어가는 구간으로, "
            f"{largest_dropoff['from_count']}명 중 "
            f"{largest_dropoff['dropoff_count']}명"
            f"({largest_dropoff['dropoff_rate'] * 100:.2f}%)이 다음 단계에 "
            "도달하지 않았습니다."
        )
        bottleneck = (
            f"{largest_dropoff['from_stage_key']}_to_"
            f"{largest_dropoff['to_stage_key']}"
        )
    limitations = [
        "동일 광고 실험에 귀속된 유효 이벤트의 고유 사용자만 집계했습니다.",
        "시연용 과거 캠페인 데이터이며 실제 운영 성과와 섞이지 않습니다.",
    ]
    if bottleneck == "booking_start_to_booking_complete":
        limitations.append(
            "결제 오류, 가격 변경, 객실 소진 이벤트가 없어 직접 원인은 확정할 수 없습니다."
        )
    evidence = [
        f"광고 랜딩 도달 고객 {response}명 중 예약 완료 {booking_complete}명",
        (
            f"{largest_dropoff['from_stage_label']} "
            f"{largest_dropoff['from_count']}명 중 "
            f"{largest_dropoff['to_stage_label']} "
            f"{largest_dropoff['to_count']}명"
        ),
        (
            f"실제 성과 {actual_value * 100:.2f}% / "
            f"목표 {TARGET_VALUE * 100:.2f}%"
            if status == "goal_met"
            else f"목표 대비 {gap_percentage_points}%p 부족"
        ),
    ]
    if previous is not None:
        evidence.insert(
            1,
            (
                f"이전 {previous.loop_count}번째 실험 {previous_value * 100:.2f}% 대비 "
                f"{improvement_percentage_points}%p 개선"
            ),
        )
    diagnosis = {
        "version": "dec.evaluation-diagnosis.v2",
        "status": status,
        "summary": summary,
        "observed_bottleneck": bottleneck,
        "largest_dropoff": largest_dropoff,
        "evidence": evidence,
        "improvement_directions": list(scenario.improvement_directions),
        "gap_percentage_points": float(gap_percentage_points),
        "evidence_strength": {
            "level": "sufficient",
            "sample_size": response,
            "reason": "단계별 이탈을 비교할 수 있는 시연 표본이 확보되었습니다.",
        },
        "limitations": limitations,
        "data_origin": {"kind": "demo_fixture", "label": "시연 데이터"},
        "experiment_iteration": {
            "loop_count": scenario.loop_count,
            "change_summary": scenario.change_summary,
            "previous_loop_count": None if previous is None else previous.loop_count,
            "previous_actual_value": (
                None if previous_value is None else float(previous_value)
            ),
            "improvement_percentage_points": (
                None
                if improvement_percentage_points is None
                else float(improvement_percentage_points)
            ),
        },
        "funnel": {
            "counting_method": "cumulative_user_reach_after_ad_response",
            "stages": stages,
            "largest_dropoff": largest_dropoff,
        },
    }
    if fixture_response != response:
        raise RuntimeError(
            f"{scenario.key} fixture response mismatch: {fixture_response}/{response}"
        )
    return status, summary, diagnosis


def _upsert_evaluation(
    connection: psycopg.Connection[Any],
    scenario: Scenario,
    experiment: dict[str, Any],
    counts: tuple[int, ...],
) -> None:
    status, summary, diagnosis = _build_diagnosis(scenario, counts)
    if status != scenario.expected_status:
        raise RuntimeError(
            f"{scenario.key} resolved to {status}; expected {scenario.expected_status}"
        )
    cutoff = experiment["ended_at"] + timedelta(hours=1)
    denominator_count = counts[0]
    numerator_count = counts[4]
    actual_value = Decimal(numerator_count) / Decimal(denominator_count)
    result_json = {
        "evaluation_cutoff_at": cutoff.astimezone(UTC).isoformat(timespec="milliseconds")
        .replace("+00:00", "Z"),
        "window_start": (cutoff - timedelta(days=30))
        .astimezone(UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z"),
        "evaluation_mode": "target_threshold",
        "evaluation_scope": "ad_experiment",
        "evaluator_version": "dec.target-threshold-evaluator.v2",
        "metric_sql_version": "dec.evaluation-metric-sql.v2",
        "metric_source": (
            "promotion_touch_events + raw_events + booking_outcome_events"
        ),
        "event_names": {
            "numerator": "booking_complete",
            "denominator": "campaign_landing",
        },
        "status_reason": status,
        "min_sample_size": MIN_SAMPLE_SIZE,
        "target_value": str(TARGET_VALUE),
        "actual_value": str(actual_value),
        "numerator_count": numerator_count,
        "denominator_count": denominator_count,
        "diagnosis": diagnosis,
    }
    with connection.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO promotion_evaluations (
                evaluation_id, project_id, campaign_id, promotion_id,
                promotion_run_id, ad_experiment_id, segment_id, content_id,
                content_option_id, metric, target_value, actual_value,
                numerator_count, denominator_count, sample_size, basis,
                status, feedback, next_loop_required, result_json, created_at
            ) VALUES (
                %s, %s, %s, %s, %s, %s, %s, %s, %s,
                'booking_conversion_rate', %s, %s, %s, %s, %s,
                'all_segments', %s, %s, %s, %s, %s
            )
            ON CONFLICT (evaluation_id) DO UPDATE SET
                project_id = EXCLUDED.project_id,
                campaign_id = EXCLUDED.campaign_id,
                promotion_id = EXCLUDED.promotion_id,
                promotion_run_id = EXCLUDED.promotion_run_id,
                ad_experiment_id = EXCLUDED.ad_experiment_id,
                segment_id = EXCLUDED.segment_id,
                content_id = EXCLUDED.content_id,
                content_option_id = EXCLUDED.content_option_id,
                metric = EXCLUDED.metric,
                target_value = EXCLUDED.target_value,
                actual_value = EXCLUDED.actual_value,
                numerator_count = EXCLUDED.numerator_count,
                denominator_count = EXCLUDED.denominator_count,
                sample_size = EXCLUDED.sample_size,
                basis = EXCLUDED.basis,
                status = EXCLUDED.status,
                feedback = EXCLUDED.feedback,
                next_loop_required = EXCLUDED.next_loop_required,
                result_json = EXCLUDED.result_json,
                created_at = EXCLUDED.created_at
            """,
            (
                scenario.evaluation_id,
                PROJECT_ID,
                CAMPAIGN_ID,
                scenario.promotion_id,
                scenario.promotion_run_id,
                scenario.ad_experiment_id,
                scenario.segment_id,
                scenario.content_id,
                scenario.content_option_id,
                TARGET_VALUE,
                actual_value,
                numerator_count,
                denominator_count,
                denominator_count,
                status,
                summary,
                status == "goal_not_met",
                Jsonb(result_json),
                cutoff,
            ),
        )


def _upsert_repeat_lineage(
    connection: psycopg.Connection[Any],
    experiments: dict[str, dict[str, Any]],
) -> None:
    with connection.cursor() as cursor:
        for scenario in SCENARIOS:
            previous = _previous_scenario(scenario)
            if previous is None:
                continue
            cursor.execute(
                """
                UPDATE ad_experiments
                SET parent_ad_experiment_id = %s,
                    source_evaluation_id = %s,
                    updated_at = %s
                WHERE ad_experiment_id = %s
                  AND project_id = %s
                  AND campaign_id = %s
                """,
                (
                    previous.ad_experiment_id,
                    previous.evaluation_id,
                    experiments[scenario.ad_experiment_id]["ended_at"],
                    scenario.ad_experiment_id,
                    PROJECT_ID,
                    CAMPAIGN_ID,
                ),
            )
            cursor.execute(
                """
                INSERT INTO next_loop_preparations (
                    next_loop_preparation_id, source_promotion_run_id,
                    analysis_id, generation_id, attempt_no,
                    failed_segment_ids_json, failed_ad_experiment_ids_json,
                    source_evaluation_ids_json, status,
                    activated_promotion_run_id, created_at, updated_at
                ) VALUES (
                    %s, %s, %s, %s, 1, %s, %s, %s, 'activated', %s, %s, %s
                )
                ON CONFLICT (next_loop_preparation_id) DO UPDATE SET
                    source_promotion_run_id = EXCLUDED.source_promotion_run_id,
                    analysis_id = EXCLUDED.analysis_id,
                    generation_id = EXCLUDED.generation_id,
                    attempt_no = EXCLUDED.attempt_no,
                    failed_segment_ids_json = EXCLUDED.failed_segment_ids_json,
                    failed_ad_experiment_ids_json =
                        EXCLUDED.failed_ad_experiment_ids_json,
                    source_evaluation_ids_json = EXCLUDED.source_evaluation_ids_json,
                    status = EXCLUDED.status,
                    activated_promotion_run_id = EXCLUDED.activated_promotion_run_id,
                    updated_at = EXCLUDED.updated_at
                """,
                (
                    f"prep_{scenario.ad_experiment_id}",
                    previous.promotion_run_id,
                    scenario.analysis_id,
                    scenario.generation_id,
                    Jsonb([previous.segment_id]),
                    Jsonb([previous.ad_experiment_id]),
                    Jsonb([previous.evaluation_id]),
                    scenario.promotion_run_id,
                    experiments[scenario.ad_experiment_id]["started_at"]
                    - timedelta(hours=1),
                    experiments[scenario.ad_experiment_id]["started_at"]
                    - timedelta(hours=1),
                ),
            )


def _verify_postgres(
    connection: psycopg.Connection[Any],
) -> list[dict[str, Any]]:
    with connection.cursor(row_factory=dict_row) as cursor:
        cursor.execute(
            """
            SELECT
                c.name AS campaign_name,
                p.marketing_theme AS promotion_name,
                ae.ad_experiment_id,
                ae.segment_name,
                ae.loop_count,
                ae.parent_ad_experiment_id,
                ae.source_evaluation_id,
                preparation.activated_promotion_run_id AS next_promotion_run_id,
                count(usa.user_id)::int AS assignment_count,
                pe.status AS evaluation_status,
                pe.numerator_count,
                pe.denominator_count,
                pe.result_json #>> '{diagnosis,data_origin,kind}' AS data_origin
            FROM campaigns c
            JOIN promotions p
              ON p.project_id = c.project_id
             AND p.campaign_id = c.campaign_id
            JOIN ad_experiments ae
              ON ae.project_id = p.project_id
             AND ae.promotion_id = p.promotion_id
            JOIN promotion_evaluations pe
              ON pe.project_id = ae.project_id
             AND pe.ad_experiment_id = ae.ad_experiment_id
            LEFT JOIN user_segment_assignments usa
              ON usa.project_id = ae.project_id
             AND usa.promotion_run_id = ae.promotion_run_id
             AND usa.ad_experiment_id = ae.ad_experiment_id
            LEFT JOIN next_loop_preparations preparation
              ON preparation.source_promotion_run_id = ae.promotion_run_id
             AND preparation.status = 'activated'
            WHERE c.project_id = %s
              AND c.campaign_id = %s
              AND pe.evaluation_id = ANY(%s)
            GROUP BY
                c.name, p.marketing_theme, ae.ad_experiment_id,
                ae.segment_name, ae.loop_count, ae.parent_ad_experiment_id,
                ae.source_evaluation_id, preparation.activated_promotion_run_id,
                pe.status,
                pe.numerator_count, pe.denominator_count, pe.result_json,
                p.scheduled_start_at
            ORDER BY p.scheduled_start_at, ae.loop_count
            """,
            (
                PROJECT_ID,
                CAMPAIGN_ID,
                [scenario.evaluation_id for scenario in SCENARIOS],
            ),
        )
        return [dict(row) for row in cursor.fetchall()]


def _dashboard_url(scenario: Scenario) -> str:
    query = urlencode(
        {
            "createCampaign": "false",
            "selectedCampaignId": CAMPAIGN_ID,
            "selectedPromotionId": scenario.promotion_id,
            "segmentView": "experiments",
            "selectedSegmentId": scenario.segment_id,
            "selectedAdExperimentId": scenario.ad_experiment_id,
        }
    )
    return f"https://dashboard.dev.loop-ad.org/dashboard/{PROJECT_ID}/experiments?{query}"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Create a dedicated historical campaign with six repeat-experiment "
            "funnels in LoopAd local or AWS dev."
        )
    )
    parser.add_argument(
        "--target",
        choices=("aws-dev", "local"),
        default="aws-dev",
        help="database environment to inspect or seed (default: aws-dev)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform writes; without this flag the command only runs preflight",
    )
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    if args.target == "aws-dev":
        postgres_host, clickhouse_host, postgres_secret, clickhouse_secret = (
            _resolve_aws_dev()
        )
        postgres_port = 5432
        postgres_database = "loopad"
        clickhouse_port = 8123
        clickhouse_database = CLICKHOUSE_DATABASE
        postgres_sslmode = "require"
    else:
        (
            postgres_host,
            postgres_port,
            postgres_database,
            postgres_secret,
            clickhouse_host,
            clickhouse_port,
            clickhouse_database,
            clickhouse_secret,
        ) = _resolve_local()
        postgres_sslmode = "disable"

    postgres_connection = psycopg.connect(
        host=postgres_host,
        port=postgres_port,
        dbname=postgres_database,
        user=postgres_secret["username"],
        password=postgres_secret["password"],
        connect_timeout=10,
        sslmode=postgres_sslmode,
        autocommit=True,
    )
    clickhouse_client = clickhouse_connect.get_client(
        host=clickhouse_host,
        port=clickhouse_port,
        database=clickhouse_database,
        username=clickhouse_secret["username"],
        password=clickhouse_secret["password"],
    )
    try:
        write_key, campaign_exists = _preflight_project(postgres_connection)
        print(
            f"preflight campaign={CAMPAIGN_NAME!r} "
            f"existing={'yes' if campaign_exists else 'no'}"
        )
        for scenario in SCENARIOS:
            actual = Decimal(scenario.stage_counts[4]) / Decimal(
                scenario.stage_counts[0]
            )
            print(
                f"planned {scenario.promotion_name} loop={scenario.loop_count}: "
                f"funnel={scenario.stage_counts} "
                f"actual={actual * 100:.2f}% status={scenario.expected_status}"
            )
        if not args.apply:
            print(
                f"dry-run complete; rerun with --target {args.target} --apply "
                "to create the campaign"
            )
            return

        today = datetime.now(KST).date()
        with postgres_connection.transaction():
            experiments = _upsert_hierarchy(postgres_connection, today)

        rows = [
            row
            for scenario in SCENARIOS
            for row in _fixture_rows(
                scenario,
                experiments[scenario.ad_experiment_id],
                write_key,
            )
        ]
        _replace_clickhouse_fixture(clickhouse_client, rows)

        counts_by_scenario: dict[str, tuple[int, ...]] = {}
        for scenario in SCENARIOS:
            experiment = experiments[scenario.ad_experiment_id]
            cutoff = experiment["ended_at"] + timedelta(hours=1)
            counts = _load_funnel_counts(clickhouse_client, experiment, cutoff)
            if counts[:5] != scenario.stage_counts:
                raise RuntimeError(
                    f"{scenario.key} funnel mismatch: expected "
                    f"{scenario.stage_counts}, got {counts[:5]}"
                )
            counts_by_scenario[scenario.key] = counts

        with postgres_connection.transaction():
            for scenario in SCENARIOS:
                _upsert_evaluation(
                    postgres_connection,
                    scenario,
                    experiments[scenario.ad_experiment_id],
                    counts_by_scenario[scenario.key],
                )
            _upsert_repeat_lineage(postgres_connection, experiments)

        verified = _verify_postgres(postgres_connection)
        if len(verified) != len(SCENARIOS):
            raise RuntimeError(
                f"expected {len(SCENARIOS)} verified experiments, found {len(verified)}"
            )
        verified_by_experiment = {
            row["ad_experiment_id"]: row for row in verified
        }
        for scenario in SCENARIOS:
            row = verified_by_experiment[scenario.ad_experiment_id]
            if row["data_origin"] != "demo_fixture":
                raise RuntimeError(f"missing demo fixture marker: {row}")
            if row["loop_count"] != scenario.loop_count:
                raise RuntimeError(f"loop count mismatch: {row}")
            if row["assignment_count"] != scenario.stage_counts[0]:
                raise RuntimeError(f"assignment count mismatch: {row}")
            if row["evaluation_status"] != scenario.expected_status:
                raise RuntimeError(f"evaluation status mismatch: {row}")
            if (
                row["numerator_count"],
                row["denominator_count"],
            ) != (scenario.stage_counts[4], scenario.stage_counts[0]):
                raise RuntimeError(f"evaluation count mismatch: {row}")
            previous = _previous_scenario(scenario)
            expected_parent = None if previous is None else previous.ad_experiment_id
            expected_source = None if previous is None else previous.evaluation_id
            if row["parent_ad_experiment_id"] != expected_parent:
                raise RuntimeError(f"parent experiment mismatch: {row}")
            if row["source_evaluation_id"] != expected_source:
                raise RuntimeError(f"source evaluation mismatch: {row}")
            following = _next_scenario(scenario)
            expected_next_run = (
                None if following is None else following.promotion_run_id
            )
            if row["next_promotion_run_id"] != expected_next_run:
                raise RuntimeError(f"next promotion run mismatch: {row}")
            print(
                f"verified {row['promotion_name']} loop={row['loop_count']}: "
                f"assignments={row['assignment_count']} "
                f"result={row['numerator_count']}/{row['denominator_count']} "
                f"status={row['evaluation_status']}"
            )
        print(f"campaign_id={CAMPAIGN_ID}")
        print(f"dashboard_gangneung={_dashboard_url(GANGNEUNG_FAMILY_1)}")
        print(f"dashboard_yeosu={_dashboard_url(YEOSU_OCEANVIEW_1)}")
    finally:
        clickhouse_client.close()
        postgres_connection.close()


if __name__ == "__main__":
    main()
