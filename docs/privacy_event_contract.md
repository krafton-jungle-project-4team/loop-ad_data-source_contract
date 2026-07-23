# Privacy Event Envelope v2

이 문서는 고객사 내부의 원본 고객 식별자를 LoopAd 클라우드로 보내지 않는
실험용 이벤트 계약을 정의합니다. 현재 운영 `hotel_rec_promo.v1` 계약을 대체하거나
운영 데이터베이스 스키마를 변경하지 않습니다.

## 데이터 경계

고객사 내부 Connector가 원본 식별자를 다음 규칙으로 가명처리합니다.

```text
subject_id =
  "sub_" + hex(
    HMAC-SHA256(
      customer_secret,
      identity_namespace + "\x00" + external_user_id
    )
  )
```

- `customer_secret`과 `external_user_id`는 고객사 환경을 벗어나지 않습니다.
- 브라우저 SDK는 HMAC 키를 보관하거나 원본 ID를 가명처리하지 않습니다.
- LoopAd에는 `subject_id`, namespace, 키 버전과 동의 증적만 전달합니다.
- 키 교체 시 `identity_key_version`을 변경합니다. 서로 다른 키 버전의 ID 연결은
  고객사 내부에서만 수행합니다.

## 동의 계약

수집 시점에 `consent.status=granted`, 정책 버전과 목적 ID를 함께 기록합니다.
동의가 없거나 철회된 이벤트는 Connector가 전송 전에 차단해야 합니다.

## 금지 필드

Envelope와 중첩 `properties` 어디에도 다음 계열의 필드를 포함하지 않습니다.

```text
user_id, external_user_id, email, phone, name, address, birth_date,
password, card_number, account_number, resident_registration_number
```

Collector도 동일한 denylist를 재귀적으로 검사합니다. 이 검사는 법률 준수를
자동으로 보장하는 장치가 아니라, 원본 개인정보의 우발적 전송을 막는 방어선입니다.

## 전송 경로

PoC 경로는 `POST /private/v2/events`이며 고객사 Connector의 server-to-server
요청만 받습니다. 프로젝트별 Bearer token은 런타임에 명시적으로 제공되어야 하며,
설정하지 않으면 해당 경로만 비활성화됩니다. 기존 브라우저 수집 경로는 그대로
유지됩니다.
