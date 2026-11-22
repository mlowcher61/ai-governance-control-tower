-- V012 (T2.10): audit completeness of a governance run (docs/plan/04 section 9.4 "Audit every action").
--   api.audit_completeness(governance_run_id) checks that every event the run's remediations imply is in the audit
--   trail, and that the hash chain from the run's first event is intact. Finalize (Record Remediation Outcome) calls it
--   at the end of every WF-02 branch. Forward-only: add V013+ for changes.

CREATE FUNCTION api.audit_completeness(governance_run_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  run uuid := audit_completeness.governance_run_id;
  ra aigov.remediation_actions;
  checks jsonb := '[]';
  first_id bigint;
  broken record;
  has_outcome boolean;

  -- one check: the event exists for this remediation (optionally with details->>'kind' and actor type)
  ok boolean;
BEGIN
  SELECT min(e.id) INTO first_id FROM aigov.audit_events e WHERE e.governance_run_id = run;
  IF first_id IS NULL THEN PERFORM aigov.api_error('no audit events for this governance run'); END IF;

  has_outcome := EXISTS (SELECT FROM aigov.audit_events e WHERE e.governance_run_id = run
                           AND e.event_type IN ('remediation.outcome', 'remediation.outcome_unknown_finding'));
  checks := checks || jsonb_build_object('check', 'outcome recorded', 'ok', has_outcome);

  FOR ra IN SELECT * FROM aigov.remediation_actions r WHERE r.governance_run_id = run ORDER BY r.created_at LOOP
    -- planned
    ok := EXISTS (SELECT FROM aigov.audit_events e WHERE e.remediation_action_id = ra.id AND e.event_type = 'remediation.planned');
    checks := checks || jsonb_build_object('check', 'planned', 'remediation_id', ra.id, 'ok', ok);
    -- a human (or the expiry) decided when OPA required approval and the remediation went past the approval
    IF ra.authz_decision ->> 'approval_required' = 'yes'
       AND ra.status NOT IN ('planned', 'awaiting_approval', 'skipped') THEN
      ok := EXISTS (SELECT FROM aigov.audit_events e WHERE e.remediation_action_id = ra.id AND e.event_type = 'approval.decided'
                      AND e.details ->> 'kind' = 'remediation'
                      AND (e.actor_type = 'human' OR e.details ->> 'decision' = 'expired'));
      checks := checks || jsonb_build_object('check', 'approval decided by a person', 'remediation_id', ra.id, 'ok', ok);
    END IF;
    -- executed (or failed)
    IF ra.status IN ('executing', 'succeeded', 'failed', 'verified', 'verification_failed', 'rolled_back', 'rollback_failed') THEN
      ok := EXISTS (SELECT FROM aigov.audit_events e WHERE e.remediation_action_id = ra.id AND e.event_type = 'remediation.executing')
            AND (ra.status = 'executing' OR EXISTS (SELECT FROM aigov.audit_events e WHERE e.remediation_action_id = ra.id
                                                    AND e.event_type IN ('remediation.executed', 'remediation.failed')));
      checks := checks || jsonb_build_object('check', 'execution recorded', 'remediation_id', ra.id, 'ok', ok);
    END IF;
    -- verified (or failed verification)
    IF ra.status IN ('verified', 'verification_failed') THEN
      ok := EXISTS (SELECT FROM aigov.audit_events e WHERE e.remediation_action_id = ra.id
                      AND e.event_type IN ('verification.passed', 'verification.failed'));
      checks := checks || jsonb_build_object('check', 'verification recorded', 'remediation_id', ra.id, 'ok', ok);
    END IF;
    IF ra.status = 'verified' THEN
      ok := EXISTS (SELECT FROM aigov.audit_events e WHERE e.remediation_action_id = ra.id AND e.event_type = 'finding.resolved');
      checks := checks || jsonb_build_object('check', 'finding resolved after verification', 'remediation_id', ra.id, 'ok', ok);
    END IF;
    -- rollback: approved by a person, then executed (or failed)
    IF ra.status IN ('rolled_back', 'rollback_failed') THEN
      ok := EXISTS (SELECT FROM aigov.audit_events e WHERE e.remediation_action_id = ra.id AND e.event_type = 'approval.decided'
                      AND e.details ->> 'kind' = 'rollback' AND e.details ->> 'decision' = 'approved' AND e.actor_type = 'human')
            AND EXISTS (SELECT FROM aigov.audit_events e WHERE e.remediation_action_id = ra.id
                          AND e.event_type IN ('rollback.executed', 'rollback.failed'));
      checks := checks || jsonb_build_object('check', 'rollback approved and recorded', 'remediation_id', ra.id, 'ok', ok);
    END IF;
  END LOOP;

  SELECT * INTO broken FROM aigov.verify_audit_chain(first_id) LIMIT 1;
  checks := checks || jsonb_build_object('check', 'audit hash chain intact', 'ok', broken.broken_id IS NULL,
                                         'broken_id', broken.broken_id, 'reason', broken.reason);

  RETURN json_build_object(
    'governance_run_id', run,
    'complete', NOT EXISTS (SELECT FROM jsonb_array_elements(checks) c WHERE (c ->> 'ok')::boolean IS NOT TRUE),
    'missing', (SELECT coalesce(json_agg(c ->> 'check' || coalesce(' (' || (c ->> 'remediation_id') || ')', '')), '[]'::json)
                FROM jsonb_array_elements(checks) c WHERE (c ->> 'ok')::boolean IS NOT TRUE),
    'events', (SELECT count(*) FROM aigov.audit_events e WHERE e.governance_run_id = run),
    'checks', checks);
END
$$;

REVOKE ALL ON FUNCTION api.audit_completeness(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.audit_completeness(uuid) TO aigov_remediator, aigov_auditor;
