-- SQL assertions for V006: demo reset and the acceptance views.
\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF NOT has_function_privilege('aigov_remediator', 'api.reset_demo(text,text,text)', 'EXECUTE')
     OR has_function_privilege('aigov_evaluator', 'api.reset_demo(text,text,text)', 'EXECUTE')
     OR has_function_privilege('aigov_reader', 'api.reset_demo(text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'reset_demo grants are wrong';
  END IF;
  IF NOT has_table_privilege('aigov_evaluator', 'api.agent_assessment', 'SELECT')
     OR NOT has_table_privilege('aigov_reader', 'api.governance_runs', 'SELECT')
     OR has_table_privilege('aigov_discovery', 'api.agent_assessment', 'SELECT') THEN
    RAISE EXCEPTION 'acceptance view grants are wrong';
  END IF;
END $$;

INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-0000000000f1', 'aws', '444455556666');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash, tags, compliance_status, risk_score, risk_category)
VALUES ('00000000-0000-0000-0000-0000000000f2', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-0000000000f1', 'us-west-1',
        'demo', 'arn:d', 'demo_bot', 'h', '{"aigov:demo": "true"}', 'noncompliant', 100, 'critical'),
       ('00000000-0000-0000-0000-0000000000f3', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-0000000000f1', 'us-west-1',
        'real', 'arn:r', 'real_bot', 'h', '{}', 'noncompliant', 90, 'critical');
INSERT INTO aigov.findings (agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation, ai_explanation)
VALUES ('00000000-0000-0000-0000-0000000000f2', 'AIGOV-IAM-001', 'violation', 'critical', 'a', 'admin', '{"headline": "kept"}'),
       ('00000000-0000-0000-0000-0000000000f3', 'AIGOV-IAM-001', 'violation', 'critical', 'b', 'admin', NULL);

DO $$
DECLARE res json; n_audit int;
BEGIN
  SELECT count(*) INTO n_audit FROM aigov.audit_events;
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  PERFORM set_config('request.jwt.claims', '{"role": "aigov_remediator", "sub": "test-reset"}', true);
  res := api.reset_demo('test');
  BEGIN
    PERFORM api.reset_demo('x', '', '');
    RAISE EXCEPTION 'reset without a tag filter accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RESET ROLE;
  IF (res ->> 'findings_resolved')::int <> 1 THEN RAISE EXCEPTION 'reset result: %', res; END IF;
  -- only the demo agent is reset; its finding is resolved but kept, with its AI explanation
  IF (SELECT status || '/' || resolution || '/' || (ai_explanation ->> 'headline') FROM aigov.findings WHERE agent_id = '00000000-0000-0000-0000-0000000000f2')
     <> 'resolved/demo_reset/kept' THEN RAISE EXCEPTION 'demo finding not resolved and kept'; END IF;
  IF (SELECT status FROM aigov.findings WHERE agent_id = '00000000-0000-0000-0000-0000000000f3') <> 'open' THEN
    RAISE EXCEPTION 'a non-demo agent was reset';
  END IF;
  IF (SELECT compliance_status FROM aigov.ai_agents WHERE id = '00000000-0000-0000-0000-0000000000f2') <> 'not_evaluated'
     OR (SELECT compliance_status FROM aigov.ai_agents WHERE id = '00000000-0000-0000-0000-0000000000f3') <> 'noncompliant' THEN
    RAISE EXCEPTION 'agent statuses wrong after reset';
  END IF;
  IF (SELECT count(*) FROM aigov.audit_events WHERE event_type = 'demo.reset' AND actor_id = 'test-reset') <> 1
     OR (SELECT count(*) FROM aigov.audit_events) <> n_audit + 1 THEN
    RAISE EXCEPTION 'demo.reset not audited exactly once';
  END IF;
END $$;

ROLLBACK;
\echo 'test_v006_demo_reset: all assertions passed'
