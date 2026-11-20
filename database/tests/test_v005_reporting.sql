-- SQL assertions for V005: the reporting views behind the Grafana dashboards.
\set ON_ERROR_STOP on
BEGIN;

-- Grafana reads every reporting view and nothing in aigov
DO $$
DECLARE v record; bad text[] := '{}';
BEGIN
  FOR v IN SELECT c.oid::regclass::text AS rel FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'reporting' AND c.relkind = 'v' LOOP
    IF NOT has_table_privilege('grafana_ro', v.rel, 'SELECT') THEN bad := bad || ('grafana_ro cannot read ' || v.rel); END IF;
    IF NOT has_table_privilege('aigov_auditor', v.rel, 'SELECT') THEN bad := bad || ('aigov_auditor cannot read ' || v.rel); END IF;
    IF has_table_privilege('aigov_discovery', v.rel, 'SELECT') THEN bad := bad || ('aigov_discovery can read ' || v.rel); END IF;
  END LOOP;
  FOR v IN SELECT c.oid::regclass::text AS rel FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'aigov' AND c.relkind = 'r' LOOP
    IF has_table_privilege('grafana_ro', v.rel, 'SELECT') THEN bad := bad || ('grafana_ro can read ' || v.rel); END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_views WHERE schemaname = 'reporting') < 11 THEN bad := bad || 'reporting views missing'::text; END IF;
  IF cardinality(bad) > 0 THEN RAISE EXCEPTION '%', bad; END IF;
END $$;

-- Data: one admin agent evaluated twice (the latest result wins), one missing agent (hidden)
INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-0000000000d1', 'aws', '333344445555');
INSERT INTO aigov.agent_identities (id, provider, principal_ref, collected_at)
VALUES ('00000000-0000-0000-0000-0000000000d2', 'aws', 'arn:aws:iam::333344445555:role/r', now());
INSERT INTO aigov.identity_permissions (identity_id, policy_type, policy_ref, policy_name, document, document_hash, collected_at)
VALUES ('00000000-0000-0000-0000-0000000000d2', 'aws_managed', 'arn:aws:iam::aws:policy/AdministratorAccess', 'AdministratorAccess',
        '[{"effect": "Allow", "actions": ["*"], "resources": ["*"]}]', 'h1', now());
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash, identity_id)
VALUES ('00000000-0000-0000-0000-0000000000d3', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-0000000000d1',
        'us-west-1', 'rt-a', 'arn:a', 'admin_bot', 'h', '00000000-0000-0000-0000-0000000000d2'),
       ('00000000-0000-0000-0000-0000000000d4', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-0000000000d1',
        'us-west-1', 'rt-gone', 'arn:g', 'gone_bot', 'h', NULL);
UPDATE aigov.ai_agents SET missing_since = now() WHERE id = '00000000-0000-0000-0000-0000000000d4';
INSERT INTO aigov.governance_runs (id, run_type, trigger_type) VALUES ('00000000-0000-0000-0000-0000000000d5', 'assessment', 'manual');
INSERT INTO aigov.policy_evaluations (id, governance_run_id, agent_id, bundle_revision, input_hash, overall_status, risk_score, risk_category, risk_factors, evaluated_at)
VALUES ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000d5', '00000000-0000-0000-0000-0000000000d3', 'r1', 'i', 'compliant', 0, 'low', '[]', now() - interval '2 days'),
       ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000d5', '00000000-0000-0000-0000-0000000000d3', 'r2', 'i', 'noncompliant', 55, 'high',
        '[{"factor": "admin_permissions", "points": 40}, {"factor": "unregistered_agent", "points": 15}]', now());
INSERT INTO aigov.policy_results (evaluation_id, policy_id, policy_version, decision, severity, explanation, evidence)
VALUES ('00000000-0000-0000-0000-0000000000e2', 'AIGOV-IAM-001', '1.0.0', 'fail', 'critical', 'admin',
        '[{"path": "identity.policies", "value": {"source": "arn:aws:iam::aws:policy/AdministratorAccess", "reason": "x"}}]'),
       ('00000000-0000-0000-0000-0000000000e2', 'AIGOV-MDL-001', '1.0.0', 'unknown', 'medium', 'model unknown', '[]'),
       ('00000000-0000-0000-0000-0000000000e2', 'AIGOV-REG-001', '1.0.0', 'fail', 'high', 'shadow', '[]'),
       ('00000000-0000-0000-0000-0000000000e2', 'AIGOV-GRD-001', '1.0.0', 'not_applicable', 'medium', 'n/a', '[]');
INSERT INTO aigov.findings (agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation, ai_explanation, first_detected_at)
VALUES ('00000000-0000-0000-0000-0000000000d3', 'AIGOV-IAM-001', 'violation', 'critical', 'f1', 'admin',
        '{"headline": "Agent can act as an administrator"}', now() - interval '3 days');
UPDATE aigov.ai_agents SET compliance_status = 'noncompliant', risk_score = 55, risk_category = 'high' WHERE id = '00000000-0000-0000-0000-0000000000d3';

SET LOCAL ROLE grafana_ro;
DO $$
BEGIN
  IF (SELECT count(*) FROM reporting.agent_current) <> 1 THEN RAISE EXCEPTION 'missing agent shown in agent_current'; END IF;
  IF (SELECT risk_category || '/' || open_findings FROM reporting.agent_current) <> 'high/1' THEN RAISE EXCEPTION 'agent_current values wrong'; END IF;
  IF (SELECT overall_status FROM reporting.latest_evaluation) <> 'noncompliant' THEN RAISE EXCEPTION 'latest_evaluation is not the latest'; END IF;
  IF (SELECT ai_headline FROM reporting.policy_results_latest WHERE policy_id = 'AIGOV-IAM-001') <> 'Agent can act as an administrator' THEN
    RAISE EXCEPTION 'AI headline not joined to the policy result';
  END IF;
  IF (SELECT sum(points) FROM reporting.agent_risk_factors) <> 55 THEN RAISE EXCEPTION 'risk factors wrong'; END IF;
  IF NOT (SELECT flagged_admin AND grants_all_actions FROM reporting.agent_permissions) THEN RAISE EXCEPTION 'admin policy not flagged'; END IF;
  IF (SELECT coverage_pct FROM reporting.evidence_coverage) <> 75.0 THEN RAISE EXCEPTION 'evidence coverage wrong'; END IF;
  IF (SELECT count(*) FROM reporting.compliance_daily) <> 2 THEN RAISE EXCEPTION 'compliance_daily should have two days'; END IF;
  IF (SELECT age_days FROM reporting.findings_open) < 2.9 THEN RAISE EXCEPTION 'finding age wrong'; END IF;
  IF (SELECT agents_evaluated FROM reporting.governance_runs_recent WHERE governance_run_id = '00000000-0000-0000-0000-0000000000d5') <> 1 THEN
    RAISE EXCEPTION 'governance run counts wrong';
  END IF;
  -- grafana_ro cannot reach the base tables
  BEGIN
    PERFORM count(*) FROM aigov.ai_agents;
    RAISE EXCEPTION 'grafana_ro read a base table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

ROLLBACK;
\echo 'test_v005_reporting: all assertions passed'
