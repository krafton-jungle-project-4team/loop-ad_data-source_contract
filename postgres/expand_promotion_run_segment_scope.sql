-- Phase 1: expand promotion_runs for segment-scoped dual writes.
-- Rerunnable. Keep uq_promotion_runs_loop until the finalize phase.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE promotion_runs
    ADD COLUMN IF NOT EXISTS segment_scope_json JSONB;

ALTER TABLE promotion_runs
    ADD COLUMN IF NOT EXISTS segment_scope_fingerprint VARCHAR(64);

COMMIT;
