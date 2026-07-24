#!/usr/bin/env python3
"""Seed the Jeju/Okinawa high-nightly-price abandonment demo scenario."""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime, timedelta
from typing import Any

import clickhouse_connect
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from seed_demo_historical_campaign import (
    CLICKHOUSE_DATABASE,
    _resolve_aws_dev,
    _resolve_local,
)


PROJECT_ID = "demo_project"
CAMPAIGN_ID = "camp_7ac4b858-b251-4efe-81c6-aae8350be0ff"
PROMOTION_ID = "promo_demo_jeju_okinawa_summer_intent"
FIXTURE_ID = "demo_jeju_high_price_abandonment_v1"
FIXTURE_EVENT_PREFIX = "evt_demo_jeju_high_price_abandonment_v1_"
TARGET_USER_COUNT = 103
NIGHTLY_PRICE_THRESHOLD = 200_000

PROMOTION_OFFERS = (
    ("jeju-ocean-breeze-006", "jeju", 278_000),
    ("jeju-aewol-sunset-007", "jeju", 214_000),
    ("okinawa-naha-terrace-017", "okinawa", 232_000),
    ("okinawa-chatan-sunset-018", "okinawa", 318_000),
)

EXPERIMENT_ANALYSES = {
    "adexp_demo_jeju_okinawa_summer_intent": {
        "booking_start_user_count": 48,
        "booking_abandon_user_count": 35,
        "booking_complete_user_count": 13,
        "booking_abandon_median_nightly_price": 278_000,
        "booking_complete_median_nightly_price": 196_000,
    },
    "adexp_demo_jeju_okinawa_summer_intent_loop_2": {
        "booking_start_user_count": 142,
        "booking_abandon_user_count": 103,
        "booking_complete_user_count": 39,
        "booking_abandon_median_nightly_price": 278_000,
        "booking_complete_median_nightly_price": 196_000,
    },
}


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Seed exactly 103 active-vector users for the Jeju/Okinawa "
            "seven-day high-nightly-price booking-abandonment demo."
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


def _connect(args: argparse.Namespace) -> tuple[Any, Any]:
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
    return postgres_connection, clickhouse_client


def _load_context(
    connection: Any,
) -> tuple[str, list[str], tuple[tuple[str, str, int], ...]]:
    with connection.cursor(row_factory=dict_row) as cursor:
        cursor.execute(
            """
            SELECT project.write_key, promotion.metadata_json
            FROM projects AS project
            JOIN campaigns AS campaign
              ON campaign.project_id = project.project_id
            JOIN promotions AS promotion
              ON promotion.project_id = campaign.project_id
             AND promotion.campaign_id = campaign.campaign_id
            WHERE project.project_id = %s
              AND campaign.campaign_id = %s
              AND promotion.promotion_id = %s
            """,
            (PROJECT_ID, CAMPAIGN_ID, PROMOTION_ID),
        )
        project = cursor.fetchone()
        if project is None:
            raise RuntimeError("required demo campaign and promotion are missing")

        offer_links = (project["metadata_json"] or {}).get("offer_links") or []
        selected_offer_ids = {
            str(link.get("offer_id") or "").strip()
            for link in offer_links
            if isinstance(link, dict) and str(link.get("offer_id") or "").strip()
        }
        known_offer_ids = {offer_id for offer_id, _, _ in PROMOTION_OFFERS}
        unknown_offer_ids = selected_offer_ids - known_offer_ids
        if unknown_offer_ids:
            raise RuntimeError(
                "selected promotion offers are missing from the demo price catalog: "
                f"{sorted(unknown_offer_ids)}"
            )
        selected_offers = tuple(
            offer for offer in PROMOTION_OFFERS if offer[0] in selected_offer_ids
        )
        if not selected_offers:
            raise RuntimeError(
                "the demo promotion must select at least one high-price offer"
            )

        cursor.execute(
            """
            SELECT search.user_id
            FROM user_behavior_vector_search_generations AS generation
            JOIN user_behavior_vector_search AS search
              ON search.vector_generation_id = generation.vector_generation_id
            WHERE generation.project_id = %s
              AND generation.status = 'activated'
              AND generation.is_active = true
            ORDER BY md5(search.user_id)
            """,
            (PROJECT_ID,),
        )
        active_user_ids = [str(row["user_id"]) for row in cursor.fetchall()]
    if len(active_user_ids) < TARGET_USER_COUNT:
        raise RuntimeError(
            f"active vector generation has only {len(active_user_ids)} users"
        )
    return str(project["write_key"]), active_user_ids, selected_offers


def _target_users(
    client: Any,
    *,
    promotion_offers: tuple[tuple[str, str, int], ...],
    window_start: datetime,
    window_end: datetime,
) -> set[str]:
    result = client.query(
        """
        SELECT user_id
        FROM funnel_step_events
        WHERE project_id = {project_id:String}
          AND event_time >= {window_start:DateTime64(3, 'UTC')}
          AND event_time < {window_end:DateTime64(3, 'UTC')}
          AND notEmpty(user_id)
        GROUP BY user_id
        HAVING countIf(
                   event_name = 'page_view'
                   AND lowerUTF8(ifNull(
                       JSONExtractString(properties_json, 'age_group'), ''
                   )) IN ('20대', '30대')
               ) >= 1
           AND countIf(
                   event_name = 'booking_start'
                   AND lowerUTF8(ifNull(
                       JSONExtractString(properties_json, 'destination_id'), ''
                   )) IN ('jeju', 'okinawa')
                   AND ifNull(
                       JSONExtractString(properties_json, 'hotel_id'), ''
                   ) IN {offer_ids:Array(String)}
                   AND toFloat64OrNull(nullIf(
                       JSONExtractString(properties_json, 'price'), ''
                   )) > {price_threshold:Float64}
               ) >= 1
           AND countIf(
                   event_name = 'booking_complete'
                   AND lowerUTF8(ifNull(
                       JSONExtractString(properties_json, 'destination_id'), ''
                   )) IN ('jeju', 'okinawa')
                   AND ifNull(
                       JSONExtractString(properties_json, 'hotel_id'), ''
                   ) IN {offer_ids:Array(String)}
               ) = 0
        """,
        parameters={
            "project_id": PROJECT_ID,
            "window_start": window_start,
            "window_end": window_end,
            "offer_ids": [offer_id for offer_id, _, _ in promotion_offers],
            "price_threshold": float(NIGHTLY_PRICE_THRESHOLD),
        },
    )
    return {str(row[0]) for row in result.result_rows}


def _blocked_users(
    client: Any,
    *,
    active_user_ids: list[str],
    promotion_offers: tuple[tuple[str, str, int], ...],
    window_start: datetime,
    window_end: datetime,
) -> set[str]:
    result = client.query(
        """
        SELECT DISTINCT user_id
        FROM funnel_step_events
        WHERE project_id = {project_id:String}
          AND user_id IN {active_user_ids:Array(String)}
          AND event_name = 'booking_complete'
          AND event_time >= {window_start:DateTime64(3, 'UTC')}
          AND event_time < {window_end:DateTime64(3, 'UTC')}
          AND lowerUTF8(ifNull(
              JSONExtractString(properties_json, 'destination_id'), ''
          )) IN ('jeju', 'okinawa')
          AND ifNull(
              JSONExtractString(properties_json, 'hotel_id'), ''
          ) IN {offer_ids:Array(String)}
        """,
        parameters={
            "project_id": PROJECT_ID,
            "active_user_ids": active_user_ids,
            "window_start": window_start,
            "window_end": window_end,
            "offer_ids": [offer_id for offer_id, _, _ in promotion_offers],
        },
    )
    return {str(row[0]) for row in result.result_rows}


def _delete_fixture(client: Any) -> None:
    client.command(
        """
        ALTER TABLE raw_events
        DELETE WHERE project_id = {project_id:String}
          AND source = 'fixture'
          AND startsWith(event_id, {event_prefix:String})
        SETTINGS mutations_sync = 1
        """,
        parameters={
            "project_id": PROJECT_ID,
            "event_prefix": FIXTURE_EVENT_PREFIX,
        },
    )


def _fixture_rows(
    *,
    user_ids: list[str],
    write_key: str,
    event_time: datetime,
    promotion_offers: tuple[tuple[str, str, int], ...],
) -> list[list[Any]]:
    rows: list[list[Any]] = []
    for index, user_id in enumerate(user_ids):
        session_id = f"session_demo_jeju_high_price_{index:03d}"
        rows.append(
            [
                PROJECT_ID,
                write_key,
                "hotel_rec_promo.v1",
                f"{FIXTURE_EVENT_PREFIX}{index:03d}_profile",
                "page_view",
                event_time + timedelta(seconds=index),
                "fixture",
                user_id,
                session_id,
                json.dumps(
                    {
                        "campaign_id": CAMPAIGN_ID,
                        "promotion_id": PROMOTION_ID,
                        "fixture_id": FIXTURE_ID,
                        "age_group": "20대" if index % 2 == 0 else "30대",
                        "page_path": "/profile",
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
                "valid",
            ]
        )
        for offer_index, (offer_id, destination_id, nightly_price) in enumerate(
            promotion_offers
        ):
            rows.append(
                [
                    PROJECT_ID,
                    write_key,
                    "hotel_rec_promo.v1",
                    (
                        f"{FIXTURE_EVENT_PREFIX}{index:03d}_booking_start_"
                        f"{offer_index:02d}"
                    ),
                    "booking_start",
                    event_time
                    + timedelta(minutes=5 + offer_index, seconds=index),
                    "fixture",
                    user_id,
                    session_id,
                    json.dumps(
                        {
                            "campaign_id": CAMPAIGN_ID,
                            "promotion_id": PROMOTION_ID,
                            "hotel_id": offer_id,
                            "destination_id": destination_id,
                            "fixture_id": FIXTURE_ID,
                            "booking_id": (
                                f"booking_demo_jeju_high_price_{index:03d}_"
                                f"{offer_index:02d}"
                            ),
                            "price": str(nightly_price),
                            "currency": "KRW",
                        },
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ),
                    "valid",
                ]
            )
    return rows


def _price_analysis(ad_experiment_id: str) -> dict[str, Any]:
    counts = EXPERIMENT_ANALYSES[ad_experiment_id]
    abandon_count = counts["booking_abandon_user_count"]
    start_count = counts["booking_start_user_count"]
    return {
        "version": "dec.price-abandonment-analysis.v1",
        "title": "높은 1박 가격이 예약 완료에 부담이 되었을 가능성이 있습니다",
        "paragraphs": [
            (
                f"1박 프로모션 가격이 20만 원을 초과한 숙소에서 예약을 시작한 "
                f"{start_count}명 중 {abandon_count}명이 예약을 완료하지 않았습니다."
            ),
            (
                "예약 이탈 고객이 확인한 1박 가격 중앙값이 예약 완료 고객보다 "
                "높아, 가격이 최종 결정에 부담이 되었을 가능성이 있습니다."
            ),
            (
                "이는 관측된 행동 차이이며 직접 원인으로 확정하지 않습니다. "
                "다음 실험에서 고가 숙소 예약 이탈 고객에게 추가 할인과 "
                "최종 가격을 명확히 제시해 가설을 검증합니다."
            ),
        ],
        "price_abandonment": {
            "currency": "KRW",
            "nightly_price_threshold": NIGHTLY_PRICE_THRESHOLD,
            **counts,
        },
        "next_segment_hypothesis": {
            "lookback_days": 7,
            "condition_labels": [
                "20·30대",
                "최근 7일 제주·오키나와 프로모션 숙소 1박 20만 원 초과",
                "예약 시작 후 미완료",
            ],
            "validation_note": (
                "관측된 가격과 이탈의 연관성을 바탕으로 만든 다음 실험 가설이며 "
                "성공을 보장하지 않습니다."
            ),
        },
    }


def _update_evaluations(connection: Any) -> None:
    with connection.cursor(row_factory=dict_row) as cursor:
        cursor.execute(
            """
            SELECT evaluation_id, ad_experiment_id, result_json
            FROM promotion_evaluations
            WHERE project_id = %s
              AND promotion_id = %s
              AND ad_experiment_id = ANY(%s)
            FOR UPDATE
            """,
            (
                PROJECT_ID,
                PROMOTION_ID,
                list(EXPERIMENT_ANALYSES),
            ),
        )
        evaluations = cursor.fetchall()
        found = {str(row["ad_experiment_id"]) for row in evaluations}
        missing = sorted(set(EXPERIMENT_ANALYSES) - found)
        if missing:
            raise RuntimeError(f"required demo evaluations are missing: {missing}")

        for row in evaluations:
            result_json = dict(row["result_json"] or {})
            diagnosis = dict(result_json.get("diagnosis") or {})
            diagnosis.pop("audience_intent_analysis", None)
            diagnosis["price_abandonment_analysis"] = _price_analysis(
                str(row["ad_experiment_id"])
            )
            result_json["diagnosis"] = diagnosis
            cursor.execute(
                """
                UPDATE promotion_evaluations
                SET result_json = %s
                WHERE evaluation_id = %s
                """,
                (Jsonb(result_json), row["evaluation_id"]),
            )


def main() -> None:
    args = _parse_args()
    postgres_connection, clickhouse_client = _connect(args)
    try:
        write_key, active_user_ids, promotion_offers = _load_context(
            postgres_connection
        )
        window_end = datetime.now(UTC)
        window_start = window_end - timedelta(days=7)
        selected_offer_users = _target_users(
            clickhouse_client,
            promotion_offers=promotion_offers,
            window_start=window_start,
            window_end=window_end,
        )
        all_demo_offer_users = _target_users(
            clickhouse_client,
            promotion_offers=PROMOTION_OFFERS,
            window_start=window_start,
            window_end=window_end,
        )
        print(
            f"preflight target={args.target} active_vector_users={len(active_user_ids)} "
            f"promotion_offers={len(promotion_offers)} "
            f"selected_offer_users={len(selected_offer_users)} "
            f"all_demo_offer_users={len(all_demo_offer_users)} "
            f"target_users={TARGET_USER_COUNT}"
        )
        if not args.apply:
            print(
                f"dry-run complete; rerun with --target {args.target} --apply "
                "to seed the scenario"
            )
            return

        _delete_fixture(clickhouse_client)
        existing_target_users = _target_users(
            clickhouse_client,
            promotion_offers=promotion_offers,
            window_start=window_start,
            window_end=window_end,
        )
        inactive_existing = existing_target_users - set(active_user_ids)
        if inactive_existing:
            raise RuntimeError(
                "target query already contains users outside the active vector "
                f"generation: {len(inactive_existing)}"
            )
        if len(existing_target_users) > TARGET_USER_COUNT:
            raise RuntimeError(
                f"target query already returns {len(existing_target_users)} users"
            )

        blocked_user_ids = _blocked_users(
            clickhouse_client,
            active_user_ids=active_user_ids,
            promotion_offers=PROMOTION_OFFERS,
            window_start=window_start,
            window_end=window_end,
        )
        needed = TARGET_USER_COUNT - len(existing_target_users)
        fixture_user_ids = [
            user_id
            for user_id in active_user_ids
            if user_id not in existing_target_users and user_id not in blocked_user_ids
        ][:needed]
        if len(fixture_user_ids) != needed:
            raise RuntimeError(
                f"only {len(fixture_user_ids)} eligible active users are available; "
                f"{needed} are required"
            )

        rows = _fixture_rows(
            user_ids=fixture_user_ids,
            write_key=write_key,
            event_time=window_end - timedelta(days=1),
            promotion_offers=PROMOTION_OFFERS,
        )
        if rows:
            clickhouse_client.insert(
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

        verified_users = _target_users(
            clickhouse_client,
            promotion_offers=promotion_offers,
            window_start=window_start,
            window_end=window_end,
        )
        if len(verified_users) != TARGET_USER_COUNT:
            raise RuntimeError(
                f"expected {TARGET_USER_COUNT} target users, found {len(verified_users)}"
            )
        if not verified_users.issubset(set(active_user_ids)):
            raise RuntimeError("verified users are not all in the active vector generation")

        with postgres_connection.transaction():
            _update_evaluations(postgres_connection)

        print(
            f"seeded target_users={len(verified_users)} "
            f"fixture_users={len(fixture_user_ids)} "
            "evaluation_analyses=2"
        )
    finally:
        clickhouse_client.close()
        postgres_connection.close()


if __name__ == "__main__":
    main()
