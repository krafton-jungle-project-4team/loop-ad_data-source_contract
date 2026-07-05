# Promotion Segment Suggestion Schema Guide

## Purpose

이 문서는 프로모션별 AI 세그먼트 추천/제안 플로우를 위해 PostgreSQL schema를 어떻게 조정해야 하는지, 그리고 각 파트가 어떤 테이블을 조회/저장해야 하는지 정리한다.

기준 schema는 `loop-ad_data-source_contract`의 최신 PostgreSQL schema이다.

- Source of truth: https://github.com/krafton-jungle-project-4team/loop-ad_data-source_contract
- Service repo는 `schema.sql`, migration, seed를 직접 소유하지 않는다.

## Current Confusion

현재 `segment_definitions`에는 `promotion_id`가 없다. 기존 의도는 `segment_definitions`를 특정 promotion의 결과가 아니라 project-level 세그먼트 정의 라이브러리로 보는 것이었다.

```text
segment_definitions
= 프로젝트 안에서 재사용 가능한 세그먼트 정의 목록
= custom_chatkit, manual_rule, system_default, ai_suggested 정의를 저장
```

하지만 우리가 원하는 UX는 아래와 다르다.

```text
1. AI가 특정 promotion을 보고 세그먼트 후보를 최대 4개 추천한다.
2. Dashboard 사용자가 AI 추천 후보를 보고 일부를 삭제하거나 유지한다.
3. 사용자가 필요하면 ChatKit 또는 manual_rule로 세그먼트를 추가한다.
4. 사용자가 확정/확인 버튼을 누른다.
5. 그때서야 해당 promotion의 최종 target segment가 결정된다.
```

이 플로우에서는 아래 세 개의 개념을 분리해야 한다.

```text
Segment Definition
= 세그먼트 자체의 정의

Segment Suggestion
= AI가 특정 promotion/analysis에 대해 제안한 후보

Promotion Target Segment
= 사용자가 최종 확정한 promotion 대상 세그먼트
```

## Recommended Schema Change

### 1. `segment_definitions`에 promotion scope 추가

AI가 특정 promotion을 보고 새 후보를 만든 경우, 그 후보가 어느 promotion을 위해 만들어졌는지 추적할 수 있어야 한다.

```sql
ALTER TABLE segment_definitions
ADD COLUMN campaign_id VARCHAR(100),
ADD COLUMN promotion_id VARCHAR(100);

ALTER TABLE segment_definitions
ADD CONSTRAINT fk_segment_definitions_campaign
FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id);

ALTER TABLE segment_definitions
ADD CONSTRAINT fk_segment_definitions_promotion
FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id);

CREATE INDEX IF NOT EXISTS idx_segment_definitions_campaign_id
ON segment_definitions (campaign_id);

CREATE INDEX IF NOT EXISTS idx_segment_definitions_promotion_id
ON segment_definitions (promotion_id);
```

의미:

```text
promotion_id IS NULL
= project-level reusable segment

promotion_id IS NOT NULL
= 특정 promotion용으로 생성/추가된 segment
```

예시:

```text
source = 'ai_suggested'
promotion_id = 'promo_banner_001'
=> AI가 promo_banner_001을 위해 만든 추천 후보 정의

source = 'manual_rule'
promotion_id = 'promo_banner_001'
=> 사용자가 promo_banner_001 편집 중 직접 추가한 세그먼트 정의

source = 'custom_chatkit'
promotion_id IS NULL
=> 여러 promotion에서 재사용 가능한 사용자 세그먼트 정의
```

주의: `promotion_id`를 추가해도 추천 후보의 삭제/채택/순위 상태까지 표현하기에는 부족하다. 이를 위해 별도 suggestion table이 필요하다.

### 2. `promotion_segment_suggestions` 테이블 추가

이 테이블은 AI가 특정 promotion analysis에서 제안한 후보 목록을 저장한다. 아직 최종 확정된 target segment가 아니다.

```sql
CREATE TABLE IF NOT EXISTS promotion_segment_suggestions (
    suggestion_id VARCHAR(100) PRIMARY KEY,

    analysis_id VARCHAR(100) NOT NULL,
    project_id VARCHAR(100) NOT NULL,
    campaign_id VARCHAR(100) NOT NULL,
    promotion_id VARCHAR(100) NOT NULL,
    segment_id VARCHAR(100) NOT NULL,

    suggested_rank INT NOT NULL,
    suggestion_source VARCHAR(50) NOT NULL DEFAULT 'ai_generated',
    status VARCHAR(50) NOT NULL DEFAULT 'suggested',

    score_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    reason_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_at TIMESTAMPTZ,

    CONSTRAINT fk_promotion_segment_suggestions_analysis
        FOREIGN KEY (analysis_id) REFERENCES promotion_analyses (analysis_id),

    CONSTRAINT fk_promotion_segment_suggestions_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id),

    CONSTRAINT fk_promotion_segment_suggestions_campaign
        FOREIGN KEY (campaign_id) REFERENCES campaigns (campaign_id),

    CONSTRAINT fk_promotion_segment_suggestions_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id),

    CONSTRAINT fk_promotion_segment_suggestions_segment
        FOREIGN KEY (segment_id) REFERENCES segment_definitions (segment_id),

    CONSTRAINT chk_promotion_segment_suggestions_source
        CHECK (suggestion_source IN (
            'ai_generated',
            'ai_ranked_existing'
        )),

    CONSTRAINT chk_promotion_segment_suggestions_status
        CHECK (status IN (
            'suggested',
            'accepted',
            'dismissed',
            'confirmed'
        )),

    CONSTRAINT chk_promotion_segment_suggestions_rank
        CHECK (suggested_rank >= 1),

    CONSTRAINT uq_promotion_segment_suggestions_analysis_segment
        UNIQUE (analysis_id, segment_id)
);

CREATE INDEX IF NOT EXISTS idx_promotion_segment_suggestions_analysis_id
ON promotion_segment_suggestions (analysis_id);

CREATE INDEX IF NOT EXISTS idx_promotion_segment_suggestions_promotion_id
ON promotion_segment_suggestions (promotion_id);

CREATE INDEX IF NOT EXISTS idx_promotion_segment_suggestions_status
ON promotion_segment_suggestions (status);
```

상태 의미:

```text
suggested
= AI가 추천했고 아직 사용자가 판단하지 않음

accepted
= 사용자가 추천 후보를 유지하기로 선택함

dismissed
= 사용자가 추천 후보를 삭제함

confirmed
= 최종 확정되어 promotion_target_segments에 반영됨
```

### 3. `promotion_target_segments`는 최종 확정본으로 사용

`promotion_target_segments`는 더 이상 "AI가 일단 추천한 후보"를 담는 테이블이 아니다. 사용자가 확정/확인 버튼을 누른 뒤 최종 선택된 세그먼트만 저장한다.

선택적으로 아래 컬럼을 추가하면 추적성이 좋아진다.

```sql
ALTER TABLE promotion_target_segments
ADD COLUMN suggestion_id VARCHAR(100),
ADD COLUMN confirmed_by VARCHAR(100),
ADD COLUMN confirmed_at TIMESTAMPTZ;

ALTER TABLE promotion_target_segments
ADD CONSTRAINT fk_promotion_target_segments_suggestion
FOREIGN KEY (suggestion_id)
REFERENCES promotion_segment_suggestions (suggestion_id);

CREATE INDEX IF NOT EXISTS idx_promotion_target_segments_suggestion_id
ON promotion_target_segments (suggestion_id);
```

의미:

```text
suggestion_id IS NOT NULL
= AI 추천 후보에서 채택된 최종 세그먼트

suggestion_id IS NULL
= 사용자가 ChatKit/manual_rule 등으로 추가한 뒤 최종 확정한 세그먼트
```

## End-to-End Flow

### Step 1. AI analysis creates suggestions

Owner: Decision Analysis

해야 할 일:

```text
1. promotion 조회
2. user_behavior_vectors 기반 군집화
3. AI 추천 후보 segment_definitions 저장
4. promotion_segment_suggestions 저장
5. promotion_analyses 저장
```

이 단계에서는 `promotion_target_segments`에 최종 row를 쓰지 않는다.

저장 예시:

```text
segment_definitions
- segment_id = seg_ai_cluster_promo_banner_001_1_xxxxxx
- source = ai_suggested
- project_id = hotel-client-a
- campaign_id = camp_summer_2026
- promotion_id = promo_banner_001
- rule_json = user_vector_clustering 정보
- profile_json = cluster_score, centroid summary 등

promotion_segment_suggestions
- suggestion_id = sugg_analysis_banner_001_001
- analysis_id = analysis_banner_001
- promotion_id = promo_banner_001
- segment_id = seg_ai_cluster_promo_banner_001_1_xxxxxx
- suggested_rank = 1
- status = suggested
- score_json = cluster_score, sample_size 등
- reason_json = 추천 근거
```

### Step 2. Dashboard displays AI suggestions

Owner: Dashboard

Dashboard는 AI 추천 목록을 `promotion_segment_suggestions` 기준으로 조회한다.

```sql
SELECT
    pss.suggestion_id,
    pss.analysis_id,
    pss.promotion_id,
    pss.segment_id,
    pss.suggested_rank,
    pss.status AS suggestion_status,
    pss.score_json,
    pss.reason_json,
    sd.segment_name,
    sd.source AS segment_source,
    sd.rule_json,
    sd.profile_json,
    sd.sample_size,
    sd.sample_ratio
FROM promotion_segment_suggestions pss
JOIN segment_definitions sd
  ON sd.segment_id = pss.segment_id
WHERE pss.analysis_id = :analysis_id
  AND pss.promotion_id = :promotion_id
  AND pss.status IN ('suggested', 'accepted')
ORDER BY pss.suggested_rank ASC;
```

주의:

```text
AI 추천 후보 화면
= promotion_target_segments를 조회하지 않는다.

promotion_target_segments
= 사용자가 최종 확정한 뒤 조회한다.
```

### Step 3. User dismisses or accepts AI suggestions

Owner: Dashboard

사용자가 추천 후보를 삭제하면 row를 삭제하지 않고 상태만 바꾼다.

```sql
UPDATE promotion_segment_suggestions
SET status = 'dismissed',
    decided_at = now(),
    updated_at = now()
WHERE suggestion_id = :suggestion_id;
```

사용자가 추천 후보를 유지하면:

```sql
UPDATE promotion_segment_suggestions
SET status = 'accepted',
    decided_at = now(),
    updated_at = now()
WHERE suggestion_id = :suggestion_id;
```

### Step 4. User adds custom segments

Owner: Dashboard

사용자가 ChatKit 또는 manual_rule로 세그먼트를 추가하면 `segment_definitions`에 저장한다.

```sql
INSERT INTO segment_definitions (
    segment_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_name,
    source,
    query_preview_id,
    natural_language_query,
    generated_sql,
    rule_json,
    profile_json,
    sample_size,
    total_eligible_user_count,
    sample_ratio,
    status
)
VALUES (
    :segment_id,
    :project_id,
    :campaign_id,
    :promotion_id,
    :segment_name,
    'manual_rule',
    NULL,
    :natural_language_query,
    NULL,
    :rule_json,
    :profile_json,
    :sample_size,
    :total_eligible_user_count,
    :sample_ratio,
    'active'
);
```

이 row는 AI suggestion이 아니므로 `promotion_segment_suggestions`에 반드시 들어갈 필요는 없다. 최종 확정 시 `promotion_target_segments`에 들어간다.

### Step 5. User confirms final segments

Owner: Dashboard + Decision boundary decision required

확정 버튼 이후 최종 선택된 세그먼트만 `promotion_target_segments`에 저장한다.

권장 방식:

```text
1. Dashboard가 accepted suggestion과 직접 추가한 segment_id 목록을 확정한다.
2. Decision 쪽 confirm action 또는 service가 promotion_target_segments와 segment_vectors를 생성한다.
```

API를 새로 만들지 않고 Dashboard가 DB에 직접 쓰는 방식으로 간다면, Dashboard가 아래를 보장해야 한다.

```text
1. dismissed suggestion은 promotion_target_segments에 넣지 않는다.
2. accepted suggestion은 promotion_target_segments에 넣는다.
3. 사용자가 추가한 custom/manual segment도 promotion_target_segments에 넣는다.
4. segment_vector_id가 없을 수 있으므로, Decision이 이후 vector를 생성/보강할 수 있어야 한다.
```

최종 저장 예시:

```sql
INSERT INTO promotion_target_segments (
    analysis_id,
    project_id,
    campaign_id,
    promotion_id,
    segment_id,
    segment_name,
    segment_vector_id,
    rule_json,
    profile_json,
    content_brief_json,
    data_evidence_json,
    estimated_size,
    priority,
    status,
    suggestion_id,
    confirmed_by,
    confirmed_at
)
SELECT
    :analysis_id,
    sd.project_id,
    :campaign_id,
    :promotion_id,
    sd.segment_id,
    sd.segment_name,
    NULL,
    sd.rule_json,
    sd.profile_json,
    :content_brief_json,
    :data_evidence_json,
    sd.sample_size,
    :priority,
    'planned',
    :suggestion_id,
    :confirmed_by,
    now()
FROM segment_definitions sd
WHERE sd.segment_id = :segment_id;
```

## Part-by-Part Read/Write Guide

### Analysis

Owner: Decision analysis

Reads:

```text
promotions
segment_definitions
ClickHouse user_behavior_vectors
ClickHouse hotel profiles/events
```

Writes:

```text
promotion_analyses
segment_definitions source='ai_suggested'
promotion_segment_suggestions
segment_vectors optional/precomputed
```

Should not write at suggestion stage:

```text
promotion_target_segments
```

`promotion_target_segments` should be written only after user confirmation.

### Dashboard

Owner: Dashboard

AI recommendation list query:

```text
promotion_segment_suggestions JOIN segment_definitions
```

User-created segment save:

```text
segment_definitions source='custom_chatkit' or 'manual_rule'
```

User dismiss/accept:

```text
UPDATE promotion_segment_suggestions.status
```

Final confirmed list:

```text
promotion_target_segments
```

### Generation

Owner: Content generation

Generation must not read `promotion_segment_suggestions` as final input.

Reads:

```text
promotion_target_segments
segment_definitions
promotions
```

Meaning:

```text
promotion_target_segments exists
= user confirmed final segments

promotion_segment_suggestions exists only
= still proposal stage, generation should wait
```

### Promotion Run / Ad Experiment

Owner: Run/experiment

Reads:

```text
promotion_target_segments
content_candidates
generation_runs
```

Writes:

```text
promotion_runs
ad_experiments
```

Rule:

```text
Only confirmed promotion_target_segments can become ad_experiments.
```

### Segment Assignment

Owner: Segment assignment

Reads:

```text
promotion_runs
ad_experiments
promotion_target_segments
segment_vectors
ClickHouse user_behavior_vectors
```

Rule:

```text
Do not assign users to promotion_segment_suggestions.
Assign users only to confirmed ad_experiments generated from promotion_target_segments.
```

### Evaluation / Next Loop

Owner: Evaluation / next-loop

Reads:

```text
promotion_runs
ad_experiments
promotion_evaluations
promotion_target_segments
```

Rule:

```text
Evaluation and next-loop operate on confirmed experiment rows, not raw suggestions.
```

## Query Cheatsheet

### Latest completed analysis for a promotion

```sql
SELECT analysis_id
FROM promotion_analyses
WHERE promotion_id = :promotion_id
  AND status = 'completed'
ORDER BY created_at DESC
LIMIT 1;
```

### AI suggestions to show on Dashboard

```sql
SELECT
    pss.suggestion_id,
    pss.suggested_rank,
    pss.status,
    pss.score_json,
    pss.reason_json,
    sd.segment_id,
    sd.segment_name,
    sd.source,
    sd.sample_size,
    sd.sample_ratio,
    sd.profile_json
FROM promotion_segment_suggestions pss
JOIN segment_definitions sd
  ON sd.segment_id = pss.segment_id
WHERE pss.analysis_id = :analysis_id
  AND pss.promotion_id = :promotion_id
ORDER BY pss.suggested_rank ASC;
```

### Final confirmed target segments

```sql
SELECT
    pts.id,
    pts.analysis_id,
    pts.promotion_id,
    pts.segment_id,
    pts.segment_name,
    pts.priority,
    pts.status,
    pts.estimated_size,
    pts.content_brief_json,
    pts.data_evidence_json,
    pts.suggestion_id,
    sd.source AS segment_source
FROM promotion_target_segments pts
JOIN segment_definitions sd
  ON sd.segment_id = pts.segment_id
WHERE pts.analysis_id = :analysis_id
  AND pts.promotion_id = :promotion_id
ORDER BY pts.id ASC;
```

## Migration Impact Summary

### Data Source Contract

Required:

```text
1. segment_definitions에 campaign_id, promotion_id nullable 컬럼 추가
2. promotion_segment_suggestions 테이블 추가
3. promotion_target_segments에 suggestion_id, confirmed_by, confirmed_at 추가 여부 결정
```

### Decision Analysis

Required:

```text
1. Analysis service가 promotion_target_segments를 즉시 쓰지 않도록 변경
2. AI cluster candidates를 segment_definitions에 저장
3. AI proposals를 promotion_segment_suggestions에 저장
4. response/contract test를 proposal 중심으로 변경
```

### Dashboard

Required:

```text
1. AI 추천 목록은 promotion_segment_suggestions에서 조회
2. 사용자의 삭제/유지 선택은 suggestion status update
3. 사용자가 추가한 세그먼트는 segment_definitions에 저장
4. 확정 버튼 후 promotion_target_segments 생성 흐름 구현
```

### Generation / Run / Assignment / Evaluation

Required:

```text
1. suggestion table을 최종 세그먼트로 사용하지 않는다.
2. promotion_target_segments만 최종 confirmed input으로 사용한다.
3. promotion_target_segments가 없으면 아직 확정 전 상태로 본다.
```

## Key Decision

최종적으로 팀이 합의해야 하는 질문은 하나다.

```text
확정 버튼을 눌렀을 때 promotion_target_segments를 누가 쓰는가?
```

권장안:

```text
Dashboard
= 사용자 선택 상태를 저장한다.

Decision
= 확정된 선택을 기준으로 promotion_target_segments와 segment_vectors를 만든다.
```

단순안:

```text
Dashboard
= promotion_target_segments까지 직접 쓴다.

Decision
= 이후 segment_vectors 누락분을 보강한다.
```

서비스 경계와 기존 contract의 "Decision writes analysis/generation/ad_experiment/assignment/evaluation results" 원칙을 고려하면 권장안이 더 안전하다.
