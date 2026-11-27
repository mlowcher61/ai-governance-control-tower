-- SQL assertions for V014: a targeted re-assessment returns new and worsened violations and stamps the change time.
\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  IF NOT has_function_privilege('aigov_evaluator', 'api.complete_targeted_assessment(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('aigov_reader', 'api.start_targeted_assessment(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'targeted assessment grants are wrong';
  END IF;
END $$;

INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000f401', 'aws', '121234345656');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash)
VALUES ('00000000-0000-0000-0000-00000000f402', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000f401', 'r', 't1', 'arn:t1', 't1', 'h');
-- Before the change: TAG-001 already open (medium), MDL-001 open (medium, stays medium)
INSERT INTO aigov.findings (id, agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation, first_detected_at) VALUES
  ('00000000-0000-0000-0000-00000000f403', '00000000-0000-0000-0000-00000000f402', 'AIGOV-TAG-001', 'violation', 'medium', 'a', 'x', now() - interval '1 day'),
  ('00000000-0000-0000-0000-00000000f404', '00000000-0000-0000-0000-00000000f402', 'AIGOV-MDL-001', 'violation', 'medium', 'b', 'x', now() - interval '1 day');
INSERT INTO aigov.change_events (id, event_id, event_time, event_source, event_name, status, agent_ids, raw)
VALUES ('00000000-0000-0000-0000-00000000f405', 'ce-1', '2026-11-27T10:00:00Z', 'iam.amazonaws.com', 'AttachRolePolicy', 'mapped',
        ARRAY['00000000-0000-0000-0000-00000000f402']::uuid[], '{}');

DO $$
DECLARE r json; run uuid; res jsonb;
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_evaluator';
  r := api.start_targeted_assessment('00000000-0000-0000-0000-00000000f405');
  run := (r ->> 'governance_run_id')::uuid;
  -- The change made the role admin (IAM-001 new, critical) and TAG-001 worse (medium -> high); MDL-001 unchanged
  res := jsonb_build_object('agent_id', '00000000-0000-0000-0000-00000000f402', 'overall_status', 'noncompliant', 'bundle_revision', 'b',
    'risk', '{"score": 90, "category": "critical", "factors": []}'::jsonb, 'summary', '{}'::jsonb,
    'results', '[{"policy_id": "AIGOV-IAM-001", "policy_version": "1", "decision": "fail", "severity": "critical", "explanation": "admin"},
                 {"policy_id": "AIGOV-TAG-001", "policy_version": "1", "decision": "fail", "severity": "high", "explanation": "tags"},
                 {"policy_id": "AIGOV-MDL-001", "policy_version": "1", "decision": "fail", "severity": "medium", "explanation": "x"}]'::jsonb);
  PERFORM api.record_evaluation(run, '00000000-0000-0000-0000-00000000f402', 'assessment', res, 'h1');
  r := api.complete_targeted_assessment(run, '00000000-0000-0000-0000-00000000f405');
  RESET ROLE;
  IF json_array_length(r -> 'new_violation_finding_ids') <> 1 OR (r ->> 'agents_evaluated')::int <> 1 THEN RAISE EXCEPTION 'new violations wrong: %', r; END IF;
  IF (SELECT policy_id FROM aigov.findings WHERE id = (r -> 'new_violation_finding_ids' ->> 0)::uuid) <> 'AIGOV-IAM-001' THEN RAISE EXCEPTION 'wrong new finding: %', r; END IF;
  IF r -> 'worsened_violation_finding_ids' ->> 0 <> '00000000-0000-0000-0000-00000000f403' OR json_array_length(r -> 'worsened_violation_finding_ids') <> 1 THEN
    RAISE EXCEPTION 'worsened violations wrong: %', r;
  END IF;
  IF json_array_length(r -> 'remediation_candidates') <> 2 THEN RAISE EXCEPTION 'candidates wrong: %', r; END IF;
  IF (SELECT source_change_at FROM aigov.findings WHERE id = (r -> 'new_violation_finding_ids' ->> 0)::uuid) <> '2026-11-27T10:00:00Z'::timestamptz THEN
    RAISE EXCEPTION 'change time not stamped';
  END IF;
  IF (SELECT status FROM aigov.governance_runs WHERE id = run) <> 'succeeded'
     OR (SELECT trigger_type FROM aigov.governance_runs WHERE id = run) <> 'event' THEN RAISE EXCEPTION 'run not closed as an event run'; END IF;
END $$;
ROLLBACK;
\echo 'test_v014_targeted_assessment: all assertions passed'
