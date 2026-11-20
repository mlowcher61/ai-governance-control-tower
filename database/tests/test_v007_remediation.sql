-- SQL assertions for V007: the remediation lifecycle and its safety rules.
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.as_remediator() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  PERFORM set_config('request.jwt.claims', '{"role": "aigov_remediator", "sub": "test-remediator"}', true);
END $$;
CREATE FUNCTION pg_temp.as_admin() RETURNS void LANGUAGE plpgsql AS $$ BEGIN RESET ROLE; END $$;

-- Grants: only the remediator runs the lifecycle
DO $$
DECLARE sig text; r text;
BEGIN
  FOREACH sig IN ARRAY ARRAY['api.get_finding_context(uuid)', 'api.begin_remediation(uuid,uuid,text,text,jsonb,jsonb,boolean,jsonb,jsonb)',
      'api.update_remediation(uuid,text,jsonb,jsonb,bigint)', 'api.record_approval(uuid,text,text,text,text,timestamp with time zone,text,text[],text)',
      'api.close_finding(uuid,uuid,text)', 'api.record_outcome(uuid,uuid,text,jsonb,uuid,integer)'] LOOP
    IF NOT has_function_privilege('aigov_remediator', sig, 'EXECUTE') THEN RAISE EXCEPTION 'remediator cannot run %', sig; END IF;
    FOREACH r IN ARRAY ARRAY['aigov_discovery', 'aigov_evaluator', 'aigov_reader', 'aigov_registry', 'aigov_api_anon'] LOOP
      IF has_function_privilege(r, sig, 'EXECUTE') THEN RAISE EXCEPTION '% can run %', r, sig; END IF;
    END LOOP;
  END LOOP;
  IF NOT has_table_privilege('aigov_reader', 'api.remediations', 'SELECT') OR has_table_privilege('aigov_discovery', 'api.remediations', 'SELECT') THEN
    RAISE EXCEPTION 'api.remediations grants are wrong';
  END IF;
END $$;

-- Data: one agent with an admin violation (needs approval), a tag violation (auto) and an unknown-model finding
INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000a001', 'aws', '555566667777');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash, environment)
VALUES ('00000000-0000-0000-0000-00000000a002', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000a001',
        'us-west-1', 'rt', 'arn:rt', 'bot', 'h', 'production');
INSERT INTO aigov.findings (id, agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation) VALUES
  ('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000a002', 'AIGOV-IAM-001', 'violation', 'critical', 'f1', 'admin'),
  ('00000000-0000-0000-0000-00000000f002', '00000000-0000-0000-0000-00000000a002', 'AIGOV-TAG-001', 'violation', 'medium', 'f2', 'tags'),
  ('00000000-0000-0000-0000-00000000f003', '00000000-0000-0000-0000-00000000a002', 'AIGOV-MDL-001', 'insufficient_evidence', 'medium', 'f3', 'unknown'),
  ('00000000-0000-0000-0000-00000000f004', '00000000-0000-0000-0000-00000000a002', 'AIGOV-OWN-001', 'violation', 'high', 'f4', 'owner');
CREATE TEMP TABLE authz (name text PRIMARY KEY, d jsonb);
GRANT ALL ON authz TO PUBLIC;
INSERT INTO authz VALUES
  ('approval', '{"route_precheck": "eligible", "selected_action": "iam_replace_managed_policy", "approval_required": "yes", "auto_remediation_permitted": "no"}'),
  ('auto', '{"route_precheck": "eligible", "selected_action": "agentcore_apply_governance_tags", "approval_required": "no", "auto_remediation_permitted": "yes"}'),
  ('denied', '{"route_precheck": "denied", "selected_action": "iam_replace_managed_policy"}');

-- ---- begin_remediation refuses what OPA did not authorize ------------------------------------------------------
DO $$
DECLARE ok boolean;
BEGIN
  PERFORM pg_temp.as_remediator();
  FOR ok IN SELECT true LOOP
    BEGIN PERFORM api.begin_remediation(NULL, '00000000-0000-0000-0000-00000000f001', 'iam_replace_managed_policy', 'enforce', (SELECT d FROM authz WHERE name = 'denied'));
      RAISE EXCEPTION 'denied authz accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    BEGIN PERFORM api.begin_remediation(NULL, '00000000-0000-0000-0000-00000000f001', 'iam_remove_inline_policy', 'enforce', (SELECT d FROM authz WHERE name = 'approval'));
      RAISE EXCEPTION 'action other than OPA''s choice accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    BEGIN PERFORM api.begin_remediation(NULL, '00000000-0000-0000-0000-00000000f003', 'iam_replace_managed_policy', 'enforce', (SELECT d FROM authz WHERE name = 'approval'));
      RAISE EXCEPTION 'insufficient evidence finding accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    BEGIN PERFORM api.begin_remediation(NULL, '00000000-0000-0000-0000-00000000f001', 'iam_replace_managed_policy', 'yolo', (SELECT d FROM authz WHERE name = 'approval'));
      RAISE EXCEPTION 'bad mode accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  END LOOP;
  PERFORM pg_temp.as_admin();
END $$;

-- ---- The approval path, end to end ------------------------------------------------------------------------------
CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
GRANT ALL ON ids TO PUBLIC;
DO $$
DECLARE res json; rid uuid; ctx json;
BEGIN
  PERFORM pg_temp.as_remediator();
  res := api.begin_remediation('00000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-00000000f001', 'iam_replace_managed_policy',
                               'enforce', (SELECT d FROM authz WHERE name = 'approval'), '{"agrees": true}', true,
                               '{"attach": ["approved"], "detach": ["AdministratorAccess"]}', '{"managed_policies": ["AdministratorAccess"]}');
  rid := (res ->> 'remediation_id')::uuid;
  INSERT INTO ids VALUES ('approval', rid);
  IF (res ->> 'attempt_number')::int <> 1 THEN RAISE EXCEPTION 'attempt number: %', res; END IF;
  ctx := api.get_finding_context('00000000-0000-0000-0000-00000000f001');
  IF ctx ->> 'finding_status' <> 'remediation_planned' OR (ctx ->> 'active_remediation_id')::uuid <> rid OR ctx ->> 'environment' <> 'production' THEN
    RAISE EXCEPTION 'context after begin: %', ctx;
  END IF;
  -- one active remediation per finding: a conflict (PostgREST returns 409)
  BEGIN
    PERFORM api.begin_remediation(NULL, '00000000-0000-0000-0000-00000000f001', 'iam_replace_managed_policy', 'enforce', (SELECT d FROM authz WHERE name = 'approval'));
    RAISE EXCEPTION 'second active remediation accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  -- OPA required approval: no direct approval, no invalid jumps
  BEGIN PERFORM api.update_remediation(rid, 'approved'); RAISE EXCEPTION 'approval bypassed'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM api.update_remediation(rid, 'executing'); RAISE EXCEPTION 'planned -> executing accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  PERFORM api.update_remediation(rid, 'awaiting_approval');
  BEGIN PERFORM api.update_remediation(rid, 'approved'); RAISE EXCEPTION 'approved without record_approval'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM api.update_remediation(rid, 'rejected'); RAISE EXCEPTION 'rejected without record_approval'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM api.record_approval(rid, 'approved'); RAISE EXCEPTION 'approval without an approver'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  res := api.record_approval(rid, 'approved', 'jdoe-security', 'Looks right; scoped policy reviewed', 'ao-approval-1', NULL, 'remediation', ARRAY['jdoe-security']);
  IF res ->> 'remediation_status' <> 'approved' THEN RAISE EXCEPTION 'record_approval: %', res; END IF;
  PERFORM api.update_remediation(rid, 'executing', NULL, NULL, 501);
  PERFORM api.update_remediation(rid, 'succeeded', '{"managed_policies": ["approved"]}', NULL, 501);
  PERFORM api.update_remediation(rid, 'verified', NULL, NULL, 502);
  PERFORM pg_temp.as_admin();
  IF (SELECT status FROM aigov.findings WHERE id = '00000000-0000-0000-0000-00000000f001') <> 'verifying' THEN RAISE EXCEPTION 'finding not verifying'; END IF;
  IF (SELECT aap_job_ids FROM aigov.remediation_actions WHERE id = rid) <> ARRAY[501, 502]::bigint[] THEN RAISE EXCEPTION 'job ids not collected once each'; END IF;
  IF (SELECT actor_type || ':' || actor_id FROM aigov.audit_events WHERE event_type = 'approval.decided') <> 'human:jdoe-security' THEN
    RAISE EXCEPTION 'approval not audited as the human approver';
  END IF;
END $$;

-- ---- close_finding: verification before resolution ----------------------------------------------------------------
INSERT INTO aigov.governance_runs (id, run_type, trigger_type) VALUES ('00000000-0000-0000-0000-00000000c002', 'remediation', 'manual');
INSERT INTO aigov.policy_evaluations (id, governance_run_id, agent_id, bundle_revision, input_hash, overall_status, risk_score, risk_category, risk_factors, purpose) VALUES
  ('00000000-0000-0000-0000-00000000e001', '00000000-0000-0000-0000-00000000c002', '00000000-0000-0000-0000-00000000a002', 'r', 'h', 'noncompliant', 50, 'high', '[]', 'assessment'),
  ('00000000-0000-0000-0000-00000000e002', '00000000-0000-0000-0000-00000000c002', '00000000-0000-0000-0000-00000000a002', 'r', 'h', 'noncompliant', 50, 'high', '[]', 'verification'),
  ('00000000-0000-0000-0000-00000000e003', '00000000-0000-0000-0000-00000000c002', '00000000-0000-0000-0000-00000000a002', 'r', 'h', 'noncompliant', 30, 'medium', '[]', 'verification');
INSERT INTO aigov.policy_results (evaluation_id, policy_id, policy_version, decision, severity, explanation) VALUES
  ('00000000-0000-0000-0000-00000000e001', 'AIGOV-IAM-001', '1.0.0', 'pass', 'critical', 'x'),
  ('00000000-0000-0000-0000-00000000e002', 'AIGOV-IAM-001', '1.0.0', 'fail', 'critical', 'still admin'),
  ('00000000-0000-0000-0000-00000000e003', 'AIGOV-IAM-001', '1.0.0', 'pass', 'critical', 'fixed');
DO $$
BEGIN
  PERFORM pg_temp.as_remediator();
  BEGIN PERFORM api.close_finding('00000000-0000-0000-0000-00000000f002', '00000000-0000-0000-0000-00000000e003');
    RAISE EXCEPTION 'closed without a verified remediation'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM api.close_finding('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000e001');
    RAISE EXCEPTION 'closed with an assessment (not verification) evaluation'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM api.close_finding('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000e002');
    RAISE EXCEPTION 'closed although verification still fails'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM api.close_finding('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000e003', 'risk_accepted');
    RAISE EXCEPTION 'non-remediated resolution accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  PERFORM api.close_finding('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000e003');
  BEGIN PERFORM api.close_finding('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000e003');
    RAISE EXCEPTION 'closed twice'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  PERFORM pg_temp.as_admin();
  IF (SELECT status || '/' || resolution FROM aigov.findings WHERE id = '00000000-0000-0000-0000-00000000f001') <> 'resolved/remediated' THEN
    RAISE EXCEPTION 'finding not resolved as remediated';
  END IF;
END $$;

-- ---- Auto path, dry run, rollback, outcome and cooldown ----------------------------------------------------------
DO $$
DECLARE res json; rid uuid; ctx json;
BEGIN
  PERFORM pg_temp.as_remediator();
  -- OPA permitted automatic remediation: planned -> approved directly; a dry run is skipped, never executed
  res := api.begin_remediation(NULL, '00000000-0000-0000-0000-00000000f002', 'agentcore_apply_governance_tags', 'dry_run', (SELECT d FROM authz WHERE name = 'auto'));
  rid := (res ->> 'remediation_id')::uuid;
  PERFORM api.update_remediation(rid, 'approved');
  BEGIN PERFORM api.update_remediation(rid, 'executing'); RAISE EXCEPTION 'dry run executed'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  PERFORM api.update_remediation(rid, 'skipped');
  ctx := api.get_finding_context('00000000-0000-0000-0000-00000000f002');
  IF ctx ->> 'finding_status' <> 'open' OR (ctx ->> 'remediation_attempts')::int <> 1 OR ctx ->> 'active_remediation_id' IS NOT NULL THEN
    RAISE EXCEPTION 'after dry run: %', ctx;
  END IF;

  -- a failed enforcement: rollback needs its own approval
  res := api.begin_remediation(NULL, '00000000-0000-0000-0000-00000000f002', 'agentcore_apply_governance_tags', 'enforce', (SELECT d FROM authz WHERE name = 'auto'));
  rid := (res ->> 'remediation_id')::uuid;
  IF (res ->> 'attempt_number')::int <> 2 THEN RAISE EXCEPTION 'second attempt number: %', res; END IF;
  PERFORM api.update_remediation(rid, 'approved');
  PERFORM api.update_remediation(rid, 'executing');
  PERFORM api.update_remediation(rid, 'failed', NULL, '{"message": "AccessDenied"}');
  BEGIN PERFORM api.update_remediation(rid, 'rolled_back'); RAISE EXCEPTION 'rollback without approval'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN PERFORM api.record_approval(rid, 'approved', 'jdoe-security', NULL, NULL, NULL, 'remediation');
    RAISE EXCEPTION 'remediation approval recorded after failure'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  PERFORM api.record_approval(rid, 'approved', 'jdoe-security', 'Restore previous tags', NULL, NULL, 'rollback');
  PERFORM api.update_remediation(rid, 'rolled_back');
  BEGIN PERFORM api.update_remediation(rid, 'executing'); RAISE EXCEPTION 'terminal state left'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  res := api.record_outcome(NULL, '00000000-0000-0000-0000-00000000f002', 'rolled_back', '["AccessDenied"]', rid, 30);
  ctx := api.get_finding_context('00000000-0000-0000-0000-00000000f002');
  IF ctx ->> 'cooldown_active' <> 'yes' OR ctx ->> 'finding_status' <> 'open' THEN RAISE EXCEPTION 'cooldown not active: %', ctx; END IF;
  BEGIN PERFORM api.record_outcome(NULL, '00000000-0000-0000-0000-00000000f002', 'great'); RAISE EXCEPTION 'unknown outcome accepted';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;

  -- rejection through record_approval returns the finding to open
  res := api.begin_remediation(NULL, '00000000-0000-0000-0000-00000000f004', 'iam_replace_managed_policy', 'enforce', (SELECT d FROM authz WHERE name = 'approval'));
  rid := (res ->> 'remediation_id')::uuid;
  PERFORM api.update_remediation(rid, 'awaiting_approval');
  res := api.record_approval(rid, 'rejected', 'jdoe-security', 'Owner must confirm first');
  IF res ->> 'remediation_status' <> 'rejected' THEN RAISE EXCEPTION 'rejection: %', res; END IF;
  PERFORM pg_temp.as_admin();
  IF (SELECT status FROM aigov.findings WHERE id = '00000000-0000-0000-0000-00000000f004') <> 'open' THEN RAISE EXCEPTION 'rejected finding not open'; END IF;
END $$;

-- Every lifecycle step is in the audit log, and the chain is intact
DO $$
DECLARE missing text[]; n int;
BEGIN
  SELECT array_agg(e) INTO missing FROM unnest(ARRAY['remediation.planned', 'approval.requested', 'approval.decided', 'remediation.executing',
      'remediation.executed', 'verification.passed', 'finding.resolved', 'remediation.failed', 'rollback.executed', 'remediation.outcome',
      'remediation.skipped']) e
  WHERE NOT EXISTS (SELECT FROM aigov.audit_events a WHERE a.event_type = e);
  IF missing IS NOT NULL THEN RAISE EXCEPTION 'audit events missing: %', missing; END IF;
  SELECT count(*) INTO n FROM aigov.verify_audit_chain();
  IF n <> 0 THEN RAISE EXCEPTION 'audit chain broken'; END IF;
END $$;

ROLLBACK;
\echo 'test_v007_remediation: all assertions passed'
