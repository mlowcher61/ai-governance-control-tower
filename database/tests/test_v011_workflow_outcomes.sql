-- SQL assertions for V011: the WF-02 outcomes are accepted and audited; unknown outcomes are still refused.
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000f101', 'aws', '999900001111');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash)
VALUES ('00000000-0000-0000-0000-00000000f102', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000f101', 'r', 'o1', 'arn:o1', 'o1', 'h');
INSERT INTO aigov.findings (id, agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation)
VALUES ('00000000-0000-0000-0000-00000000f103', '00000000-0000-0000-0000-00000000f102', 'AIGOV-MDL-001', 'insufficient_evidence', 'medium', 'f', 'x');
DO $$
DECLARE o text; r json; ok boolean;
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  FOREACH o IN ARRAY ARRAY['no_longer_detected', 'missing_evidence', 'assessment_error', 'halted'] LOOP
    r := api.record_outcome('00000000-0000-0000-0000-00000000f104', '00000000-0000-0000-0000-00000000f103', o, '["t"]');
    IF r ->> 'outcome' <> o OR r ->> 'cooldown_until' IS NOT NULL THEN RAISE EXCEPTION 'outcome % wrong: %', o, r; END IF;
  END LOOP;
  ok := false;
  BEGIN PERFORM api.record_outcome('00000000-0000-0000-0000-00000000f104', '00000000-0000-0000-0000-00000000f103', 'made_up');
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'unknown outcome accepted'; END IF;
  RESET ROLE;
  IF (SELECT count(*) FROM aigov.audit_events WHERE event_type = 'remediation.outcome' AND finding_id = '00000000-0000-0000-0000-00000000f103') <> 4 THEN
    RAISE EXCEPTION 'outcomes not audited';
  END IF;
END $$;
ROLLBACK;
\echo 'test_v011_workflow_outcomes: all assertions passed'
