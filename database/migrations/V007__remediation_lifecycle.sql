-- V007 (T2.02): the remediation lifecycle (docs/plan/04 sections 4.7, 9). Forward-only: add V008+ for changes.
--
-- The database enforces the safety rules itself, whatever a job sends:
--   * the executed action is always the one OPA selected, for an eligible finding;
--   * a remediation is approved directly only when OPA permitted automatic remediation; otherwise only a recorded
--     human approval approves it;
--   * dry runs never execute; rollback needs its own approval;
--   * a finding is resolved as remediated only after a verified remediation and a verification evaluation in which
--     the finding's policy passed;
--   * one active remediation per finding (unique index from V001, reported as a conflict).

ALTER TABLE aigov.approvals ADD COLUMN kind text NOT NULL DEFAULT 'remediation' CHECK (kind IN ('remediation', 'rollback'));

-- Allowed remediation status transitions
CREATE TABLE aigov.remediation_transitions (
  from_status text NOT NULL,
  to_status   text NOT NULL,
  PRIMARY KEY (from_status, to_status)
);
INSERT INTO aigov.remediation_transitions VALUES
  ('planned', 'awaiting_approval'), ('planned', 'approved'), ('planned', 'skipped'),
  ('awaiting_approval', 'approved'), ('awaiting_approval', 'rejected'), ('awaiting_approval', 'expired'),
  ('approved', 'executing'), ('approved', 'skipped'),
  ('executing', 'succeeded'), ('executing', 'failed'),
  ('succeeded', 'verified'), ('succeeded', 'verification_failed'),
  ('failed', 'rolled_back'), ('failed', 'rollback_failed'),
  ('verification_failed', 'rolled_back'), ('verification_failed', 'rollback_failed');
REVOKE ALL ON aigov.remediation_transitions FROM PUBLIC;

-- Finding status that goes with each remediation status
CREATE FUNCTION aigov.finding_status_for(remediation_status text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE remediation_status
    WHEN 'planned' THEN 'remediation_planned'
    WHEN 'awaiting_approval' THEN 'awaiting_approval'
    WHEN 'approved' THEN 'remediating'
    WHEN 'executing' THEN 'remediating'
    WHEN 'succeeded' THEN 'verifying'
    WHEN 'verified' THEN 'verifying'
    ELSE 'open'   -- rejected, expired, skipped, failed, verification_failed, rolled_back, rollback_failed
  END
$$;

-- Everything a remediation needs to know about a finding (docs/plan/04 section 4.2, plus target details)
CREATE FUNCTION api.get_finding_context(finding_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  res json;
BEGIN
  SELECT json_build_object(
    'finding_id', f.id, 'agent_id', a.id, 'agent_name', a.name, 'policy_id', f.policy_id, 'severity', f.severity,
    'finding_type', f.finding_type, 'finding_status', f.status,
    'environment', coalesce(a.environment, g.environment, 'unknown'),
    'account_ref', c.account_ref, 'platform', a.platform, 'region', a.region, 'external_id', a.external_id,
    'resource_ref', a.resource_ref, 'execution_role', i.principal_ref, 'registration_id', a.registration_id,
    'remediation_attempts', f.remediation_attempts,
    'cooldown_active', CASE WHEN f.cooldown_until > now() THEN 'yes' ELSE 'no' END,
    'cooldown_until', f.cooldown_until,
    'exempt', CASE WHEN a.tags ->> 'aigov:exempt' = 'true' THEN 'yes' ELSE 'no' END,
    'deterministic_explanation', f.deterministic_explanation,
    'latest_evaluation_id', f.latest_evaluation_id,
    'active_remediation_id', (SELECT r.id FROM aigov.remediation_actions r WHERE r.finding_id = f.id
                              AND r.status IN ('planned', 'awaiting_approval', 'approved', 'executing')))
  INTO res
  FROM aigov.findings f
  JOIN aigov.ai_agents a ON a.id = f.agent_id
  JOIN aigov.cloud_accounts c ON c.id = a.account_id
  LEFT JOIN aigov.agent_identities i ON i.id = a.identity_id
  LEFT JOIN aigov.agent_registrations g ON g.registration_id = a.registration_id
  WHERE f.id = get_finding_context.finding_id;
  IF res IS NULL THEN PERFORM aigov.api_error('unknown finding_id'); END IF;
  RETURN res;
END
$$;

CREATE FUNCTION api.begin_remediation(governance_run_id uuid, finding_id uuid, action_type text, mode text,
                                      authz_decision jsonb, ai_recommendation jsonb DEFAULT NULL,
                                      ai_recommendation_accepted boolean DEFAULT NULL, planned_change jsonb DEFAULT NULL,
                                      pre_state jsonb DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  f aigov.findings;
  gov_id uuid;
  rid uuid;
  attempt smallint;
BEGIN
  IF mode NOT IN ('dry_run', 'enforce') THEN PERFORM aigov.api_error('mode must be dry_run or enforce'); END IF;
  IF jsonb_typeof(authz_decision) IS DISTINCT FROM 'object' THEN PERFORM aigov.api_error('authz_decision is required'); END IF;
  IF authz_decision ->> 'route_precheck' IS DISTINCT FROM 'eligible' THEN
    PERFORM aigov.api_error(format('OPA did not authorize remediation (route_precheck %s)', coalesce(authz_decision ->> 'route_precheck', 'missing')));
  END IF;
  IF authz_decision ->> 'selected_action' IS DISTINCT FROM action_type THEN
    PERFORM aigov.api_error(format('action %s is not the action OPA selected (%s)', action_type, coalesce(authz_decision ->> 'selected_action', 'none')));
  END IF;
  SELECT * INTO f FROM aigov.findings x WHERE x.id = begin_remediation.finding_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown finding_id'); END IF;
  IF f.finding_type <> 'violation' THEN PERFORM aigov.api_error('insufficient evidence findings are never remediated'); END IF;
  IF f.status <> 'open' THEN
    IF EXISTS (SELECT FROM aigov.remediation_actions r WHERE r.finding_id = f.id
               AND r.status IN ('planned', 'awaiting_approval', 'approved', 'executing')) THEN
      RAISE EXCEPTION 'finding % already has an active remediation', f.id USING ERRCODE = 'unique_violation';
    END IF;
    PERFORM aigov.api_error(format('finding is %s, not open', f.status));
  END IF;

  gov_id := aigov.ensure_governance_run(governance_run_id, 'remediation', 'manual');
  attempt := f.remediation_attempts + 1;
  BEGIN
    INSERT INTO aigov.remediation_actions (governance_run_id, finding_id, action_type, mode, status, authz_decision,
                                           ai_recommendation, ai_recommendation_accepted, planned_change, pre_state, attempt_number)
    VALUES (gov_id, f.id, action_type, mode, 'planned', authz_decision, ai_recommendation, ai_recommendation_accepted,
            planned_change, pre_state, attempt)
    RETURNING id INTO rid;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'finding % already has an active remediation', f.id USING ERRCODE = 'unique_violation';
  END;
  UPDATE aigov.findings x SET status = 'remediation_planned', remediation_attempts = attempt WHERE x.id = f.id;
  PERFORM aigov.audit('remediation.planned', 'service', aigov.api_actor(), 'aap', gov_id, f.agent_id, f.id,
                      details => jsonb_build_object('action_type', action_type, 'mode', mode, 'attempt', attempt,
                                                    'planned_change', planned_change, 'authz', authz_decision,
                                                    'ai_recommendation_accepted', ai_recommendation_accepted),
                      remediation_action_id => rid);
  RETURN json_build_object('remediation_id', rid, 'attempt_number', attempt, 'governance_run_id', gov_id);
END
$$;

CREATE FUNCTION api.update_remediation(remediation_id uuid, status text, post_state jsonb DEFAULT NULL,
                                       error jsonb DEFAULT NULL, aap_job_id bigint DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  ra aigov.remediation_actions;
  f aigov.findings;
  event text;
BEGIN
  SELECT * INTO ra FROM aigov.remediation_actions x WHERE x.id = update_remediation.remediation_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown remediation_id'); END IF;
  IF NOT EXISTS (SELECT FROM aigov.remediation_transitions t WHERE t.from_status = ra.status AND t.to_status = update_remediation.status) THEN
    PERFORM aigov.api_error(format('invalid transition %s -> %s', ra.status, status));
  END IF;
  -- Direct approval only when OPA permitted automatic remediation; otherwise record_approval approves.
  IF status = 'approved' THEN
    PERFORM aigov.api_error('a remediation is approved only through record_approval') WHERE ra.status = 'awaiting_approval';
    IF ra.authz_decision ->> 'auto_remediation_permitted' IS DISTINCT FROM 'yes' THEN
      PERFORM aigov.api_error('OPA requires approval: move to awaiting_approval and record the approval');
    END IF;
  END IF;
  IF status IN ('rejected', 'expired') THEN
    PERFORM aigov.api_error('rejections and expiries are recorded through record_approval');
  END IF;
  IF status = 'executing' AND ra.mode <> 'enforce' THEN PERFORM aigov.api_error('a dry run never executes'); END IF;
  IF status IN ('rolled_back', 'rollback_failed') AND NOT EXISTS (
       SELECT FROM aigov.approvals ap WHERE ap.remediation_action_id = ra.id AND ap.kind = 'rollback' AND ap.decision = 'approved') THEN
    PERFORM aigov.api_error('rollback requires an approved rollback approval');
  END IF;

  UPDATE aigov.remediation_actions x
  SET status = update_remediation.status, updated_at = now(),
      post_state = coalesce(update_remediation.post_state, x.post_state),
      error = coalesce(update_remediation.error, x.error),
      aap_job_ids = CASE WHEN update_remediation.aap_job_id IS NULL OR update_remediation.aap_job_id = ANY (x.aap_job_ids)
                         THEN x.aap_job_ids ELSE x.aap_job_ids || update_remediation.aap_job_id END
  WHERE x.id = ra.id;
  UPDATE aigov.findings x SET status = aigov.finding_status_for(update_remediation.status)
  WHERE x.id = ra.finding_id AND x.status NOT IN ('resolved', 'false_positive');
  SELECT * INTO f FROM aigov.findings WHERE id = ra.finding_id;
  event := CASE status WHEN 'awaiting_approval' THEN 'approval.requested' WHEN 'executing' THEN 'remediation.executing'
                       WHEN 'succeeded' THEN 'remediation.executed' WHEN 'failed' THEN 'remediation.failed'
                       WHEN 'verified' THEN 'verification.passed' WHEN 'verification_failed' THEN 'verification.failed'
                       WHEN 'rolled_back' THEN 'rollback.executed' WHEN 'rollback_failed' THEN 'rollback.failed'
                       ELSE 'remediation.' || status END;
  PERFORM aigov.audit(event, 'service', aigov.api_actor(), 'aap', ra.governance_run_id, f.agent_id, f.id,
                      aap_job_id::text, jsonb_build_object('from', ra.status, 'to', status, 'action_type', ra.action_type,
                                                           'error', error), ra.id);
  RETURN json_build_object('ok', true, 'remediation_id', ra.id, 'status', status, 'finding_status', f.status);
END
$$;

CREATE FUNCTION api.record_approval(remediation_id uuid, decision text, decided_by text DEFAULT NULL,
                                    decision_notes text DEFAULT NULL, ao_approval_id text DEFAULT NULL,
                                    decided_at timestamptz DEFAULT NULL, kind text DEFAULT 'remediation',
                                    approvers_required text[] DEFAULT '{}', prompt text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  ra aigov.remediation_actions;
  f aigov.findings;
  aid uuid;
  new_status text;
BEGIN
  IF decision NOT IN ('approved', 'rejected', 'expired') THEN PERFORM aigov.api_error('decision must be approved, rejected or expired'); END IF;
  IF kind NOT IN ('remediation', 'rollback') THEN PERFORM aigov.api_error('kind must be remediation or rollback'); END IF;
  IF decision IN ('approved', 'rejected') AND coalesce(decided_by, '') = '' THEN
    PERFORM aigov.api_error('decided_by (the approver) is required for an approval or rejection');
  END IF;
  SELECT * INTO ra FROM aigov.remediation_actions x WHERE x.id = record_approval.remediation_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown remediation_id'); END IF;
  IF kind = 'remediation' AND ra.status <> 'awaiting_approval' THEN
    PERFORM aigov.api_error(format('remediation is %s, not awaiting_approval', ra.status));
  END IF;
  IF kind = 'rollback' AND ra.status NOT IN ('failed', 'verification_failed') THEN
    PERFORM aigov.api_error(format('rollback can be approved only after a failure (remediation is %s)', ra.status));
  END IF;

  INSERT INTO aigov.approvals (remediation_action_id, ao_approval_id, prompt, approvers_required, decision, decided_by,
                               decision_notes, decided_at, kind)
  VALUES (ra.id, ao_approval_id, prompt, coalesce(approvers_required, '{}'), decision, decided_by, left(decision_notes, 2000),
          coalesce(decided_at, now()), kind)
  RETURNING id INTO aid;

  IF kind = 'remediation' THEN
    new_status := decision;   -- approved, rejected or expired
    UPDATE aigov.remediation_actions x SET status = new_status, updated_at = now() WHERE x.id = ra.id;
    UPDATE aigov.findings x SET status = aigov.finding_status_for(new_status)
    WHERE x.id = ra.finding_id AND x.status NOT IN ('resolved', 'false_positive');
  END IF;
  SELECT * INTO f FROM aigov.findings WHERE id = ra.finding_id;
  PERFORM aigov.audit('approval.decided', CASE WHEN decision = 'expired' THEN 'service' ELSE 'human' END,
                      coalesce(nullif(decided_by, ''), aigov.api_actor()), 'ao', ra.governance_run_id, f.agent_id, f.id,
                      ao_approval_id, jsonb_build_object('kind', kind, 'decision', decision, 'notes', left(decision_notes, 2000),
                                                         'recorded_by', aigov.api_actor()), ra.id);
  RETURN json_build_object('approval_id', aid, 'remediation_status', coalesce(new_status, ra.status));
END
$$;

-- Resolve a remediated finding: needs a verified remediation and a verification evaluation in which the
-- finding's policy passed (docs/plan/08 section 5: verification before closure).
CREATE FUNCTION api.close_finding(finding_id uuid, evaluation_id uuid, resolution text DEFAULT 'remediated')
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  f aigov.findings;
  ev aigov.policy_evaluations;
  ra_id uuid;
  ra_updated timestamptz;
BEGIN
  IF resolution <> 'remediated' THEN PERFORM aigov.api_error('close_finding resolves remediated findings only'); END IF;
  SELECT * INTO f FROM aigov.findings x WHERE x.id = close_finding.finding_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown finding_id'); END IF;
  IF f.status IN ('resolved', 'false_positive') THEN PERFORM aigov.api_error(format('finding is already %s', f.status)); END IF;
  SELECT r.id, r.updated_at INTO ra_id, ra_updated FROM aigov.remediation_actions r
  WHERE r.finding_id = f.id AND r.status = 'verified' ORDER BY r.updated_at DESC LIMIT 1;
  IF ra_id IS NULL THEN PERFORM aigov.api_error('no verified remediation for this finding'); END IF;
  SELECT * INTO ev FROM aigov.policy_evaluations e WHERE e.id = close_finding.evaluation_id;
  IF NOT FOUND OR ev.agent_id <> f.agent_id OR ev.purpose <> 'verification' THEN
    PERFORM aigov.api_error('evaluation_id must be a verification evaluation of the same agent');
  END IF;
  IF NOT EXISTS (SELECT FROM aigov.policy_results pr WHERE pr.evaluation_id = ev.id AND pr.policy_id = f.policy_id AND pr.decision = 'pass') THEN
    PERFORM aigov.api_error(format('the verification evaluation does not show %s as pass', f.policy_id));
  END IF;

  UPDATE aigov.findings x SET status = 'resolved', resolution = 'remediated', resolved_at = now(), latest_evaluation_id = ev.id
  WHERE x.id = f.id;
  PERFORM aigov.audit('finding.resolved', 'service', aigov.api_actor(), 'aap', ev.governance_run_id, f.agent_id, f.id,
                      details => jsonb_build_object('resolution', 'remediated', 'verification_evaluation_id', ev.id),
                      remediation_action_id => ra_id);
  RETURN json_build_object('ok', true, 'finding_id', f.id, 'status', 'resolved');
END
$$;

-- Record how a remediation attempt ended; rejections and failures start the cooldown.
CREATE FUNCTION api.record_outcome(governance_run_id uuid, finding_id uuid, outcome text, reasons jsonb DEFAULT '[]',
                                   remediation_id uuid DEFAULT NULL, cooldown_minutes int DEFAULT 60)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  f aigov.findings;
  cool timestamptz;
BEGIN
  IF outcome NOT IN ('remediated', 'detect_only', 'denied', 'simulated', 'rejected', 'expired', 'failed',
                     'verification_failed', 'rolled_back', 'escalated') THEN
    PERFORM aigov.api_error(format('unknown outcome %s', outcome));
  END IF;
  SELECT * INTO f FROM aigov.findings x WHERE x.id = record_outcome.finding_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown finding_id'); END IF;
  IF outcome IN ('rejected', 'failed', 'verification_failed', 'rolled_back') THEN
    cool := now() + make_interval(mins => greatest(coalesce(cooldown_minutes, 60), 0));
    UPDATE aigov.findings x SET cooldown_until = cool WHERE x.id = f.id;
  END IF;
  PERFORM aigov.audit('remediation.outcome', 'service', aigov.api_actor(), 'aap', aigov.ensure_governance_run(governance_run_id, 'remediation', 'manual'),
                      f.agent_id, f.id, details => jsonb_build_object('outcome', outcome, 'reasons', coalesce(reasons, '[]'),
                                                                     'cooldown_until', cool),
                      remediation_action_id => remediation_id);
  RETURN json_build_object('ok', true, 'outcome', outcome, 'cooldown_until', cool);
END
$$;

CREATE VIEW api.remediations AS
SELECT r.id AS remediation_id, r.finding_id, f.policy_id, a.name AS agent_name, r.action_type, r.mode, r.status,
       r.attempt_number, r.authz_decision ->> 'route_precheck' AS route_precheck, r.ai_recommendation_accepted,
       r.aap_job_ids, r.created_at, r.updated_at,
       (SELECT json_agg(json_build_object('kind', ap.kind, 'decision', ap.decision, 'decided_by', ap.decided_by,
                                          'decided_at', ap.decided_at) ORDER BY ap.requested_at)
        FROM aigov.approvals ap WHERE ap.remediation_action_id = r.id) AS approvals
FROM aigov.remediation_actions r
JOIN aigov.findings f ON f.id = r.finding_id
JOIN aigov.ai_agents a ON a.id = f.agent_id;

REVOKE ALL ON FUNCTION aigov.finding_status_for(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_finding_context(uuid), api.begin_remediation(uuid, uuid, text, text, jsonb, jsonb, boolean, jsonb, jsonb),
  api.update_remediation(uuid, text, jsonb, jsonb, bigint),
  api.record_approval(uuid, text, text, text, text, timestamptz, text, text[], text),
  api.close_finding(uuid, uuid, text), api.record_outcome(uuid, uuid, text, jsonb, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_finding_context(uuid), api.begin_remediation(uuid, uuid, text, text, jsonb, jsonb, boolean, jsonb, jsonb),
  api.update_remediation(uuid, text, jsonb, jsonb, bigint),
  api.record_approval(uuid, text, text, text, text, timestamptz, text, text[], text),
  api.close_finding(uuid, uuid, text), api.record_outcome(uuid, uuid, text, jsonb, uuid, int) TO aigov_remediator;
REVOKE ALL ON api.remediations FROM PUBLIC;
GRANT SELECT ON api.remediations TO aigov_remediator, aigov_reader, aigov_evaluator;

NOTIFY pgrst, 'reload schema';
