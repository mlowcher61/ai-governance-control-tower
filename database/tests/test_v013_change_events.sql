-- SQL assertions for V013: change events are stored once, mapped to agents, ignored or suppressed, and audited.
\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  IF NOT has_function_privilege('aigov_discovery', 'api.record_change_event(jsonb,text[])', 'EXECUTE')
     OR has_function_privilege('aigov_reader', 'api.record_change_event(jsonb,text[])', 'EXECUTE')
     OR has_function_privilege('aigov_remediator', 'api.record_change_event(jsonb,text[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'record_change_event grants are wrong';
  END IF;
  IF NOT has_table_privilege('aigov_reader', 'api.change_events', 'SELECT') THEN RAISE EXCEPTION 'reader cannot see change events'; END IF;
END $$;

INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000e301', 'aws', '111122223333');
INSERT INTO aigov.agent_identities (id, provider, principal_ref, collected_at) VALUES
  ('00000000-0000-0000-0000-00000000e302', 'aws', 'arn:aws:iam::111122223333:role/aigov-agents/aigov-demo-quick-helper-bot', now());
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash, identity_id) VALUES
  ('00000000-0000-0000-0000-00000000e311', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000e301', 'us-west-1',
   'quick_helper_bot-AbC123', 'arn:aws:bedrock-agentcore:us-west-1:111122223333:runtime/quick_helper_bot-AbC123', 'quick_helper_bot', 'h',
   '00000000-0000-0000-0000-00000000e302');

CREATE FUNCTION pg_temp.ev(eid text, name text, src text, params jsonb, caller text, err text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('source', 'aws.' || split_part(src, '.', 1), 'detail-type', 'AWS API Call via CloudTrail',
    'detail', jsonb_build_object('eventID', eid, 'eventName', name, 'eventSource', src, 'awsRegion', 'us-west-1',
      'eventTime', '2026-11-23T16:17:00Z', 'requestParameters', params, 'userIdentity', jsonb_build_object('arn', caller))
      || CASE WHEN err IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('errorCode', err) END)
$$;
GRANT EXECUTE ON FUNCTION pg_temp.ev(text, text, text, jsonb, text, text) TO PUBLIC;

DO $$
DECLARE r json; ok boolean; dev text := 'arn:aws:iam::111122223333:user/dev';
        sup text[] := ARRAY['assumed-role/AIGovRemediationRole/', 'assumed-role/AIGovDemoResetRole/'];
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_discovery';
  -- IAM change on the agent's role: mapped to the agent
  r := api.record_change_event(pg_temp.ev('e1', 'AttachRolePolicy', 'iam.amazonaws.com',
         '{"roleName": "aigov-demo-quick-helper-bot", "policyArn": "arn:aws:iam::aws:policy/AdministratorAccess"}', dev), sup);
  IF r ->> 'status' <> 'mapped' OR r ->> 'target' <> 'aigov-demo-quick-helper-bot' OR json_array_length(r -> 'agent_ids') <> 1 THEN
    RAISE EXCEPTION 'role event not mapped: %', r;
  END IF;
  -- The same event again (SQS redelivery): returned, not stored twice
  r := api.record_change_event(pg_temp.ev('e1', 'AttachRolePolicy', 'iam.amazonaws.com', '{"roleName": "aigov-demo-quick-helper-bot"}', dev), sup);
  IF NOT (r ->> 'duplicate')::boolean THEN RAISE EXCEPTION 'duplicate stored twice: %', r; END IF;
  -- Tagging the runtime (named by ARN): mapped
  r := api.record_change_event(pg_temp.ev('e2', 'TagResource', 'bedrock-agentcore.amazonaws.com',
         '{"resourceArn": "arn:aws:bedrock-agentcore:us-west-1:111122223333:runtime/quick_helper_bot-AbC123"}', dev), sup);
  IF r ->> 'status' <> 'mapped' OR r ->> 'target_type' <> 'agent_runtime' THEN RAISE EXCEPTION 'runtime event not mapped: %', r; END IF;
  -- A role no agent uses: ignored, not_agent_related
  r := api.record_change_event(pg_temp.ev('e3', 'PutRolePolicy', 'iam.amazonaws.com', '{"roleName": "unrelated-role"}', dev), sup);
  IF r ->> 'status' <> 'ignored' OR r ->> 'reason' <> 'not_agent_related' THEN RAISE EXCEPTION 'unrelated role not ignored: %', r; END IF;
  -- Made by the remediation role: suppressed (loop prevention)
  r := api.record_change_event(pg_temp.ev('e4', 'DetachRolePolicy', 'iam.amazonaws.com', '{"roleName": "aigov-demo-quick-helper-bot"}',
         'arn:aws:sts::111122223333:assumed-role/AIGovRemediationRole/aigov-x'), sup);
  IF r ->> 'status' <> 'suppressed' OR r ->> 'reason' NOT LIKE 'governance_role:%AIGovRemediationRole%' THEN RAISE EXCEPTION 'self event not suppressed: %', r; END IF;
  -- A failed call: ignored
  r := api.record_change_event(pg_temp.ev('e5', 'AttachRolePolicy', 'iam.amazonaws.com', '{"roleName": "aigov-demo-quick-helper-bot"}', dev, 'AccessDenied'), sup);
  IF r ->> 'reason' <> 'failed_call' THEN RAISE EXCEPTION 'failed call not ignored: %', r; END IF;
  -- Not a CloudTrail event: refused
  ok := false;
  BEGIN PERFORM api.record_change_event('{"detail": {}}'); EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'malformed event accepted'; END IF;
  r := api.update_change_event((SELECT change_event_id FROM api.change_events WHERE status = 'mapped' LIMIT 1), 'exec-1');
  RESET ROLE;
  IF (SELECT count(*) FROM aigov.change_events) <> 5 THEN RAISE EXCEPTION 'expected 5 stored events'; END IF;
  IF (SELECT count(*) FROM aigov.audit_events WHERE event_type IN ('event.received', 'event.ignored', 'event.suppressed')) < 5 THEN
    RAISE EXCEPTION 'change events not audited';
  END IF;
  IF NOT EXISTS (SELECT FROM aigov.change_events WHERE ao_execution_id = 'exec-1') THEN RAISE EXCEPTION 'execution not recorded'; END IF;
END $$;
ROLLBACK;
\echo 'test_v013_change_events: all assertions passed'
