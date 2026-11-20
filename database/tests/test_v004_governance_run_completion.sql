-- SQL assertions for V004: closing a governance run.
\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF NOT has_function_privilege('aigov_evaluator', 'api.complete_governance_run(uuid,text,jsonb,text)', 'EXECUTE')
     OR has_function_privilege('aigov_reader', 'api.complete_governance_run(uuid,text,jsonb,text)', 'EXECUTE')
     OR has_function_privilege('aigov_discovery', 'api.complete_governance_run(uuid,text,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'complete_governance_run grants are wrong';
  END IF;
END $$;

INSERT INTO aigov.governance_runs (id, run_type, trigger_type) VALUES ('00000000-0000-0000-0000-0000000000c1', 'assessment', 'manual');

DO $$
DECLARE res json; r aigov.governance_runs;
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_evaluator';
  PERFORM set_config('request.jwt.claims', '{"role": "aigov_evaluator", "sub": "test-summary"}', true);
  res := api.complete_governance_run('00000000-0000-0000-0000-0000000000c1', 'completed', '{"agents": 4}', 'ao-exec-1');
  BEGIN
    PERFORM api.complete_governance_run('00000000-0000-0000-0000-0000000000c1', 'done', '{}', NULL);
    RAISE EXCEPTION 'invalid status accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM api.complete_governance_run(gen_random_uuid(), 'completed', '{}', NULL);
    RAISE EXCEPTION 'unknown run accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RESET ROLE;
  SELECT * INTO r FROM aigov.governance_runs WHERE id = '00000000-0000-0000-0000-0000000000c1';
  IF r.status <> 'completed' OR r.finished_at IS NULL OR r.ao_execution_id <> 'ao-exec-1' THEN
    RAISE EXCEPTION 'run not closed: %', row_to_json(r);
  END IF;
  IF (SELECT count(*) FROM aigov.audit_events WHERE event_type = 'governance.run_completed'
        AND actor_id = 'test-summary' AND details -> 'summary' ->> 'agents' = '4') <> 1 THEN
    RAISE EXCEPTION 'governance.run_completed not audited';
  END IF;
END $$;

ROLLBACK;
\echo 'test_v004_governance_run_completion: all assertions passed'
