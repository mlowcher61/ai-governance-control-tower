-- SQL assertions for V009: get_remediation and separation of duties in record_approval.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.as_remediator() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  PERFORM set_config('request.jwt.claims', '{"role": "aigov_remediator", "sub": "test-remediator"}', true);
END $$;

DO $$
BEGIN
  IF NOT has_function_privilege('aigov_remediator', 'api.get_remediation(uuid)', 'EXECUTE') THEN RAISE EXCEPTION 'remediator cannot read remediations'; END IF;
  IF has_function_privilege('aigov_reader', 'api.get_remediation(uuid)', 'EXECUTE')
     OR has_function_privilege('aigov_api_anon', 'api.get_remediation(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'get_remediation is granted too widely';
  END IF;
END $$;

INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000d901', 'aws', '777788889999');
INSERT INTO aigov.owners (id, name, email, approved) VALUES ('own-y', 'Team Y', 'Y@example.com', true);
INSERT INTO aigov.agent_registrations (registration_id, match_keys, owner_id, environment) VALUES ('REG-9101', '{"name": "b1"}', 'own-y', 'production');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash, registration_id, registration_status)
VALUES ('00000000-0000-0000-0000-00000000d902', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000d901', 'r', 'b1', 'arn:b1', 'b1', 'h', 'REG-9101', 'registered');
INSERT INTO aigov.findings (id, agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation, status)
VALUES ('00000000-0000-0000-0000-00000000d903', '00000000-0000-0000-0000-00000000d902', 'AIGOV-IAM-001', 'violation', 'critical', 'f', 'x', 'awaiting_approval');
INSERT INTO aigov.governance_runs (id, run_type, trigger_type) VALUES ('00000000-0000-0000-0000-00000000d904', 'remediation', 'manual');
INSERT INTO aigov.remediation_actions (id, governance_run_id, finding_id, action_type, mode, status, authz_decision, pre_state, attempt_number)
VALUES ('00000000-0000-0000-0000-00000000d905', '00000000-0000-0000-0000-00000000d904', '00000000-0000-0000-0000-00000000d903',
        'iam_replace_managed_policy', 'enforce', 'awaiting_approval', '{"route_precheck": "eligible"}', '{"identity": {}}', 1);

DO $$
DECLARE r json; ok boolean;
BEGIN
  PERFORM pg_temp.as_remediator();
  r := api.get_remediation('00000000-0000-0000-0000-00000000d905');
  IF r ->> 'action_type' <> 'iam_replace_managed_policy' OR r -> 'pre_state' IS NULL OR r ->> 'governance_run_id' <> '00000000-0000-0000-0000-00000000d904'
     OR json_array_length(r -> 'approvals') <> 0 THEN
    RAISE EXCEPTION 'get_remediation incomplete: %', r;
  END IF;
  ok := false;
  BEGIN PERFORM api.get_remediation('00000000-0000-0000-0000-0000000000ff'); EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'unknown remediation accepted'; END IF;

  -- The owner (by id, e-mail in any case, or name) cannot approve
  FOREACH r IN ARRAY ARRAY['"own-y"', '" y@EXAMPLE.com "', '"Team Y"']::json[] LOOP
    ok := false;
    BEGIN PERFORM api.record_approval('00000000-0000-0000-0000-00000000d905', 'approved', r #>> '{}');
    EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%separation of duties%'; END;
    IF NOT ok THEN RAISE EXCEPTION 'owner % approved its own remediation', r; END IF;
  END LOOP;

  -- Someone else can; the approval shows in get_remediation
  r := api.record_approval('00000000-0000-0000-0000-00000000d905', 'approved', 'security-approver', 'ok');
  IF r ->> 'remediation_status' <> 'approved' THEN RAISE EXCEPTION 'approval not recorded: %', r; END IF;
  r := api.get_remediation('00000000-0000-0000-0000-00000000d905');
  IF r ->> 'status' <> 'approved' OR r -> 'approvals' -> 0 ->> 'decided_by' <> 'security-approver' THEN RAISE EXCEPTION 'approval missing: %', r; END IF;
  RESET ROLE;
END $$;
ROLLBACK;
\echo 'test_v009_execute_remediation: all assertions passed'
