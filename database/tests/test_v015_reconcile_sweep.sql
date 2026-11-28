-- SQL assertions for V015: the sweep expires stale remediations, confirms missing agents, explains drift, and checks
-- the audit chain incrementally (F-19: a tampered row is reported as audit.chain_broken).
\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  IF NOT has_function_privilege('aigov_remediator', 'api.reconcile_sweep(integer,integer)', 'EXECUTE')
     OR has_function_privilege('aigov_reader', 'api.reconcile_sweep(integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'reconcile_sweep grants are wrong';
  END IF;
  IF (SELECT array_agg(p ORDER BY p) FROM aigov.jsonb_diff_paths('{"a": 1, "t": {"x": "1", "y": "2"}, "l": [1]}', '{"a": 1, "t": {"x": "9"}, "l": [1, 2], "n": true}') p)
     <> ARRAY['l', 'n', 't.x', 't.y'] THEN
    RAISE EXCEPTION 'jsonb_diff_paths wrong';
  END IF;
END $$;

INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000f501', 'aws', '989898989898');
INSERT INTO aigov.governance_runs (id, run_type, trigger_type) VALUES ('00000000-0000-0000-0000-00000000f502', 'remediation', 'manual');
INSERT INTO aigov.discovery_runs (id, governance_run_id, provider, scope) VALUES ('00000000-0000-0000-0000-00000000f503', '00000000-0000-0000-0000-00000000f502', 'aws', '{}');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash, missing_since) VALUES
  ('00000000-0000-0000-0000-00000000f511', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000f501', 'r', 's1', 'arn:s1', 's1', 'h', NULL),
  ('00000000-0000-0000-0000-00000000f512', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000f501', 'r', 's2', 'arn:s2', 's2', 'h', NULL),
  ('00000000-0000-0000-0000-00000000f513', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000f501', 'r', 's3', 'arn:s3', 'gone', 'h', now() - interval '30 hours');
-- Four stale remediations on four findings of agent s1
INSERT INTO aigov.findings (id, agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation, status) VALUES
  ('00000000-0000-0000-0000-00000000f521', '00000000-0000-0000-0000-00000000f511', 'AIGOV-IAM-001', 'violation', 'critical', 'f1', 'x', 'awaiting_approval'),
  ('00000000-0000-0000-0000-00000000f522', '00000000-0000-0000-0000-00000000f511', 'AIGOV-TAG-001', 'violation', 'medium', 'f2', 'x', 'remediation_planned'),
  ('00000000-0000-0000-0000-00000000f523', '00000000-0000-0000-0000-00000000f511', 'AIGOV-REG-001', 'violation', 'high', 'f3', 'x', 'remediating'),
  ('00000000-0000-0000-0000-00000000f524', '00000000-0000-0000-0000-00000000f511', 'AIGOV-OWN-001', 'violation', 'high', 'f4', 'x', 'remediating');
INSERT INTO aigov.remediation_actions (id, governance_run_id, finding_id, action_type, mode, status, authz_decision, attempt_number, updated_at) VALUES
  ('00000000-0000-0000-0000-00000000f531', '00000000-0000-0000-0000-00000000f502', '00000000-0000-0000-0000-00000000f521', 'iam_replace_managed_policy', 'enforce', 'awaiting_approval', '{}', 1, now() - interval '5 hours'),
  ('00000000-0000-0000-0000-00000000f532', '00000000-0000-0000-0000-00000000f502', '00000000-0000-0000-0000-00000000f522', 'agentcore_apply_governance_tags', 'enforce', 'planned', '{}', 1, now() - interval '5 hours'),
  ('00000000-0000-0000-0000-00000000f533', '00000000-0000-0000-0000-00000000f502', '00000000-0000-0000-0000-00000000f523', 'agentcore_apply_governance_tags', 'enforce', 'approved', '{}', 1, now() - interval '5 hours'),
  ('00000000-0000-0000-0000-00000000f534', '00000000-0000-0000-0000-00000000f502', '00000000-0000-0000-0000-00000000f524', 'agentcore_apply_governance_tags', 'enforce', 'executing', '{}', 1, now() - interval '5 hours');
-- Drift: s1 changed with a change event explaining it; s2 changed without one
INSERT INTO aigov.agent_snapshots (agent_id, discovery_run_id, content_hash, record, observed_at) VALUES
  ('00000000-0000-0000-0000-00000000f511', '00000000-0000-0000-0000-00000000f503', 'a', '{"tags": {"env": "prod"}, "status": "READY"}', now() - interval '2 hours'),
  ('00000000-0000-0000-0000-00000000f511', '00000000-0000-0000-0000-00000000f503', 'b', '{"tags": {"env": "dev"}, "status": "READY"}', now() - interval '1 minute'),
  ('00000000-0000-0000-0000-00000000f512', '00000000-0000-0000-0000-00000000f503', 'c', '{"tags": {}, "status": "READY"}', now() - interval '2 hours'),
  ('00000000-0000-0000-0000-00000000f512', '00000000-0000-0000-0000-00000000f503', 'd', '{"tags": {"x": "1"}, "status": "READY"}', now() - interval '1 minute');
INSERT INTO aigov.change_events (event_id, received_at, event_time, event_source, event_name, status, agent_ids, raw)
VALUES ('ce-s1', now() - interval '30 minutes', now() - interval '31 minutes', 'bedrock-agentcore.amazonaws.com', 'TagResource', 'mapped',
        ARRAY['00000000-0000-0000-0000-00000000f511']::uuid[], '{}');
UPDATE aigov.sweep_state SET last_drift_check = now() - interval '1 hour';

DO $$
DECLARE r json; d jsonb;
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  PERFORM set_config('request.jwt.claims', '{"role": "aigov_remediator", "sub": "sweep-test"}', true);
  r := api.reconcile_sweep(120, 24);
  RESET ROLE;
  IF r -> 'chain' ->> 'status' <> 'intact' THEN RAISE EXCEPTION 'chain should be intact: %', r -> 'chain'; END IF;
  IF r -> 'expired_remediations' ->> 0 <> '00000000-0000-0000-0000-00000000f531'
     OR json_array_length(r -> 'skipped_remediations') <> 2 OR r -> 'failed_remediations' ->> 0 <> '00000000-0000-0000-0000-00000000f534' THEN
    RAISE EXCEPTION 'stale remediations wrong: %', r;
  END IF;
  IF (SELECT status FROM aigov.remediation_actions WHERE id = '00000000-0000-0000-0000-00000000f531') <> 'expired'
     OR (SELECT status FROM aigov.findings WHERE id = '00000000-0000-0000-0000-00000000f521') <> 'open' THEN
    RAISE EXCEPTION 'expired remediation not applied';
  END IF;
  IF json_array_length(r -> 'missing_confirmed') <> 1 OR r -> 'missing_confirmed' -> 0 ->> 'name' <> 'gone' THEN RAISE EXCEPTION 'missing wrong: %', r; END IF;
  d := (r -> 'drift')::jsonb;
  IF jsonb_array_length(d) <> 2 THEN RAISE EXCEPTION 'drift wrong: %', d; END IF;
  IF NOT (SELECT bool_and(x ->> 'attributed' = CASE x ->> 'agent' WHEN 's1' THEN 'true' ELSE 'false' END) FROM jsonb_array_elements(d) x) THEN
    RAISE EXCEPTION 'attribution wrong: %', d;
  END IF;
  IF NOT EXISTS (SELECT FROM jsonb_array_elements(d) x WHERE x ->> 'agent' = 's1' AND x -> 'changed_paths' ? 'tags.env') THEN
    RAISE EXCEPTION 'changed paths wrong: %', d;
  END IF;
  -- A second sweep: nothing new; missing is not confirmed twice; the chain check advances
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  r := api.reconcile_sweep(120, 24);
  RESET ROLE;
  IF json_array_length(r -> 'missing_confirmed') <> 0 OR json_array_length(r -> 'drift') <> 0 OR json_array_length(r -> 'expired_remediations') <> 0 THEN
    RAISE EXCEPTION 'second sweep not idempotent: %', r;
  END IF;
  IF (r -> 'chain' ->> 'verified_from_id')::bigint <= 0 THEN RAISE EXCEPTION 'checkpoint did not advance: %', r -> 'chain'; END IF;
END $$;

-- F-19: a superuser alters an audit row written after the last checkpoint; the next sweep reports it
DO $$ BEGIN PERFORM aigov.audit('test.marker', 'service', 't', 'db'); END $$;
ALTER TABLE aigov.audit_events DISABLE TRIGGER audit_events_immutable;
UPDATE aigov.audit_events SET details = '{"forged": true}' WHERE event_type = 'test.marker';
ALTER TABLE aigov.audit_events ENABLE TRIGGER audit_events_immutable;
DO $$
DECLARE r json;
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  r := api.reconcile_sweep(120, 24);
  RESET ROLE;
  IF r -> 'chain' ->> 'status' <> 'broken' OR (r -> 'chain' ->> 'broken_id') IS NULL THEN RAISE EXCEPTION 'tamper not detected: %', r -> 'chain'; END IF;
  IF NOT EXISTS (SELECT FROM aigov.audit_events WHERE event_type = 'audit.chain_broken') THEN RAISE EXCEPTION 'chain_broken not audited'; END IF;
END $$;
ROLLBACK;
\echo 'test_v015_reconcile_sweep: all assertions passed'
