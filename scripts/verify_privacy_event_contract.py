#!/usr/bin/env python3
"""Privacy Event Envelope v2의 핵심 불변식을 외부 패키지 없이 검증한다."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "contracts" / "privacy-event-envelope.v2.schema.json"
EXAMPLE_PATH = ROOT / "contracts" / "examples" / "privacy-event.v2.json"
SUBJECT_PATTERN = re.compile(r"^sub_[0-9a-f]{64}$")
FORBIDDEN_KEYS = {
    "user_id",
    "external_user_id",
    "email",
    "phone",
    "name",
    "address",
    "birth_date",
    "password",
    "card_number",
    "account_number",
    "resident_registration_number",
}


def walk_keys(value: object) -> set[str]:
    if isinstance(value, dict):
        keys = set(value)
        for child in value.values():
            keys.update(walk_keys(child))
        return keys
    if isinstance(value, list):
        keys: set[str] = set()
        for child in value:
            keys.update(walk_keys(child))
        return keys
    return set()


def main() -> None:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    example = json.loads(EXAMPLE_PATH.read_text(encoding="utf-8"))

    missing = set(schema["required"]) - set(example)
    if missing:
        raise SystemExit(f"example is missing required fields: {sorted(missing)}")
    if set(example) - set(schema["properties"]):
        raise SystemExit("example contains a field outside the canonical envelope")
    if example["envelope_version"] != "privacy-event.v2":
        raise SystemExit("invalid envelope_version")
    if not SUBJECT_PATTERN.fullmatch(example["subject_id"]):
        raise SystemExit("subject_id must be a sub_ prefixed SHA-256 digest")
    if example["consent"]["status"] != "granted":
        raise SystemExit("example consent must be granted")

    leaked = FORBIDDEN_KEYS & walk_keys(example)
    if leaked:
        raise SystemExit(f"example contains forbidden keys: {sorted(leaked)}")

    print("privacy event contract: ok")


if __name__ == "__main__":
    main()
