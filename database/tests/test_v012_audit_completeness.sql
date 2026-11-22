-- SQL assertions for V012: api.audit_completeness finds missing lifecycle events and a broken hash chain.
\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  IF NOT has_function_privilege('aigov_remediator', 'api.audit_completeness(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('aigov_auditor', 'api.audit_completeness(uuid)', 'EXECUTE')
     OR has_function_privilege('aigov_reader', 'api.audit_completeness(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'audit_completeness grants are wrong';
  END IF;
END $$;

INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000c201', 'aws', '121212121212');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash)
VALUES ('00000000-0000-0000-0000-00000000c202', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000c201', 'r', 'c1', 'arn:c1', 'c1', 'h');
INSERT INTO aigov.findings (id, agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation) VALUES
  ('00000000-0000-0000-0000-00000000c203', '00000000-0000-0000-0000-00000000c202', 'AIGOV-IAM-001', 'violation', 'critical', 'f1', 'x'),
  ('00000000-0000-0000-0000-00000000c204', '00000000-0000-0000-0000-00000000c202', 'AIGOV-TAG-001', 'violation', 'medium', 'f2', 'x');
INSERT INTO aigov.governance_runs (id, run_type, trigger_type) VALUES
  ('00000000-0000-0000-0000-00000000c205', 'remediation', 'manual'), ('00000000-0000-0000-0000-00000000c206', 'remediation', 'manual');
-- Run 1: a verified remediation with every event. Run 2: rolled back, but the rollback approval event is missing.
INSERT INTO aigov.remediation_actions (id, governance_run_id, finding_id, action_type, mode, status, authz_decision, attempt_number) VALUES
  ('00000000-0000-0000-0000-00000000c207', '00000000-0000-0000-0000-00000000c205', '00000000-0000-0000-0000-00000000c203',
   'iam_replace_managed_policy', 'enforce', 'verified', '{"approval_required": "yes"}', 1),
  ('00000000-0000-0000-0000-00000000c208', '00000000-0000-0000-0000-00000000c206', '00000000-0000-0000-0000-00000000c204',
   'agentcore_apply_governance_tags', 'enforce', 'rolled_back', '{"approval_required": "yes"}', 1);
DO $$
DECLARE g1 uuid := '00000000-0000-0000-0000-00000000c205'; g2 uuid := '00000000-0000-0000-0000-00000000c206';
        r1 uuid := '00000000-0000-0000-0000-00000000c207'; r2 uuid := '00000000-0000-0000-0000-00000000c208';
        a uuid := '00000000-0000-0000-0000-00000000c202'; ev text;
BEGIN
  FOREACH ev IN ARRAY ARRAY['remediation.planned', 'remediation.executing', 'remediation.executed', 'verification.passed', 'finding.resolved'] LOOP
    PERFORM aigov.audit(ev, 'service', 't', 'aap', g1, a, NULL, NULL, '{}', r1);
  END LOOP;
  PERFORM aigov.audit('approval.decided', 'human', 'approver', 'ao', g1, a, NULL, NULL, '{"kind": "remediation", "decision": "approved"}', r1);
  PERFORM aigov.audit('remediation.outcome', 'service', 't', 'aap', g1, a, NULL, NULL, '{"outcome": "remediated"}', r1);
  FOREACH ev IN ARRAY ARRAY['remediation.planned', 'remediation.executing', 'remediation.executed', 'verification.failed', 'rollback.executed', 'remediation.outcome'] LOOP
    PERFORM aigov.audit(ev, 'service', 't', 'aap', g2, a, NULL, NULL, '{}', r2);
  END LOOP;
  PERFORM aigov.audit('approval.decided', 'human', 'approver', 'ao', g2, a, NULL, NULL, '{"kind": "remediation", "decision": "approved"}', r2);
END $$;

DO $$
DECLARE r json; ok boolean;
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  r := api.audit_completeness('00000000-0000-0000-0000-00000000c205');
  IF NOT (r ->> 'complete')::boolean OR json_array_length(r -> 'missing') <> 0 THEN RAISE EXCEPTION 'complete run reported incomplete: %', r; END IF;
  r := api.audit_completeness('00000000-0000-0000-0000-00000000c206');
  IF (r ->> 'complete')::boolean OR r -> 'missing' ->> 0 NOT LIKE 'rollback approved and recorded%' THEN
    RAISE EXCEPTION 'missing rollback approval not found: %', r;
  END IF;
  ok := false;
  BEGIN PERFORM api.audit_completeness('00000000-0000-0000-0000-0000000000ff'); EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'a run without events was accepted'; END IF;
  RESET ROLE;
END $$;

-- Tampering with an event of run 1 breaks the chain, and the run is no longer complete
ALTER TABLE aigov.audit_events DISABLE TRIGGER audit_events_immutable;
UPDATE aigov.audit_events SET details = '{"outcome": "forged"}'
WHERE governance_run_id = '00000000-0000-0000-0000-00000000c205' AND event_type = 'remediation.outcome';
ALTER TABLE aigov.audit_events ENABLE TRIGGER audit_events_immutable;
DO $$
DECLARE r json;
BEGIN
  r := api.audit_completeness('00000000-0000-0000-0000-00000000c205');
  IF (r ->> 'complete')::boolean OR r::text NOT LIKE '%audit hash chain intact%' THEN RAISE EXCEPTION 'tampering not detected: %', r; END IF;
END $$;
ROLLBACK;
\echo 'test_v012_audit_completeness: all assertions passed'
