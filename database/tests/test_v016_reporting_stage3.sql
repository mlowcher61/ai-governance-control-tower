-- SQL assertions for V016: the Stage 3 reporting returns correct figures on seeded history - daily compliance
-- snapshots, time to detect (event-attributed findings), time to remediate (automatic and after approval), and the
-- operations views (remediations, pending approvals, funnel, change events, drift).
-- History is seeded on 2001-02-03 and 2001-02-04 so the daily figures are independent of other test data.
\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  IF NOT has_function_privilege('aigov_remediator', 'api.capture_compliance_snapshot()', 'EXECUTE')
     OR has_function_privilege('aigov_reader', 'api.capture_compliance_snapshot()', 'EXECUTE')
     OR has_function_privilege('grafana_ro', 'api.capture_compliance_snapshot()', 'EXECUTE') THEN
    RAISE EXCEPTION 'capture_compliance_snapshot grants are wrong';
  END IF;
  IF has_table_privilege('grafana_ro', 'aigov.compliance_snapshots', 'SELECT')
     OR NOT has_table_privilege('grafana_ro', 'reporting.compliance_trend', 'SELECT')
     OR NOT has_table_privilege('aigov_auditor', 'reporting.mttr_daily', 'SELECT') THEN
    RAISE EXCEPTION 'snapshot table or view grants are wrong';
  END IF;
END $$;

-- Baselines (other test data may exist): the snapshot and funnel are checked as differences
CREATE TEMP TABLE t_before AS
SELECT (api.capture_compliance_snapshot())::jsonb AS snap,
       (SELECT jsonb_object_agg(stage, remediations) FROM reporting.remediation_funnel) AS funnel;

INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000f601', 'aws', '616161616161');
INSERT INTO aigov.governance_runs (id, run_type, trigger_type) VALUES ('00000000-0000-0000-0000-00000000f602', 'remediation', 'manual');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash,
                             compliance_status, registration_status, missing_since) VALUES
  ('00000000-0000-0000-0000-00000000f611', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000f601', 'r', 'm1', 'arn:m1', 'metrics-one', 'h', 'noncompliant', 'registered', NULL),
  ('00000000-0000-0000-0000-00000000f612', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000f601', 'r', 'm2', 'arn:m2', 'metrics-two', 'h', 'compliant', 'unregistered', NULL),
  ('00000000-0000-0000-0000-00000000f613', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000f601', 'r', 'm3', 'arn:m3', 'metrics-gone', 'h', 'noncompliant', 'registered', now() - interval '3 days');

-- An AWS change event and the event-triggered targeted re-assessment it started
INSERT INTO aigov.change_events (id, event_id, received_at, event_time, event_source, event_name, status, agent_ids, ao_execution_id, raw) VALUES
  ('00000000-0000-0000-0000-00000000f641', 'ce-m1', '2001-02-03 10:00:30+00', '2001-02-03 10:00:00+00', 'iam.amazonaws.com', 'AttachRolePolicy', 'mapped',
   ARRAY['00000000-0000-0000-0000-00000000f611']::uuid[], 'exec-1', '{}'),
  ('00000000-0000-0000-0000-00000000f642', 'ce-m2', '2001-02-03 11:00:10+00', '2001-02-03 11:00:00+00', 'iam.amazonaws.com', 'GetRole', 'ignored', '{}', NULL, '{}'),
  ('00000000-0000-0000-0000-00000000f643', 'ce-m3', '2001-02-03 12:00:20+00', '2001-02-03 12:00:00+00', 'iam.amazonaws.com', 'PutRolePolicy', 'suppressed',
   ARRAY['00000000-0000-0000-0000-00000000f611']::uuid[], NULL, '{}');
INSERT INTO aigov.governance_runs (id, run_type, trigger_type, trigger_ref) VALUES
  ('00000000-0000-0000-0000-00000000f603', 'targeted_reassessment', 'event', '00000000-0000-0000-0000-00000000f641');

-- Findings: two event-attributed (detected 2 and 4 minutes after the change), two remediated, one open on the
-- missing agent (excluded), one open without a change time
INSERT INTO aigov.findings (id, agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation, status,
                            first_detected_at, source_change_at, resolved_at, resolution) VALUES
  ('00000000-0000-0000-0000-00000000f621', '00000000-0000-0000-0000-00000000f611', 'AIGOV-IAM-001', 'violation', 'critical', 'g1', 'x', 'open',
   '2001-02-03 10:02:00+00', '2001-02-03 10:00:00+00', NULL, NULL),
  ('00000000-0000-0000-0000-00000000f622', '00000000-0000-0000-0000-00000000f611', 'AIGOV-IAM-002', 'violation', 'high', 'g2', 'x', 'awaiting_approval',
   '2001-02-03 10:04:00+00', '2001-02-03 10:00:00+00', NULL, NULL),
  ('00000000-0000-0000-0000-00000000f623', '00000000-0000-0000-0000-00000000f612', 'AIGOV-TAG-001', 'violation', 'medium', 'g3', 'x', 'resolved',
   '2001-02-04 08:00:00+00', NULL, '2001-02-04 08:30:00+00', 'remediated'),
  ('00000000-0000-0000-0000-00000000f624', '00000000-0000-0000-0000-00000000f612', 'AIGOV-REG-001', 'violation', 'high', 'g4', 'x', 'resolved',
   '2001-02-04 09:00:00+00', NULL, '2001-02-04 11:00:00+00', 'remediated'),
  ('00000000-0000-0000-0000-00000000f625', '00000000-0000-0000-0000-00000000f613', 'AIGOV-IAM-001', 'violation', 'critical', 'g5', 'x', 'open',
   '2001-02-03 09:00:00+00', NULL, NULL, NULL),
  ('00000000-0000-0000-0000-00000000f626', '00000000-0000-0000-0000-00000000f612', 'AIGOV-OWN-001', 'violation', 'low', 'g6', 'x', 'open',
   '2001-02-03 09:00:00+00', NULL, NULL, NULL);
SELECT aigov.audit('finding.opened', 'service', 'test', 'aap', '00000000-0000-0000-0000-00000000f603', '00000000-0000-0000-0000-00000000f611',
                   '00000000-0000-0000-0000-00000000f621');
SELECT aigov.audit('finding.opened', 'service', 'test', 'aap', '00000000-0000-0000-0000-00000000f603', '00000000-0000-0000-0000-00000000f611',
                   '00000000-0000-0000-0000-00000000f622');

-- Remediations: verified automatically (30 min), verified after approval (120 min), awaiting approval, planned, failed
INSERT INTO aigov.remediation_actions (id, governance_run_id, finding_id, action_type, mode, status, authz_decision, planned_change,
                                       attempt_number, created_at, updated_at) VALUES
  ('00000000-0000-0000-0000-00000000f631', '00000000-0000-0000-0000-00000000f602', '00000000-0000-0000-0000-00000000f623', 'agentcore_apply_governance_tags',
   'enforce', 'verified', '{}', '{"route": {"route": "auto"}}', 1, '2001-02-04 08:05:00+00', '2001-02-04 08:30:00+00'),
  ('00000000-0000-0000-0000-00000000f632', '00000000-0000-0000-0000-00000000f602', '00000000-0000-0000-0000-00000000f624', 'agentcore_apply_governance_tags',
   'enforce', 'failed', '{}', '{"route": {"route": "auto"}}', 1, '2001-02-04 09:05:00+00', '2001-02-04 09:10:00+00'),
  ('00000000-0000-0000-0000-00000000f633', '00000000-0000-0000-0000-00000000f602', '00000000-0000-0000-0000-00000000f624', 'agentcore_apply_governance_tags',
   'enforce', 'verified', '{}', '{"route": {"route": "approval"}}', 2, '2001-02-04 10:00:00+00', '2001-02-04 11:00:00+00'),
  ('00000000-0000-0000-0000-00000000f634', '00000000-0000-0000-0000-00000000f602', '00000000-0000-0000-0000-00000000f622', 'iam_replace_managed_policy',
   'enforce', 'awaiting_approval', '{}', '{"route": {"route": "approval"}}', 1, now() - interval '20 minutes', now() - interval '20 minutes'),
  ('00000000-0000-0000-0000-00000000f635', '00000000-0000-0000-0000-00000000f602', '00000000-0000-0000-0000-00000000f621', 'iam_replace_managed_policy',
   'enforce', 'planned', '{}', '{"route": {"route": "auto"}}', 1, now(), now());
INSERT INTO aigov.approvals (remediation_action_id, approvers_required, decision, decided_by, decided_at) VALUES
  ('00000000-0000-0000-0000-00000000f633', ARRAY['AI Governance Approvers'], 'approved', 'approver@example.com', '2001-02-04 10:20:00+00');

-- Drift explained by the sweep
SELECT aigov.audit('agent.drift_unattributed', 'service', 'test', 'db', NULL, '00000000-0000-0000-0000-00000000f612',
                   details => '{"changed_paths": ["tags.env", "status"], "change_event_ids": []}');
SELECT aigov.audit('agent.drift_attributed', 'service', 'test', 'db', NULL, '00000000-0000-0000-0000-00000000f611',
                   details => '{"changed_paths": ["identity.policies"], "change_event_ids": ["00000000-0000-0000-0000-00000000f641"]}');

-- A past day's snapshot is history: it stays even after agents and findings change
INSERT INTO aigov.compliance_snapshots (day, agents, compliant, noncompliant, unknown, not_evaluated, unregistered, open_findings,
  open_critical, open_high, open_medium, open_low, open_remediations, pending_approvals)
VALUES ('2001-02-03', 8, 6, 2, 0, 0, 1, 3, 1, 1, 1, 0, 1, 0);

DO $$
DECLARE r record; s jsonb; b jsonb; f jsonb;
BEGIN
  -- Time to detect: (2 + 4) / 2 = 3 minutes, attributed to the change event; the finding without a change time is excluded
  SELECT * INTO r FROM reporting.mttd_daily WHERE day = '2001-02-03';
  IF r.findings <> 2 OR r.mttd_minutes <> 3.00 OR r.max_detect_minutes <> 4.00 THEN RAISE EXCEPTION 'mttd_daily wrong: %', r; END IF;
  IF (SELECT count(*) FROM reporting.findings_event_attributed
      WHERE change_event_id = '00000000-0000-0000-0000-00000000f641' AND event_name = 'AttachRolePolicy') <> 2 THEN
    RAISE EXCEPTION 'event attribution wrong';
  END IF;

  -- Time to remediate: (30 + 120) / 2 = 75 minutes; automatic 30, after approval 120 (the failed first attempt is ignored)
  SELECT * INTO r FROM reporting.mttr_daily WHERE day = '2001-02-04';
  IF r.remediated <> 2 OR r.mttr_minutes <> 75.00 OR r.automatic <> 1 OR r.after_approval <> 1
     OR r.mttr_automatic_minutes <> 30.00 OR r.mttr_approval_minutes <> 120.00 THEN
    RAISE EXCEPTION 'mttr_daily wrong: %', r;
  END IF;
  IF (SELECT remediation_id FROM reporting.findings_remediated WHERE finding_id = '00000000-0000-0000-0000-00000000f624')
     <> '00000000-0000-0000-0000-00000000f633' THEN
    RAISE EXCEPTION 'findings_remediated should use the verified attempt';
  END IF;

  -- Operations
  IF (SELECT string_agg(status_group, ',' ORDER BY remediation_id) FROM reporting.remediations WHERE agent_name IN ('metrics-one', 'metrics-two'))
     <> 'verified,failed,verified,open,open' THEN
    RAISE EXCEPTION 'remediation status groups wrong';
  END IF;
  IF (SELECT decided_by FROM reporting.remediations WHERE remediation_id = '00000000-0000-0000-0000-00000000f633') <> 'approver@example.com'
     OR (SELECT route FROM reporting.remediations WHERE remediation_id = '00000000-0000-0000-0000-00000000f633') <> 'approval' THEN
    RAISE EXCEPTION 'remediation decision/route wrong';
  END IF;
  SELECT * INTO r FROM reporting.pending_approvals WHERE remediation_id = '00000000-0000-0000-0000-00000000f634';
  IF r.remediation_id IS NULL OR r.waiting_minutes NOT BETWEEN 19.5 AND 21 OR r.severity <> 'high' THEN
    RAISE EXCEPTION 'pending_approvals wrong: %', r;
  END IF;
  SELECT * INTO r FROM reporting.change_events_daily WHERE day = '2001-02-03';
  IF r.received <> 3 OR r.mapped <> 1 OR r.ignored <> 1 OR r.suppressed <> 1 OR r.reassessments_started <> 1
     OR r.avg_delivery_seconds <> 20.0 THEN
    RAISE EXCEPTION 'change_events_daily wrong: %', r;
  END IF;
  IF (SELECT string_agg(agent_name || ':' || attributed || ':' || changed_paths || ':' || change_events, ' | ' ORDER BY event_id)
      FROM reporting.drift_events WHERE agent_name LIKE 'metrics-%')
     <> 'metrics-two:false:tags.env, status:0 | metrics-one:true:identity.policies:1' THEN
    RAISE EXCEPTION 'drift_events wrong';
  END IF;

  -- Funnel: 5 planned; 3 approved or automatic (verified x2, failed); 2 executed (the change was applied: verified x2;
  -- a failed execution applied nothing); 2 verified
  SELECT funnel INTO b FROM t_before;
  SELECT jsonb_object_agg(stage, remediations) INTO f FROM reporting.remediation_funnel;
  IF (f ->> 'planned')::int - (b ->> 'planned')::int <> 5
     OR (f ->> 'approved or automatic')::int - (b ->> 'approved or automatic')::int <> 3
     OR (f ->> 'executed')::int - (b ->> 'executed')::int <> 2
     OR (f ->> 'verified')::int - (b ->> 'verified')::int <> 2 THEN
    RAISE EXCEPTION 'remediation_funnel wrong: before % after %', b, f;
  END IF;

  -- Daily snapshot: as the remediator (the sweep's role); the missing agent and its finding are not counted
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  s := api.capture_compliance_snapshot()::jsonb;
  RESET ROLE;
  SELECT snap INTO b FROM t_before;
  IF (s ->> 'day')::date <> (now() AT TIME ZONE 'UTC')::date
     OR (s ->> 'agents')::int - (b ->> 'agents')::int <> 2
     OR (s ->> 'compliant')::int - (b ->> 'compliant')::int <> 1
     OR (s ->> 'noncompliant')::int - (b ->> 'noncompliant')::int <> 1
     OR (s ->> 'unregistered')::int - (b ->> 'unregistered')::int <> 1
     OR (s ->> 'open_findings')::int - (b ->> 'open_findings')::int <> 3
     OR (s ->> 'open_critical')::int - (b ->> 'open_critical')::int <> 1
     OR (s ->> 'open_high')::int - (b ->> 'open_high')::int <> 1
     OR (s ->> 'open_low')::int - (b ->> 'open_low')::int <> 1
     OR (s ->> 'open_remediations')::int - (b ->> 'open_remediations')::int <> 1
     OR (s ->> 'pending_approvals')::int - (b ->> 'pending_approvals')::int <> 1 THEN
    RAISE EXCEPTION 'snapshot wrong: before % after %', b, s;
  END IF;
  -- One row per day: the second capture today updated the first
  IF (SELECT count(*) FROM aigov.compliance_snapshots WHERE day = (now() AT TIME ZONE 'UTC')::date) <> 1 THEN
    RAISE EXCEPTION 'snapshot not upserted';
  END IF;
  SELECT * INTO r FROM reporting.compliance_trend WHERE day = '2001-02-03';
  IF r.agents <> 8 OR r.compliant_pct <> 75.0 OR r.open_findings <> 3 THEN RAISE EXCEPTION 'compliance_trend history wrong: %', r; END IF;
END $$;

-- Grafana reads the new views
SET LOCAL ROLE grafana_ro;
SELECT count(*) FROM reporting.compliance_trend, reporting.mttd_daily, reporting.mttr_daily LIMIT 1;
SELECT count(*) FROM reporting.remediations, reporting.pending_approvals, reporting.remediation_funnel, reporting.change_events_daily,
       reporting.drift_events, reporting.findings_event_attributed, reporting.findings_remediated LIMIT 1;
RESET ROLE;
ROLLBACK;
\echo 'test_v016_reporting_stage3: all assertions passed'
