-- V004 (T1.11): close a governance run with its summary (the last step of WF-01).
-- Forward-only: add V005+ for changes.

CREATE FUNCTION api.complete_governance_run(governance_run_id uuid, status text, summary jsonb DEFAULT '{}',
                                            ao_execution_id text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  run aigov.governance_runs;
BEGIN
  IF status NOT IN ('completed', 'partial', 'failed') THEN
    PERFORM aigov.api_error('status must be completed, partial or failed');
  END IF;
  IF jsonb_typeof(coalesce(summary, '{}')) <> 'object' THEN
    PERFORM aigov.api_error('summary must be an object');
  END IF;
  SELECT * INTO run FROM aigov.governance_runs g WHERE g.id = complete_governance_run.governance_run_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown governance_run_id'); END IF;

  UPDATE aigov.governance_runs g
  SET status = complete_governance_run.status, finished_at = now(),
      ao_execution_id = coalesce(complete_governance_run.ao_execution_id, g.ao_execution_id)
  WHERE g.id = run.id;
  PERFORM aigov.audit('governance.run_completed', 'service', aigov.api_actor(), 'aap', run.id,
                      source_ref => complete_governance_run.ao_execution_id,
                      details => jsonb_build_object('status', status, 'summary', coalesce(summary, '{}'),
                                                    'started_at', run.started_at, 'previous_status', run.status));
  RETURN json_build_object('governance_run_id', run.id, 'status', status, 'started_at', run.started_at, 'finished_at', now());
END
$$;

REVOKE ALL ON FUNCTION api.complete_governance_run(uuid, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.complete_governance_run(uuid, text, jsonb, text) TO aigov_evaluator;

NOTIFY pgrst, 'reload schema';
