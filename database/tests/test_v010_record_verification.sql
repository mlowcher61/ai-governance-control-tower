-- SQL assertions for V010: api.record_verification decides verified / verification_failed and closes the finding.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.as_remediator() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  PERFORM set_config('request.jwt.claims', '{"role": "aigov_remediator", "sub": "test-remediator"}', true);
END $$;

DO $$
BEGIN
  IF NOT has_function_privilege('aigov_remediator', 'api.record_verification(uuid,jsonb,text,jsonb,bigint,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'remediator cannot record verifications';
  END IF;
  IF has_function_privilege('aigov_evaluator', 'api.record_verification(uuid,jsonb,text,jsonb,bigint,text)', 'EXECUTE')
     OR has_function_privilege('aigov_reader', 'api.record_verification(uuid,jsonb,text,jsonb,bigint,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'record_verification is granted too widely';
  END IF;
  IF NOT has_table_privilege('aigov_remediator', 'api.evaluation_inputs', 'SELECT') THEN RAISE EXCEPTION 'remediator cannot read inputs'; END IF;
END $$;

INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000e001', 'aws', '888899990000');
INSERT INTO aigov.governance_runs (id, run_type, trigger_type) VALUES ('00000000-0000-0000-0000-00000000e002', 'remediation', 'manual');

-- One agent per case, each with an open IAM-001 violation, a baseline evaluation (IAM-001 fail, TAG-001 pass) one hour
-- before the remediation, and an executed (succeeded) remediation.
CREATE FUNCTION pg_temp.setup(n int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE agent uuid := ('00000000-0000-0000-0000-0000000e1' || lpad(n::text, 3, '0'))::uuid; fid uuid; ev json; rid uuid;
BEGIN
  INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash)
  VALUES (agent, 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000e001', 'r', 'v' || n, 'arn:v' || n, 'v' || n, 'h');
  ev := api.record_evaluation('00000000-0000-0000-0000-00000000e002', agent, 'assessment', pg_temp.result(agent, 'fail', 'pass'), 'h0');
  UPDATE aigov.policy_evaluations SET evaluated_at = now() - interval '1 hour' WHERE id = (ev ->> 'evaluation_id')::uuid;
  SELECT id INTO fid FROM aigov.findings WHERE agent_id = agent AND policy_id = 'AIGOV-IAM-001';
  UPDATE aigov.findings SET status = 'verifying' WHERE id = fid;
  INSERT INTO aigov.remediation_actions (governance_run_id, finding_id, action_type, mode, status, authz_decision, attempt_number)
  VALUES ('00000000-0000-0000-0000-00000000e002', fid, 'iam_replace_managed_policy', 'enforce', 'succeeded', '{}', 1) RETURNING id INTO rid;
  RETURN rid;
END $$;
CREATE FUNCTION pg_temp.result(agent uuid, iam text, tag text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('agent_id', agent, 'overall_status', 'noncompliant', 'bundle_revision', 'b1',
    'risk', '{"score": 50, "category": "high", "factors": []}'::jsonb, 'summary', '{}'::jsonb,
    'results', jsonb_build_array(
      jsonb_build_object('policy_id', 'AIGOV-IAM-001', 'policy_version', '1.0.0', 'decision', iam, 'severity', 'critical', 'explanation', 'iam'),
      jsonb_build_object('policy_id', 'AIGOV-TAG-001', 'policy_version', '1.0.0', 'decision', tag, 'severity', 'medium', 'explanation', 'tags')))
$$;
CREATE TEMP TABLE rem (n int PRIMARY KEY, id uuid);
GRANT ALL ON rem TO PUBLIC;
INSERT INTO rem SELECT n, pg_temp.setup(n) FROM generate_series(1, 3) n;
GRANT EXECUTE ON FUNCTION pg_temp.result(uuid, text, text) TO PUBLIC;

DO $$
DECLARE r json; ok boolean; a1 uuid := '00000000-0000-0000-0000-0000000e1001'; a2 uuid := '00000000-0000-0000-0000-0000000e1002';
        a3 uuid := '00000000-0000-0000-0000-0000000e1003'; good jsonb := '{"simulation_admin_probes": "all_denied", "agent_status": "READY"}';
BEGIN
  PERFORM pg_temp.as_remediator();

  -- Invalid check values are refused
  ok := false;
  BEGIN PERFORM api.record_verification((SELECT id FROM rem WHERE n = 1), pg_temp.result(a1, 'pass', 'pass'), 'h', '{"simulation_admin_probes": "maybe"}');
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'invalid simulation check accepted'; END IF;

  -- 1. Everything passes: verified, finding resolved as remediated
  r := api.record_verification((SELECT id FROM rem WHERE n = 1), pg_temp.result(a1, 'pass', 'pass'), 'h1', good, 42);
  IF r ->> 'status' <> 'verified' OR r ->> 'finding_status' <> 'resolved' OR (r ->> 'regressions')::int <> 0
     OR r ->> 'target_policy_decision' <> 'pass' THEN RAISE EXCEPTION 'case 1 not verified: %', r; END IF;
  -- Only once: the remediation is now verified
  ok := false;
  BEGIN PERFORM api.record_verification((SELECT id FROM rem WHERE n = 1), pg_temp.result(a1, 'pass', 'pass'), 'h1', good);
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%succeeded%'; END;
  IF NOT ok THEN RAISE EXCEPTION 'a verified remediation was verified again'; END IF;

  -- 2. Target passes but TAG-001 regressed (pass -> fail): verification_failed, finding back to open
  r := api.record_verification((SELECT id FROM rem WHERE n = 2), pg_temp.result(a2, 'pass', 'fail'), 'h2', good);
  IF r ->> 'status' <> 'verification_failed' OR (r ->> 'regressions')::int <> 1 OR r -> 'regressed_policies' ->> 0 <> 'AIGOV-TAG-001'
     OR r ->> 'finding_status' <> 'open' THEN RAISE EXCEPTION 'case 2 wrong: %', r; END IF;

  -- 3. OPA passes but an admin probe is still allowed (IAM not yet consistent): verification_failed
  r := api.record_verification((SELECT id FROM rem WHERE n = 3), pg_temp.result(a3, 'pass', 'pass'), 'h3',
                               '{"simulation_admin_probes": "some_allowed", "agent_status": "READY"}');
  IF r ->> 'status' <> 'verification_failed' OR (r ->> 'regressions')::int <> 0 THEN RAISE EXCEPTION 'case 3 wrong: %', r; END IF;
  RESET ROLE;

  -- The evaluations are verification evaluations; the regression opened a TAG-001 finding; the audit has both outcomes
  IF (SELECT count(*) FROM aigov.policy_evaluations WHERE agent_id IN (a1, a2, a3) AND purpose = 'verification') <> 3 THEN
    RAISE EXCEPTION 'verification evaluations missing';
  END IF;
  IF NOT EXISTS (SELECT FROM aigov.findings WHERE agent_id = a2 AND policy_id = 'AIGOV-TAG-001' AND status = 'open') THEN
    RAISE EXCEPTION 'regression did not open a finding';
  END IF;
  IF (SELECT resolution FROM aigov.findings WHERE agent_id = a1 AND policy_id = 'AIGOV-IAM-001') <> 'remediated' THEN
    RAISE EXCEPTION 'case 1 finding not remediated';
  END IF;
  IF (SELECT status FROM aigov.remediation_actions WHERE id = (SELECT id FROM rem WHERE n = 3)) <> 'verification_failed'
     OR (SELECT error -> 'checks' ->> 'simulation_admin_probes' FROM aigov.remediation_actions WHERE id = (SELECT id FROM rem WHERE n = 3)) <> 'some_allowed' THEN
    RAISE EXCEPTION 'case 3 remediation record wrong';
  END IF;
  IF NOT EXISTS (SELECT FROM aigov.audit_events WHERE event_type = 'verification.passed') OR
     NOT EXISTS (SELECT FROM aigov.audit_events WHERE event_type = 'verification.failed') THEN
    RAISE EXCEPTION 'verification audit events missing';
  END IF;
END $$;
ROLLBACK;
\echo 'test_v010_record_verification: all assertions passed'
