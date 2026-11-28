-- SQL assertions for V017: the views behind the Stage 3 dashboards - audit chain status and checks, the audit timeline
-- per run, policy bundle revisions, compliance history (snapshots first, assessments before them), agent tools and data
-- sources, and the dead-letter depth recorded by Reconcile and Sweep.
\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  IF NOT has_function_privilege('aigov_remediator', 'api.record_dead_letters(integer)', 'EXECUTE')
     OR has_function_privilege('aigov_reader', 'api.record_dead_letters(integer)', 'EXECUTE')
     OR has_function_privilege('grafana_ro', 'api.record_dead_letters(integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'record_dead_letters grants are wrong';
  END IF;
END $$;

INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000f701', 'aws', '717171717171');
INSERT INTO aigov.governance_runs (id, run_type, trigger_type) VALUES ('00000000-0000-0000-0000-00000000f702', 'assessment', 'manual');
INSERT INTO aigov.agent_registrations (registration_id, match_keys, approved_tools) VALUES ('REG-F7', '{}', ARRAY['code-interpreter']);
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash, registration_id, registration_status) VALUES
  ('00000000-0000-0000-0000-00000000f711', 'aws', 'aws.bedrock_agent', '00000000-0000-0000-0000-00000000f701', 'r', 'd1', 'arn:d1', 'dash-one', 'h', 'REG-F7', 'registered');
INSERT INTO aigov.agent_tools (agent_id, tool_type, external_id, name, state, parent_signature) VALUES
  ('00000000-0000-0000-0000-00000000f711', 'action_group', 'ag-1', 'interpreter', 'ENABLED', 'code-interpreter'),
  ('00000000-0000-0000-0000-00000000f711', 'action_group', 'ag-2', 'computer', 'ENABLED', 'computer-use'),
  ('00000000-0000-0000-0000-00000000f711', 'action_group', 'ag-3', NULL, 'ENABLED', NULL);
INSERT INTO aigov.agent_data_sources (agent_id, source_type, external_id, name, classification) VALUES
  ('00000000-0000-0000-0000-00000000f711', 'knowledge_base', 'kb-1', 'policies-kb', 'confidential');

-- Evaluations under two bundle revisions; the latest uses the commit
INSERT INTO aigov.policy_evaluations (agent_id, governance_run_id, bundle_revision, input_hash, overall_status, risk_score, risk_category, risk_factors, evaluated_at) VALUES
  ('00000000-0000-0000-0000-00000000f711', '00000000-0000-0000-0000-00000000f702', 'local', 'i1', 'noncompliant', 50, 'high', '[]', '2001-03-01 12:00+00'),
  ('00000000-0000-0000-0000-00000000f711', '00000000-0000-0000-0000-00000000f702', 'local', 'i2', 'noncompliant', 50, 'high', '[]', '2001-03-02 12:00+00'),
  ('00000000-0000-0000-0000-00000000f711', '00000000-0000-0000-0000-00000000f702', 'abc1234def', 'i3', 'compliant', 10, 'low', '[]', now());
-- A snapshot exists for 2001-03-02 only
INSERT INTO aigov.compliance_snapshots (day, agents, compliant, noncompliant, unknown, not_evaluated, unregistered, open_findings,
  open_critical, open_high, open_medium, open_low, open_remediations, pending_approvals)
VALUES ('2001-03-02', 4, 1, 3, 0, 0, 1, 6, 2, 1, 2, 1, 0, 0);

-- Audit events for the run, a chain check that covers all but the last one
SELECT aigov.audit('governance.run_started', 'service', 'test', 'ao', '00000000-0000-0000-0000-00000000f702', details => '{"run_type": "assessment"}');
SELECT aigov.audit('evaluation.recorded', 'policy', 'opa', 'opa', '00000000-0000-0000-0000-00000000f702', '00000000-0000-0000-0000-00000000f711',
                   details => '{"overall_status": "compliant"}');
INSERT INTO aigov.audit_checkpoints (verified_from_id, verified_to_id, status) SELECT 0, max(id), 'intact' FROM aigov.audit_events;
SELECT aigov.audit('approval.recorded', 'human', 'approver@example.com', 'ao', '00000000-0000-0000-0000-00000000f702', details => '{"decision": "approved"}');

DO $$
DECLARE r record;
BEGIN
  -- Dead letters: recorded by the remediator, shown in the chain status row
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  PERFORM api.record_dead_letters(2);
  BEGIN
    PERFORM api.record_dead_letters(-1);
    RAISE EXCEPTION 'negative dead letters accepted';
  EXCEPTION WHEN raise_exception THEN RAISE; WHEN OTHERS THEN NULL;
  END;
  RESET ROLE;
  SELECT * INTO r FROM reporting.audit_chain_status;
  IF r.chain_status <> 'intact' OR r.events_since_check <> 1 OR r.latest_event_id <= r.verified_to_id
     OR r.dead_letters <> 2 OR r.dead_letters_checked_at IS NULL THEN
    RAISE EXCEPTION 'audit_chain_status wrong: %', r;
  END IF;
  IF (SELECT count(*) FROM reporting.audit_chain_status) <> 1 THEN RAISE EXCEPTION 'audit_chain_status must be one row'; END IF;
  IF NOT EXISTS (SELECT FROM reporting.audit_chain_checks WHERE status = 'intact' AND verified_from_id = 0
                 AND events_checked = (SELECT count(*) FROM aigov.audit_events e WHERE e.id <= verified_to_id)) THEN
    RAISE EXCEPTION 'audit_chain_checks wrong';
  END IF;

  -- Audit timeline for the run, in chain order, with the subject taken from the details
  IF (SELECT string_agg(actor_type || ':' || event_type || ':' || subject, ' | ' ORDER BY event_id) FROM reporting.audit_timeline
      WHERE governance_run_id = '00000000-0000-0000-0000-00000000f702')
     <> 'service:governance.run_started:assessment | policy:evaluation.recorded:compliant | human:approval.recorded:approved' THEN
    RAISE EXCEPTION 'audit_timeline wrong';
  END IF;
  IF (SELECT agent_name FROM reporting.audit_timeline WHERE event_type = 'evaluation.recorded'
      AND governance_run_id = '00000000-0000-0000-0000-00000000f702') <> 'dash-one' THEN
    RAISE EXCEPTION 'audit_timeline agent missing';
  END IF;

  -- Bundle revisions: the commit is in use (latest evaluation), 'local' is history
  SELECT * INTO r FROM reporting.bundle_revisions WHERE bundle_revision = 'abc1234def';
  IF NOT r.in_use OR NOT r.is_commit OR r.evaluations <> 1 THEN RAISE EXCEPTION 'bundle revision (commit) wrong: %', r; END IF;
  SELECT * INTO r FROM reporting.bundle_revisions WHERE bundle_revision = 'local';
  IF r.in_use OR r.is_commit OR r.evaluations <> 2 OR r.agents <> 1 THEN RAISE EXCEPTION 'bundle revision (local) wrong: %', r; END IF;

  -- Compliance history: 2001-03-02 from the snapshot (not the assessment), 2001-03-01 from assessments
  SELECT * INTO r FROM reporting.compliance_history WHERE day = '2001-03-02';
  IF r.source <> 'snapshot' OR r.agents <> 4 OR r.compliant_pct <> 25.0 OR r.open_critical_high <> 3 THEN
    RAISE EXCEPTION 'compliance_history snapshot day wrong: %', r;
  END IF;
  IF (SELECT count(*) FROM reporting.compliance_history WHERE day = '2001-03-02') <> 1 THEN RAISE EXCEPTION 'day listed twice'; END IF;
  SELECT * INTO r FROM reporting.compliance_history WHERE day = '2001-03-01';
  IF r.source <> 'assessments' OR r.agents <> 1 OR r.noncompliant <> 1 OR r.compliant_pct <> 0.0 THEN
    RAISE EXCEPTION 'compliance_history assessment day wrong: %', r;
  END IF;

  -- Tools and data sources: the high-risk tool in approved_tools is approved, the other is not; no signature = n/a
  IF (SELECT string_agg(kind || ':' || name || ':' || coalesce(approved::text, '-') || ':' || coalesce(classification, '-'), ' | ' ORDER BY kind DESC, name)
      FROM reporting.agent_resources WHERE agent_id = '00000000-0000-0000-0000-00000000f711')
     <> 'tool:ag-3:-:- | tool:computer:false:- | tool:interpreter:true:- | data source:policies-kb:-:confidential' THEN
    RAISE EXCEPTION 'agent_resources wrong: %', (SELECT string_agg(kind || ':' || name || ':' || coalesce(approved::text, '-'), ' | ')
                                                 FROM reporting.agent_resources WHERE agent_id = '00000000-0000-0000-0000-00000000f711');
  END IF;
END $$;

-- Time to detect counts only findings an event-triggered re-assessment opened. A finding opened by a full assessment
-- also carries source_change_at (V002 sets the agent's last update time) and must not count.
INSERT INTO aigov.change_events (id, event_id, received_at, event_time, event_source, event_name, status, agent_ids, raw) VALUES
  ('00000000-0000-0000-0000-00000000f741', 'ce-f7', '2001-04-01 10:00:20+00', '2001-04-01 10:00:00+00', 'iam.amazonaws.com',
   'AttachRolePolicy', 'mapped', ARRAY['00000000-0000-0000-0000-00000000f711']::uuid[], '{}');
INSERT INTO aigov.governance_runs (id, run_type, trigger_type, trigger_ref) VALUES
  ('00000000-0000-0000-0000-00000000f703', 'targeted_reassessment', 'event', '00000000-0000-0000-0000-00000000f741');
INSERT INTO aigov.findings (id, agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation,
                            first_detected_at, source_change_at) VALUES
  ('00000000-0000-0000-0000-00000000f751', '00000000-0000-0000-0000-00000000f711', 'AIGOV-IAM-001', 'violation', 'critical', 'e1', 'x',
   '2001-04-01 10:01:30+00', '2001-04-01 10:00:00+00'),
  ('00000000-0000-0000-0000-00000000f752', '00000000-0000-0000-0000-00000000f711', 'AIGOV-TAG-001', 'violation', 'medium', 'e2', 'x',
   '2001-04-01 11:00:00+00', '2001-03-20 08:00:00+00');
SELECT aigov.audit('finding.opened', 'policy', 'opa', 'opa', '00000000-0000-0000-0000-00000000f703', '00000000-0000-0000-0000-00000000f711',
                   '00000000-0000-0000-0000-00000000f751');
SELECT aigov.audit('finding.opened', 'policy', 'opa', 'opa', '00000000-0000-0000-0000-00000000f702', '00000000-0000-0000-0000-00000000f711',
                   '00000000-0000-0000-0000-00000000f752');
DO $$
DECLARE r record;
BEGIN
  IF EXISTS (SELECT FROM reporting.findings_event_attributed WHERE finding_id = '00000000-0000-0000-0000-00000000f752') THEN
    RAISE EXCEPTION 'a finding from a full assessment counted as event-attributed';
  END IF;
  SELECT * INTO r FROM reporting.findings_event_attributed WHERE finding_id = '00000000-0000-0000-0000-00000000f751';
  IF r.detect_minutes <> 1.50 OR r.change_event_id <> '00000000-0000-0000-0000-00000000f741' THEN
    RAISE EXCEPTION 'event-attributed finding wrong: %', r;
  END IF;
  SELECT * INTO r FROM reporting.mttd_daily WHERE day = '2001-04-01';
  IF r.findings <> 1 OR r.mttd_minutes <> 1.50 THEN RAISE EXCEPTION 'mttd_daily wrong: %', r; END IF;
END $$;

SET LOCAL ROLE grafana_ro;
SELECT count(*) FROM reporting.audit_chain_status, reporting.audit_chain_checks LIMIT 1;
SELECT count(*) FROM reporting.audit_timeline, reporting.bundle_revisions, reporting.compliance_history, reporting.agent_resources LIMIT 1;
RESET ROLE;
ROLLBACK;
\echo 'test_v017_dashboards_stage3: all assertions passed'
