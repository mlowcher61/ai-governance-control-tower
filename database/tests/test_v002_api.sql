-- SQL assertions for V002 (T1.02): the api schema RPCs, views and per-role grants.
-- Run as a SUPERUSER (it switches to each API role with SET ROLE, the way PostgREST does).
-- Everything runs in one transaction that is rolled back.
\set ON_ERROR_STOP on
BEGIN;

-- Helper: act as an API role with JWT claims, as PostgREST does for each request.
CREATE FUNCTION pg_temp.as_role(r text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', r);
  PERFORM set_config('request.jwt.claims', json_build_object('role', r, 'sub', 'test-' || r)::text, true);
END $$;
CREATE FUNCTION pg_temp.as_admin() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END $$;

-- Discovery record fixture (AgentCore runtime with AdministratorAccess)
CREATE FUNCTION pg_temp.rec(ext text, nm text, model text DEFAULT NULL, policy_arn text DEFAULT 'arn:aws:iam::aws:policy/AdministratorAccess')
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'provider', 'aws', 'platform', 'aws.bedrock_agentcore_runtime', 'account_ref', '111122223333',
    'region', 'us-west-1', 'external_id', ext, 'name', nm,
    'resource_ref', 'arn:aws:bedrock-agentcore:us-west-1:111122223333:runtime/' || ext,
    'status', 'READY', 'environment', NULL,
    'tags', jsonb_build_object('DataClassification', 'restricted'),
    'attributes', '{}'::jsonb,
    'evidence_status', jsonb_build_object('agent', 'collected', 'tags', 'collected', 'identity', 'collected',
                                          'identity_simulation', 'collected', 'tools', 'collected',
                                          'data_sources', 'not_supported', 'model', 'not_supported'),
    'source_created_at', '2026-11-10T09:12:00Z', 'source_updated_at', '2026-11-16T22:40:00Z',
    'foundation_model', CASE WHEN model IS NULL THEN NULL ELSE jsonb_build_object('model_id', model) END,
    'identity', jsonb_build_object(
      'principal_ref', 'arn:aws:iam::111122223333:role/' || nm || '-role',
      'simulation', jsonb_build_object('iam:CreateUser', 'allowed'),
      'policies', jsonb_build_array(jsonb_build_object(
        'type', 'aws_managed', 'ref', policy_arn, 'name', split_part(policy_arn, '/', 2),
        'statements', jsonb_build_array(jsonb_build_object('effect', 'Allow', 'actions', jsonb_build_array('*'),
                                                           'resources', jsonb_build_array('*')))))),
    'tools', '[]'::jsonb, 'data_sources', '[]'::jsonb,
    'collected_at', clock_timestamp()::text)
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Grants: each function is executable only by its role; no API role touches aigov tables
-- ---------------------------------------------------------------------------------------------
DO $$
DECLARE
  roles text[] := ARRAY['aigov_api_anon', 'aigov_discovery', 'aigov_registry', 'aigov_evaluator',
                        'aigov_remediator', 'aigov_reader', 'aigov_auditor'];
  fn record;
  r text;
  expected boolean;
  bad text[] := '{}';
BEGIN
  FOR fn IN SELECT * FROM (VALUES
      ('api.health()', ARRAY['aigov_api_anon']),
      ('api.whoami()', ARRAY['aigov_discovery', 'aigov_registry', 'aigov_evaluator', 'aigov_remediator', 'aigov_reader', 'aigov_auditor']),
      ('api.start_discovery_run(jsonb,uuid,bigint)', ARRAY['aigov_discovery']),
      ('api.record_discovery(uuid,jsonb)', ARRAY['aigov_discovery']),
      ('api.complete_discovery_run(uuid,text,jsonb,jsonb)', ARRAY['aigov_discovery']),
      ('api.load_registry(jsonb,jsonb,text)', ARRAY['aigov_registry']),
      ('api.record_evaluation(uuid,uuid,text,jsonb,text,text)', ARRAY['aigov_evaluator']),
      ('api.record_explanations(uuid,jsonb,text)', ARRAY['aigov_evaluator']),
      ('api.append_audit_event(jsonb)', ARRAY['aigov_discovery', 'aigov_registry', 'aigov_evaluator', 'aigov_remediator'])
    ) AS t (sig, allowed)
  LOOP
    FOREACH r IN ARRAY roles LOOP
      expected := r = ANY (fn.allowed);
      IF has_function_privilege(r, fn.sig, 'EXECUTE') IS DISTINCT FROM expected THEN
        bad := bad || format('%s EXECUTE %s: expected %s', r, fn.sig, expected);
      END IF;
    END LOOP;
  END LOOP;

  FOR fn IN SELECT * FROM (VALUES
      ('api.evaluation_inputs', ARRAY['aigov_evaluator', 'aigov_remediator']),   -- remediator since V010 (Verify)
      ('api.agent_overview', ARRAY['aigov_reader', 'aigov_evaluator']),
      ('api.findings_open', ARRAY['aigov_reader', 'aigov_evaluator'])
    ) AS t (rel, allowed)
  LOOP
    FOREACH r IN ARRAY roles LOOP
      expected := r = ANY (fn.allowed);
      IF has_table_privilege(r, fn.rel, 'SELECT') IS DISTINCT FROM expected THEN
        bad := bad || format('%s SELECT %s: expected %s', r, fn.rel, expected);
      END IF;
    END LOOP;
  END LOOP;

  -- No API role may write any aigov table, or execute internal helpers.
  FOR fn IN SELECT c.oid::regclass::text AS rel FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'aigov' AND c.relkind = 'r' LOOP
    FOREACH r IN ARRAY roles LOOP
      IF has_table_privilege(r, fn.rel, 'INSERT,UPDATE,DELETE,TRUNCATE') THEN
        bad := bad || format('%s can write %s', r, fn.rel);
      END IF;
      IF has_table_privilege(r, fn.rel, 'SELECT') AND NOT (r = 'aigov_auditor' AND fn.rel = 'aigov.audit_events') THEN
        bad := bad || format('%s can read %s', r, fn.rel);
      END IF;
    END LOOP;
  END LOOP;
  FOR fn IN SELECT p.oid::regprocedure::text AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'aigov' AND p.proname NOT IN ('verify_audit_chain', 'audit_canonical') LOOP
    FOREACH r IN ARRAY roles LOOP
      CONTINUE WHEN r = 'aigov_evaluator' AND fn.sig IN ('aigov.rfc3339(text)', 'aigov.rfc3339_members(jsonb)', 'aigov.safe_text(text,integer)');
      -- V010: the remediator reads api.evaluation_inputs (Verify Remediation), which calls the two date helpers
      CONTINUE WHEN r = 'aigov_remediator' AND fn.sig IN ('aigov.rfc3339(text)', 'aigov.rfc3339_members(jsonb)');
      IF has_function_privilege(r, fn.sig, 'EXECUTE') THEN bad := bad || format('%s can execute %s', r, fn.sig); END IF;
    END LOOP;
  END LOOP;

  -- Writer functions are SECURITY DEFINER with a fixed search_path.
  FOR fn IN SELECT p.oid::regprocedure::text AS sig, p.prosecdef, p.proconfig FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'api' AND p.proname NOT IN ('health', 'whoami') LOOP
    IF NOT fn.prosecdef OR NOT coalesce(fn.proconfig::text LIKE '%search_path=pg_catalog, pg_temp%', false) THEN
      bad := bad || format('%s must be SECURITY DEFINER with search_path=pg_catalog, pg_temp', fn.sig);
    END IF;
  END LOOP;

  IF cardinality(bad) > 0 THEN RAISE EXCEPTION 'privilege matrix violations: %', bad; END IF;
END $$;

-- A role calling a function it was not granted is rejected (PostgREST returns 401/403).
DO $$
BEGIN
  PERFORM pg_temp.as_role('aigov_reader');
  BEGIN
    PERFORM api.start_discovery_run('{"provider": "aws", "account_ref": "111122223333"}', NULL, NULL);
    RAISE EXCEPTION 'aigov_reader could start a discovery run';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.as_role('aigov_discovery');
  BEGIN
    PERFORM count(*) FROM api.evaluation_inputs;
    RAISE EXCEPTION 'aigov_discovery could read evaluation_inputs';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.as_admin();
END $$;

-- whoami reports the switched role and the JWT subject
DO $$
DECLARE w json;
BEGIN
  PERFORM pg_temp.as_role('aigov_evaluator');
  w := api.whoami();
  PERFORM pg_temp.as_admin();
  IF w ->> 'role' <> 'aigov_evaluator' OR w ->> 'actor' <> 'test-aigov_evaluator' THEN
    RAISE EXCEPTION 'whoami returned %', w;
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------
-- 2. Discovery: record, idempotency, drift, scope checks, missing agents
-- ---------------------------------------------------------------------------------------------
CREATE TEMP TABLE ctx (k text PRIMARY KEY, v text);
GRANT ALL ON ctx TO PUBLIC;

DO $$
DECLARE
  run json; res json; n int;
  scope jsonb := '{"provider": "aws", "account_ref": "111122223333", "regions": ["us-west-1"]}';
BEGIN
  PERFORM pg_temp.as_role('aigov_discovery');
  run := api.start_discovery_run(scope, NULL, 42);
  res := api.record_discovery((run ->> 'discovery_run_id')::uuid,
                              jsonb_build_array(pg_temp.rec('rt-quick', 'quick_helper_bot'),
                                                pg_temp.rec('rt-pay', 'payments_dispute_assistant')));
  IF (SELECT array_agg(x ->> 'change' ORDER BY x ->> 'external_id') FROM json_array_elements(res) x) <> ARRAY['new', 'new'] THEN
    RAISE EXCEPTION 'first record_discovery: %', res;
  END IF;
  -- records outside the run scope are rejected
  BEGIN
    PERFORM api.record_discovery((run ->> 'discovery_run_id')::uuid,
                                 jsonb_build_array(pg_temp.rec('rt-x', 'x') || '{"account_ref": "999999999999"}'));
    RAISE EXCEPTION 'out-of-scope record was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM api.complete_discovery_run((run ->> 'discovery_run_id')::uuid, 'succeeded', '{"agents": 2}', '[]');
  -- a completed run accepts no more records
  BEGIN
    PERFORM api.record_discovery((run ->> 'discovery_run_id')::uuid, jsonb_build_array(pg_temp.rec('rt-quick', 'quick_helper_bot')));
    RAISE EXCEPTION 'completed run accepted records';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM pg_temp.as_admin();
  INSERT INTO ctx VALUES ('gov', run ->> 'governance_run_id');

  SELECT count(*) INTO n FROM aigov.agent_snapshots;
  IF n <> 2 THEN RAISE EXCEPTION 'expected 2 snapshots, got %', n; END IF;
  SELECT count(*) INTO n FROM aigov.identity_permissions WHERE removed_at IS NULL;
  IF n <> 2 THEN RAISE EXCEPTION 'expected 2 current permissions, got %', n; END IF;
  IF (SELECT simulation ->> 'iam:CreateUser' FROM aigov.agent_identities LIMIT 1) <> 'allowed' THEN
    RAISE EXCEPTION 'identity simulation was not stored';
  END IF;
  IF (SELECT count(*) FROM aigov.audit_events WHERE event_type = 'discovery.agent_observed'
        AND actor_id = 'test-aigov_discovery' AND source_ref = '42') <> 2 THEN
    RAISE EXCEPTION 'discovery.agent_observed audit events missing or without the JWT subject';
  END IF;
END $$;

-- Re-recording identical content (a new collected_at) is idempotent: no snapshot, no audit event.
DO $$
DECLARE run json; res json; snaps int; events int;
BEGIN
  SELECT count(*) INTO snaps FROM aigov.agent_snapshots;
  SELECT count(*) INTO events FROM aigov.audit_events WHERE event_type IN ('discovery.agent_observed', 'agent.config_drift');
  PERFORM pg_temp.as_role('aigov_discovery');
  run := api.start_discovery_run('{"provider": "aws", "account_ref": "111122223333", "regions": ["us-west-1"]}', NULL, 43);
  res := api.record_discovery((run ->> 'discovery_run_id')::uuid,
                              jsonb_build_array(pg_temp.rec('rt-quick', 'quick_helper_bot'),
                                                pg_temp.rec('rt-pay', 'payments_dispute_assistant')));
  PERFORM pg_temp.as_admin();
  IF (SELECT array_agg(DISTINCT x ->> 'change') FROM json_array_elements(res) x) <> ARRAY['unchanged'] THEN
    RAISE EXCEPTION 'repeat record_discovery not unchanged: %', res;
  END IF;
  IF (SELECT count(*) FROM aigov.agent_snapshots) <> snaps
     OR (SELECT count(*) FROM aigov.audit_events WHERE event_type IN ('discovery.agent_observed', 'agent.config_drift')) <> events THEN
    RAISE EXCEPTION 'repeat record_discovery wrote snapshots or audit events';
  END IF;

  -- A changed policy is drift: new snapshot, old permission marked removed, agent.config_drift event.
  PERFORM pg_temp.as_role('aigov_discovery');
  res := api.record_discovery((run ->> 'discovery_run_id')::uuid,
           jsonb_build_array(pg_temp.rec('rt-pay', 'payments_dispute_assistant', NULL,
                                         'arn:aws:iam::111122223333:policy/aigov/payments-least-privilege')));
  PERFORM pg_temp.as_admin();
  IF res -> 0 ->> 'change' <> 'changed' THEN RAISE EXCEPTION 'drift not detected: %', res; END IF;
  IF (SELECT count(*) FROM aigov.agent_snapshots) <> snaps + 1 THEN RAISE EXCEPTION 'drift wrote no snapshot'; END IF;
  IF (SELECT count(*) FROM aigov.audit_events WHERE event_type = 'agent.config_drift') <> 1 THEN
    RAISE EXCEPTION 'agent.config_drift not audited';
  END IF;
  IF (SELECT count(*) FROM aigov.identity_permissions ip JOIN aigov.agent_identities i ON i.id = ip.identity_id
      WHERE i.principal_ref LIKE '%payments_dispute_assistant-role' AND ip.removed_at IS NULL
        AND ip.policy_ref LIKE '%payments-least-privilege') <> 1
     OR (SELECT count(*) FROM aigov.identity_permissions ip JOIN aigov.agent_identities i ON i.id = ip.identity_id
      WHERE i.principal_ref LIKE '%payments_dispute_assistant-role' AND ip.removed_at IS NULL
        AND ip.policy_ref LIKE '%AdministratorAccess') <> 0 THEN
    RAISE EXCEPTION 'permission set not replaced on drift';
  END IF;

  -- AccessDenied on identity keeps the known permissions
  PERFORM pg_temp.as_role('aigov_discovery');
  PERFORM api.record_discovery((run ->> 'discovery_run_id')::uuid,
           jsonb_build_array(jsonb_set(pg_temp.rec('rt-quick', 'quick_helper_bot') || '{"identity": {"principal_ref": "arn:aws:iam::111122223333:role/quick_helper_bot-role", "policies": []}}',
                                       '{evidence_status,identity}', '"access_denied"')));
  PERFORM pg_temp.as_admin();
  IF (SELECT count(*) FROM aigov.identity_permissions ip JOIN aigov.agent_identities i ON i.id = ip.identity_id
      WHERE i.principal_ref LIKE '%quick_helper_bot-role' AND ip.removed_at IS NULL) <> 1 THEN
    RAISE EXCEPTION 'access_denied evidence erased the known permissions';
  END IF;
  -- restore the collected record for the next steps
  PERFORM pg_temp.as_role('aigov_discovery');
  PERFORM api.record_discovery((run ->> 'discovery_run_id')::uuid, jsonb_build_array(pg_temp.rec('rt-quick', 'quick_helper_bot')));
  PERFORM api.complete_discovery_run((run ->> 'discovery_run_id')::uuid, 'succeeded', '{}', '[]');
  PERFORM pg_temp.as_admin();
END $$;

-- Missing agents: a succeeded run marks unseen agents in scope; a partial run does not.
DO $$
DECLARE run json; done json;
BEGIN
  UPDATE aigov.ai_agents SET last_seen_at = last_seen_at - interval '1 hour';   -- earlier runs happened before
  PERFORM pg_temp.as_role('aigov_discovery');
  run := api.start_discovery_run('{"provider": "aws", "account_ref": "111122223333", "regions": ["us-west-1"]}', NULL, 44);
  PERFORM pg_temp.as_admin();
  UPDATE aigov.discovery_runs SET started_at = now() - interval '1 minute' WHERE id = (run ->> 'discovery_run_id')::uuid;
  PERFORM pg_temp.as_role('aigov_discovery');
  PERFORM api.record_discovery((run ->> 'discovery_run_id')::uuid, jsonb_build_array(pg_temp.rec('rt-quick', 'quick_helper_bot')));
  done := api.complete_discovery_run((run ->> 'discovery_run_id')::uuid, 'partial', '{}', '[{"region": "us-west-1"}]');
  PERFORM pg_temp.as_admin();
  IF json_array_length(done -> 'missing') <> 0 THEN RAISE EXCEPTION 'partial run marked agents missing'; END IF;

  PERFORM pg_temp.as_role('aigov_discovery');
  run := api.start_discovery_run('{"provider": "aws", "account_ref": "111122223333", "regions": ["us-west-1"]}', NULL, 45);
  PERFORM pg_temp.as_admin();
  UPDATE aigov.ai_agents SET last_seen_at = now() - interval '2 minutes';
  UPDATE aigov.discovery_runs SET started_at = now() - interval '1 minute' WHERE id = (run ->> 'discovery_run_id')::uuid;
  PERFORM pg_temp.as_role('aigov_discovery');
  PERFORM api.record_discovery((run ->> 'discovery_run_id')::uuid, jsonb_build_array(pg_temp.rec('rt-quick', 'quick_helper_bot')));
  done := api.complete_discovery_run((run ->> 'discovery_run_id')::uuid, 'succeeded', '{}', '[]');
  PERFORM pg_temp.as_admin();
  IF json_array_length(done -> 'missing') <> 1 OR done -> 'missing' -> 0 ->> 'external_id' <> 'rt-pay' THEN
    RAISE EXCEPTION 'expected rt-pay missing, got %', done;
  END IF;
  -- seen again: missing_since is cleared
  PERFORM pg_temp.as_role('aigov_discovery');
  run := api.start_discovery_run('{"provider": "aws", "account_ref": "111122223333"}', NULL, 46);
  PERFORM api.record_discovery((run ->> 'discovery_run_id')::uuid,
           jsonb_build_array(pg_temp.rec('rt-pay', 'payments_dispute_assistant', NULL,
                                         'arn:aws:iam::111122223333:policy/aigov/payments-least-privilege')));
  PERFORM api.complete_discovery_run((run ->> 'discovery_run_id')::uuid, 'succeeded', '{}', '[]');
  PERFORM pg_temp.as_admin();
  IF (SELECT missing_since FROM aigov.ai_agents WHERE external_id = 'rt-pay') IS NOT NULL THEN
    RAISE EXCEPTION 'missing_since not cleared when the agent reappeared';
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------
-- 3. Registry: load, match, re-match on removal
-- ---------------------------------------------------------------------------------------------
DO $$
DECLARE res json; inp jsonb;
BEGIN
  PERFORM pg_temp.as_role('aigov_registry');
  res := api.load_registry(
    '[{"id": "own-payments", "name": "Payments ML", "email": "pay@example.com", "approved": true, "approved_by": "ciso", "approved_at": "2026-10-01"}]',
    '[{"registration_id": "REG-0001", "owner_id": "own-payments", "environment": "Production",
       "match_keys": {"provider": "aws", "platform": "aws.bedrock_agentcore_runtime", "name": "payments_dispute_assistant"},
       "declared_model": "amazon.nova-pro-v1:0", "data_classification": "confidential", "approved_tools": [],
       "risk_assessment": {"status": "complete", "completed_at": "2026-09-01", "expires_at": "2027-09-01"}}]',
    'abc1234');
  PERFORM pg_temp.as_admin();
  IF (res ->> 'registered_agents')::int <> 1 OR (res ->> 'unregistered_agents')::int <> 1 THEN
    RAISE EXCEPTION 'load_registry: %', res;
  END IF;
  IF (SELECT registration_id FROM aigov.ai_agents WHERE external_id = 'rt-pay') <> 'REG-0001' THEN
    RAISE EXCEPTION 'payments agent not matched to REG-0001';
  END IF;

  -- the evaluator sees the registration, with RFC 3339 dates and the effective registration evidence
  PERFORM pg_temp.as_role('aigov_evaluator');
  SELECT input INTO inp FROM api.evaluation_inputs e JOIN api.agent_overview o USING (agent_id) WHERE o.external_id = 'rt-pay';
  PERFORM pg_temp.as_admin();
  IF inp #>> '{registration,risk_assessment,expires_at}' <> '2027-09-01T00:00:00Z'
     OR inp #>> '{registration,owner,approved_at}' <> '2026-10-01T00:00:00Z'
     OR inp #>> '{registration,environment}' <> 'production'
     OR inp #>> '{evidence,registration}' <> 'collected'
     OR inp #>> '{agent,source_updated_at}' <> '2026-11-16T22:40:00Z'
     OR inp #>> '{identity,policies,0,ref}' NOT LIKE '%payments-least-privilege'
     OR inp ->> 'schema_version' <> '1.0' THEN
    RAISE EXCEPTION 'unexpected evaluation input: %', inp;
  END IF;

  -- reloading the same registry changes nothing; removing the registration unregisters the agent
  PERFORM pg_temp.as_role('aigov_registry');
  res := api.load_registry('[{"id": "own-payments", "name": "Payments ML"}]', '[]', 'def5678');
  PERFORM pg_temp.as_admin();
  IF (SELECT registration_status FROM aigov.ai_agents WHERE external_id = 'rt-pay') <> 'unregistered' THEN
    RAISE EXCEPTION 'agent still registered after its registration was removed';
  END IF;
  IF (SELECT count(*) FROM aigov.audit_events WHERE event_type = 'registry.loaded') <> 2 THEN
    RAISE EXCEPTION 'registry.loaded not audited';
  END IF;
  BEGIN
    PERFORM pg_temp.as_role('aigov_registry');
    PERFORM api.load_registry('[]', '[{"registration_id": "REG-X", "match_keys": {}}]', NULL);
    RAISE EXCEPTION 'empty match_keys accepted (would match every agent)';
  EXCEPTION WHEN invalid_parameter_value THEN PERFORM pg_temp.as_admin();
  END;
END $$;

-- ---------------------------------------------------------------------------------------------
-- 4. Evaluation and the finding lifecycle; AI explanations
-- ---------------------------------------------------------------------------------------------
DO $$
DECLARE
  agent uuid := (SELECT id FROM aigov.ai_agents WHERE external_id = 'rt-quick');
  gov uuid := (SELECT v::uuid FROM ctx WHERE k = 'gov');
  res json; n int; fid uuid;
  fail_result jsonb := jsonb_build_object(
    'agent_id', (SELECT id FROM aigov.ai_agents WHERE external_id = 'rt-quick'),
    'overall_status', 'noncompliant', 'bundle_revision', 'a1b2c3d',
    'risk', '{"score": 100, "category": "critical", "factors": [{"factor": "admin_permissions", "points": 40}]}'::jsonb,
    'summary', '{"pass": 1, "fail": 1, "unknown": 1}'::jsonb,
    'results', '[{"policy_id": "AIGOV-IAM-001", "policy_version": "1.0.0", "decision": "fail", "severity": "critical",
                  "explanation": "AdministratorAccess attached", "evidence": [{"path": "identity.policies[0].ref"}],
                  "controls": ["ENT-IAM-LEAST-PRIVILEGE"], "assumptions": ["environment_assumed_production"]},
                 {"policy_id": "AIGOV-MDL-001", "policy_version": "1.0.0", "decision": "unknown", "severity": "medium",
                  "explanation": "model evidence is not_supported"},
                 {"policy_id": "AIGOV-GRD-001", "policy_version": "1.0.0", "decision": "not_applicable", "severity": "info",
                  "explanation": "n/a"}]'::jsonb);
BEGIN
  PERFORM pg_temp.as_role('aigov_evaluator');
  res := api.record_evaluation(gov, agent, 'assessment', fail_result, 'hash-1', 'opa-dec-1');
  PERFORM pg_temp.as_admin();
  IF (res -> 'findings' ->> 'opened')::int <> 2 THEN RAISE EXCEPTION 'expected 2 findings opened: %', res; END IF;
  IF (SELECT compliance_status || '/' || risk_score || '/' || risk_category FROM aigov.ai_agents WHERE id = agent) <> 'noncompliant/100/critical' THEN
    RAISE EXCEPTION 'agent status not updated';
  END IF;
  IF (SELECT finding_type FROM aigov.findings WHERE agent_id = agent AND policy_id = 'AIGOV-MDL-001') <> 'insufficient_evidence' THEN
    RAISE EXCEPTION 'unknown did not open an insufficient_evidence finding';
  END IF;
  IF (SELECT actor_type || ':' || actor_id || ':' || source_ref FROM aigov.audit_events WHERE event_type = 'policy.evaluated')
     <> 'policy:opa:a1b2c3d:opa-dec-1' THEN
    RAISE EXCEPTION 'policy.evaluated audit actor or source_ref wrong';
  END IF;

  -- same result again: findings refreshed, none opened
  PERFORM pg_temp.as_role('aigov_evaluator');
  res := api.record_evaluation(gov, agent, 'assessment', fail_result, 'hash-1', 'opa-dec-2');
  PERFORM pg_temp.as_admin();
  IF (res -> 'findings' ->> 'opened')::int <> 0 OR (res -> 'findings' ->> 'refreshed')::int <> 2 THEN
    RAISE EXCEPTION 'repeat evaluation: %', res;
  END IF;

  -- pre_remediation evaluations never change findings
  PERFORM pg_temp.as_role('aigov_evaluator');
  res := api.record_evaluation(gov, agent, 'pre_remediation',
           jsonb_set(fail_result, '{results,0,decision}', '"pass"'), 'hash-1', NULL);
  PERFORM pg_temp.as_admin();
  IF (SELECT count(*) FROM aigov.findings WHERE agent_id = agent AND status = 'open') <> 2 THEN
    RAISE EXCEPTION 'pre_remediation evaluation changed findings';
  END IF;

  -- AI explanation on an open finding; skip unknown ids; free text is trimmed, extra keys dropped
  SELECT id INTO fid FROM aigov.findings WHERE agent_id = agent AND policy_id = 'AIGOV-IAM-001';
  PERFORM pg_temp.as_role('aigov_evaluator');
  res := api.record_explanations(gov, jsonb_build_array(
           jsonb_build_object('finding_id', fid, 'headline', repeat('x', 3000), 'risk_explanation', 'r',
                              'override_decision', 'pass'),
           jsonb_build_object('finding_id', gen_random_uuid(), 'headline', 'h')), 'llama-scout-17b');
  PERFORM pg_temp.as_admin();
  IF (res ->> 'updated')::int <> 1 OR json_array_length(res -> 'skipped') <> 1 THEN RAISE EXCEPTION 'record_explanations: %', res; END IF;
  IF (SELECT length(ai_explanation ->> 'headline') FROM aigov.findings WHERE id = fid) <> 2000
     OR (SELECT ai_explanation ? 'override_decision' FROM aigov.findings WHERE id = fid)
     OR (SELECT (ai_explanation ->> 'advisory')::boolean FROM aigov.findings WHERE id = fid) IS NOT TRUE THEN
    RAISE EXCEPTION 'ai_explanation not sanitized';
  END IF;
  IF (SELECT actor_type || ':' || actor_id FROM aigov.audit_events WHERE event_type = 'ai.explanation_generated') <> 'ai:llm:llama-scout-17b' THEN
    RAISE EXCEPTION 'ai.explanation_generated audit actor wrong';
  END IF;

  -- IAM-001 now unknown: the violation stays open (fail closed); MDL-001 now passes: auto-closed
  PERFORM pg_temp.as_role('aigov_evaluator');
  res := api.record_evaluation(gov, agent, 'assessment',
           jsonb_set(jsonb_set(fail_result, '{results,0,decision}', '"unknown"'), '{results,1,decision}', '"pass"'),
           'hash-2', 'opa-dec-3');
  PERFORM pg_temp.as_admin();
  IF (SELECT status FROM aigov.findings WHERE agent_id = agent AND policy_id = 'AIGOV-IAM-001' AND finding_type = 'violation') <> 'open' THEN
    RAISE EXCEPTION 'violation closed on unknown evidence';
  END IF;
  IF EXISTS (SELECT FROM aigov.findings WHERE agent_id = agent AND policy_id = 'AIGOV-IAM-001' AND finding_type = 'insufficient_evidence') THEN
    RAISE EXCEPTION 'insufficient_evidence finding opened next to an open violation';
  END IF;
  IF (SELECT status || '/' || resolution FROM aigov.findings WHERE agent_id = agent AND policy_id = 'AIGOV-MDL-001') <> 'resolved/no_longer_detected' THEN
    RAISE EXCEPTION 'insufficient_evidence finding not auto-closed on pass';
  END IF;

  -- IAM-001 passes: the violation auto-closes
  PERFORM pg_temp.as_role('aigov_evaluator');
  res := api.record_evaluation(gov, agent, 'assessment',
           jsonb_set(jsonb_set(fail_result, '{results,0,decision}', '"pass"'), '{results,1,decision}', '"pass"')
             || '{"overall_status": "compliant", "risk": {"score": 10, "category": "low", "factors": []}}', 'hash-3', 'opa-dec-4');
  PERFORM pg_temp.as_admin();
  SELECT count(*) INTO n FROM aigov.findings WHERE agent_id = agent AND status = 'open';
  IF n <> 0 THEN RAISE EXCEPTION 'expected no open findings, got %', n; END IF;

  -- a fail after a resolved finding opens a new one (the partial unique index allows it)
  PERFORM pg_temp.as_role('aigov_evaluator');
  res := api.record_evaluation(gov, agent, 'assessment', fail_result, 'hash-4', 'opa-dec-5');
  PERFORM pg_temp.as_admin();
  IF (SELECT count(*) FROM aigov.findings WHERE agent_id = agent AND policy_id = 'AIGOV-IAM-001') <> 2 THEN
    RAISE EXCEPTION 'regression did not open a new finding';
  END IF;

  -- invalid results are rejected
  BEGIN
    PERFORM pg_temp.as_role('aigov_evaluator');
    PERFORM api.record_evaluation(gov, agent, 'assessment', '{"overall_status": "great"}', 'h', NULL);
    RAISE EXCEPTION 'invalid result accepted';
  EXCEPTION WHEN invalid_parameter_value THEN PERFORM pg_temp.as_admin();
  END;
  BEGIN
    PERFORM pg_temp.as_role('aigov_evaluator');
    PERFORM api.record_evaluation(gov, agent, 'assessment', fail_result || jsonb_build_object('agent_id', gen_random_uuid()), 'h', NULL);
    RAISE EXCEPTION 'result for another agent accepted';
  EXCEPTION WHEN invalid_parameter_value THEN PERFORM pg_temp.as_admin();
  END;
END $$;

-- ---------------------------------------------------------------------------------------------
-- 5. Generic audit append, reader views, and the audit chain after all of the above
-- ---------------------------------------------------------------------------------------------
DO $$
DECLARE res json; n int; r record;
BEGIN
  PERFORM pg_temp.as_role('aigov_discovery');
  res := api.append_audit_event('{"event_type": "discovery.scope_skipped", "details": {"region": "eu-west-1"}}');
  PERFORM pg_temp.as_admin();
  IF (SELECT actor_id || '/' || (details ->> 'recorded_by') FROM aigov.audit_events WHERE id = (res ->> 'id')::bigint)
     <> 'test-aigov_discovery/test-aigov_discovery' THEN
    RAISE EXCEPTION 'append_audit_event actor wrong';
  END IF;
  BEGIN
    PERFORM pg_temp.as_role('aigov_discovery');
    PERFORM api.append_audit_event('{"event_type": "DROP TABLE"}');
    RAISE EXCEPTION 'invalid event_type accepted';
  EXCEPTION WHEN invalid_parameter_value THEN PERFORM pg_temp.as_admin();
  END;

  PERFORM pg_temp.as_role('aigov_reader');
  SELECT count(*) INTO n FROM api.agent_overview;
  IF n <> 2 THEN RAISE EXCEPTION 'agent_overview rows: %', n; END IF;
  SELECT count(*) INTO n FROM api.findings_open;
  IF n < 1 THEN RAISE EXCEPTION 'findings_open is empty'; END IF;
  PERFORM pg_temp.as_admin();

  SELECT count(*) INTO n FROM aigov.verify_audit_chain();
  IF n <> 0 THEN
    SELECT * INTO r FROM aigov.verify_audit_chain();
    RAISE EXCEPTION 'audit chain broken at % (%)', r.broken_id, r.reason;
  END IF;
END $$;

ROLLBACK;
\echo 'test_v002_api: all assertions passed'
