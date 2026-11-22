-- V011 (T2.09): outcomes that WF-02 records on its other branches:
--   no_longer_detected (reassessment: the finding's policy passes now), missing_evidence (the evidence is missing; the owner
--   is asked, never remediated), assessment_error (reassessment failed), halted (the plan stopped: not eligible or failed).
-- Unchanged otherwise. Forward-only: add V012+ for changes.

CREATE OR REPLACE FUNCTION api.record_outcome(governance_run_id uuid, finding_id uuid, outcome text, reasons jsonb DEFAULT '[]',
                                   remediation_id uuid DEFAULT NULL, cooldown_minutes int DEFAULT 60)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  f aigov.findings;
  cool timestamptz;
BEGIN
  IF outcome NOT IN ('remediated', 'detect_only', 'denied', 'simulated', 'rejected', 'expired', 'failed',
                     'verification_failed', 'rolled_back', 'escalated',
                     -- V011 (WF-02): outcomes of the reassessment and plan branches
                     'no_longer_detected', 'missing_evidence', 'assessment_error', 'halted') THEN
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
