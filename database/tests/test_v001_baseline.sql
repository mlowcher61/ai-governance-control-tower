-- SQL assertions for V001 (T1.01). Run as the database owner after bootstrap + migrations.
-- Every block raises on failure; the test run stops at the first error (ON_ERROR_STOP).
\set ON_ERROR_STOP on
BEGIN;

-- 1. Every Stage 1-3 table exists
DO $$
DECLARE missing text[];
BEGIN
  SELECT array_agg(t) INTO missing FROM unnest(ARRAY[
    'cloud_accounts', 'owners', 'agent_registrations', 'ai_models', 'agent_identities', 'ai_agents',
    'agent_tools', 'agent_data_sources', 'identity_permissions', 'governance_runs', 'discovery_runs',
    'agent_snapshots', 'policy_evaluations', 'policy_results', 'findings', 'remediation_actions',
    'approvals', 'audit_events', 'schema_migrations']) AS t
  WHERE to_regclass('aigov.' || t) IS NULL;
  IF missing IS NOT NULL THEN RAISE EXCEPTION 'missing tables: %', missing; END IF;
END $$;

-- 2. Audit chain: inserts are chained, and the chain verifies
INSERT INTO aigov.audit_events (event_type, actor_type, actor_id, source_system, details)
VALUES ('test.one', 'service', 'svc-test', 'db', '{"n": 1}'),
       ('test.two', 'policy', 'opa:test', 'opa', '{"n": 2}'),
       ('test.three', 'human', 'jdoe-abc', 'ao', '{"n": 3}');
DO $$
DECLARE r record; n int;
BEGIN
  SELECT count(*) INTO n FROM aigov.verify_audit_chain();
  IF n <> 0 THEN
    SELECT * INTO r FROM aigov.verify_audit_chain();
    RAISE EXCEPTION 'audit chain broken at % (%)', r.broken_id, r.reason;
  END IF;
  SELECT count(*) INTO n FROM aigov.audit_events a
  JOIN aigov.audit_events b ON b.id = (SELECT min(id) FROM aigov.audit_events WHERE id > a.id)
  WHERE b.prev_hash <> a.hash;
  IF n <> 0 THEN RAISE EXCEPTION 'audit rows are not linked by prev_hash'; END IF;
END $$;

-- 3. Audit log is immutable: UPDATE, DELETE and TRUNCATE are rejected
DO $$
BEGIN
  BEGIN
    UPDATE aigov.audit_events SET actor_id = 'tampered';
    RAISE EXCEPTION 'UPDATE on audit_events was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    DELETE FROM aigov.audit_events;
    RAISE EXCEPTION 'DELETE on audit_events was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    TRUNCATE aigov.audit_events;
    RAISE EXCEPTION 'TRUNCATE on audit_events was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

-- 4. One open finding per agent/policy/fingerprint; a resolved one does not block a new one
INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-0000000000a1', 'aws', '111122223333');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash)
VALUES ('00000000-0000-0000-0000-0000000000b1', 'aws', 'aws.bedrock_agentcore_runtime',
        '00000000-0000-0000-0000-0000000000a1', 'us-west-1', 'rt-1', 'arn:aws:test', 'test-agent', 'h');
INSERT INTO aigov.findings (agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation)
VALUES ('00000000-0000-0000-0000-0000000000b1', 'AIGOV-IAM-001', 'violation', 'critical', 'fp1', 'admin role');
DO $$
BEGIN
  BEGIN
    INSERT INTO aigov.findings (agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation)
    VALUES ('00000000-0000-0000-0000-0000000000b1', 'AIGOV-IAM-001', 'violation', 'critical', 'fp1', 'dup');
    RAISE EXCEPTION 'a second open finding with the same fingerprint was allowed';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END $$;
UPDATE aigov.findings SET status = 'resolved', resolved_at = now() WHERE fingerprint = 'fp1';
INSERT INTO aigov.findings (agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation)
VALUES ('00000000-0000-0000-0000-0000000000b1', 'AIGOV-IAM-001', 'violation', 'critical', 'fp1', 'recurred');

-- 5. At most one active remediation per finding
INSERT INTO aigov.governance_runs (id, run_type, trigger_type) VALUES ('00000000-0000-0000-0000-0000000000c1', 'remediation', 'manual');
INSERT INTO aigov.remediation_actions (governance_run_id, finding_id, action_type, mode, status, authz_decision, attempt_number)
SELECT '00000000-0000-0000-0000-0000000000c1', id, 'replace_managed_policy', 'enforce', 'planned', '{}', 1
FROM aigov.findings WHERE status = 'open' AND fingerprint = 'fp1';
DO $$
BEGIN
  BEGIN
    INSERT INTO aigov.remediation_actions (governance_run_id, finding_id, action_type, mode, status, authz_decision, attempt_number)
    SELECT '00000000-0000-0000-0000-0000000000c1', id, 'replace_managed_policy', 'enforce', 'executing', '{}', 2
    FROM aigov.findings WHERE status = 'open' AND fingerprint = 'fp1';
    RAISE EXCEPTION 'a second active remediation for the same finding was allowed';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END $$;

-- 6. Grants: API roles cannot touch aigov tables directly; auditors can only read the audit log
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['aigov_api_anon', 'aigov_discovery', 'aigov_registry', 'aigov_evaluator',
                           'aigov_remediator', 'aigov_reader', 'grafana_ro'] LOOP
    FOREACH t IN ARRAY ARRAY['aigov.ai_agents', 'aigov.findings', 'aigov.audit_events'] LOOP
      IF has_table_privilege(r, t, 'SELECT') OR has_table_privilege(r, t, 'INSERT')
         OR has_table_privilege(r, t, 'UPDATE') THEN
        RAISE EXCEPTION 'role % has direct access to %', r, t;
      END IF;
    END LOOP;
  END LOOP;
  IF NOT has_table_privilege('aigov_auditor', 'aigov.audit_events', 'SELECT') THEN
    RAISE EXCEPTION 'aigov_auditor cannot read the audit log';
  END IF;
  IF has_table_privilege('aigov_auditor', 'aigov.audit_events', 'INSERT')
     OR has_table_privilege('aigov_auditor', 'aigov.ai_agents', 'SELECT') THEN
    RAISE EXCEPTION 'aigov_auditor has more than read access to the audit log';
  END IF;
END $$;

ROLLBACK;
\echo 'test_v001_baseline: all assertions passed'
