-- V009 (T2.05): what Execute Remediation needs.
--   * api.get_remediation: the full remediation record (authorization, planned change, pre-state) for the
--     remediator, so Execute acts on the recorded plan, never on launch-time variables.
--   * api.record_approval: unchanged, plus separation of duties - the agent's registered owner cannot approve.
-- Forward-only: add V010+ for changes.

CREATE FUNCTION api.get_remediation(remediation_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  res json;
BEGIN
  SELECT json_build_object(
    'remediation_id', r.id, 'governance_run_id', r.governance_run_id, 'finding_id', r.finding_id,
    'action_type', r.action_type, 'mode', r.mode, 'status', r.status, 'attempt_number', r.attempt_number,
    'authz_decision', r.authz_decision, 'planned_change', r.planned_change, 'pre_state', r.pre_state,
    'post_state', r.post_state, 'error', r.error, 'aap_job_ids', r.aap_job_ids,
    'approvals', (SELECT coalesce(json_agg(json_build_object('kind', ap.kind, 'decision', ap.decision,
                                                             'decided_by', ap.decided_by, 'decided_at', ap.decided_at)
                                           ORDER BY ap.requested_at), '[]'::json)
                  FROM aigov.approvals ap WHERE ap.remediation_action_id = r.id))
  INTO res
  FROM aigov.remediation_actions r WHERE r.id = get_remediation.remediation_id;
  IF res IS NULL THEN PERFORM aigov.api_error('unknown remediation_id'); END IF;
  RETURN res;
END
$$;

CREATE OR REPLACE FUNCTION api.record_approval(remediation_id uuid, decision text, decided_by text DEFAULT NULL,
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
  -- Separation of duties (docs/plan/04 section 8): the agent's registered owner cannot approve its remediation.
  IF decision = 'approved' AND EXISTS (
       SELECT FROM aigov.findings f2
       JOIN aigov.ai_agents a ON a.id = f2.agent_id
       JOIN aigov.agent_registrations g ON g.registration_id = a.registration_id
       JOIN aigov.owners o ON o.id = g.owner_id
       WHERE f2.id = ra.finding_id
         AND lower(btrim(decided_by)) IN (lower(o.id), lower(coalesce(o.email, '')), lower(coalesce(o.name, '')))) THEN
    PERFORM aigov.api_error('the agent owner cannot approve its own remediation (separation of duties)');
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

REVOKE ALL ON FUNCTION api.get_remediation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_remediation(uuid) TO aigov_remediator;
