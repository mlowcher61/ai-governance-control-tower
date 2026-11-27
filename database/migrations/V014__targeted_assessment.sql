-- V014 (T3.03): targeted re-assessment after a change event (WF-03, docs/plan/05 sections 2.3-2.4).
--   api.start_targeted_assessment(change_event_id) opens a governance run (run_type targeted_reassessment, trigger
--   event or manual). The Assess Agents job then records an assessment evaluation per affected agent (findings open,
--   update and close as in a full assessment; the inventory itself is not rewritten).
--   api.complete_targeted_assessment(run, change_event_id) returns the violations that are NEW (opened in this run)
--   or WORSENED (severity raised in this run) - the findings WF-03 sends to WF-02 - stamps new findings with the
--   change's event time (source_change_at, for time-to-detect reporting), and closes the run.
-- Forward-only: add V015+ for changes.

CREATE FUNCTION api.start_targeted_assessment(change_event_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  rid uuid := gen_random_uuid();
BEGIN
  IF change_event_id IS NOT NULL AND NOT EXISTS (SELECT FROM aigov.change_events c WHERE c.id = start_targeted_assessment.change_event_id) THEN
    PERFORM aigov.api_error('unknown change_event_id');
  END IF;
  INSERT INTO aigov.governance_runs (id, run_type, trigger_type, trigger_ref)
  VALUES (rid, 'targeted_reassessment', CASE WHEN change_event_id IS NULL THEN 'manual' ELSE 'event' END, change_event_id::text);
  PERFORM aigov.audit('governance.run_started', 'service', aigov.api_actor(), 'aap', rid,
                      details => jsonb_build_object('run_type', 'targeted_reassessment', 'change_event_id', change_event_id));
  RETURN json_build_object('governance_run_id', rid);
END
$$;

CREATE FUNCTION api.complete_targeted_assessment(governance_run_id uuid, change_event_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  run aigov.governance_runs;
  ce aigov.change_events;
  new_ids uuid[];
  worse_ids uuid[];
  evaluated int;
BEGIN
  SELECT * INTO run FROM aigov.governance_runs r WHERE r.id = complete_targeted_assessment.governance_run_id FOR UPDATE;
  IF NOT FOUND OR run.run_type <> 'targeted_reassessment' THEN PERFORM aigov.api_error('not a targeted re-assessment run'); END IF;
  IF change_event_id IS NOT NULL THEN
    SELECT * INTO ce FROM aigov.change_events c WHERE c.id = complete_targeted_assessment.change_event_id;
  END IF;
  SELECT count(*) INTO evaluated FROM aigov.policy_evaluations e WHERE e.governance_run_id = run.id AND e.purpose = 'assessment';

  -- New: violation findings opened by this run's evaluations
  SELECT coalesce(array_agg(f.id ORDER BY f.severity, f.id), '{}') INTO new_ids
  FROM aigov.findings f JOIN aigov.policy_evaluations e ON e.id = f.latest_evaluation_id
  WHERE e.governance_run_id = run.id AND f.finding_type = 'violation' AND f.status NOT IN ('resolved', 'false_positive')
    AND f.first_detected_at >= run.started_at;

  -- Worsened: open violations whose severity this run raised (audited by record_evaluation as finding.updated)
  SELECT coalesce(array_agg(DISTINCT f.id), '{}') INTO worse_ids
  FROM aigov.audit_events a JOIN aigov.findings f ON f.id = a.finding_id
  WHERE a.governance_run_id = run.id AND a.event_type = 'finding.updated' AND f.finding_type = 'violation'
    AND f.status NOT IN ('resolved', 'false_positive') AND NOT f.id = ANY (new_ids)
    AND array_position(ARRAY['info', 'low', 'medium', 'high', 'critical'], a.details ->> 'severity')
        > array_position(ARRAY['info', 'low', 'medium', 'high', 'critical'], a.details ->> 'previous_severity');

  IF ce.id IS NOT NULL AND ce.event_time IS NOT NULL AND cardinality(new_ids) > 0 THEN
    UPDATE aigov.findings f SET source_change_at = ce.event_time WHERE f.id = ANY (new_ids);
  END IF;
  UPDATE aigov.governance_runs r SET finished_at = now(), status = 'succeeded' WHERE r.id = run.id;
  PERFORM aigov.audit('governance.run_completed', 'service', aigov.api_actor(), 'aap', run.id,
                      details => jsonb_build_object('run_type', 'targeted_reassessment', 'change_event_id', ce.id,
                                                    'agents_evaluated', evaluated, 'new_violations', to_jsonb(new_ids),
                                                    'worsened_violations', to_jsonb(worse_ids)));
  RETURN json_build_object('governance_run_id', run.id, 'agents_evaluated', evaluated,
                           'new_violation_finding_ids', new_ids, 'worsened_violation_finding_ids', worse_ids,
                           'remediation_candidates', new_ids || worse_ids);
END
$$;

REVOKE ALL ON FUNCTION api.start_targeted_assessment(uuid), api.complete_targeted_assessment(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.start_targeted_assessment(uuid), api.complete_targeted_assessment(uuid, uuid) TO aigov_evaluator;
