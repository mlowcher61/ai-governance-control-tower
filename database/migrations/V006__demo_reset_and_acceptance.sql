-- V006 (T1.13): demo reset and the read-only views behind the Stage 1 acceptance checks.
-- Forward-only: add V007+ for changes.

-- Reset the governance state of DEMO agents only (agents whose tag tag_key equals tag_value, by default
-- aigov:demo=true): open findings are resolved with resolution 'demo_reset', and the agents are marked not
-- evaluated. Nothing is deleted: evaluations, results, snapshots and the audit log are kept, and each reset agent
-- gets a 'demo.reset' audit event. Only the remediator role may call it.
CREATE FUNCTION api.reset_demo(reason text DEFAULT 'demo reset', tag_key text DEFAULT 'aigov:demo', tag_value text DEFAULT 'true')
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  a record;
  n_findings int;
  agents jsonb := '[]';
  total int := 0;
BEGIN
  IF coalesce(tag_key, '') = '' OR coalesce(tag_value, '') = '' THEN
    PERFORM aigov.api_error('tag_key and tag_value are required (only demo-tagged agents can be reset)');
  END IF;
  FOR a IN SELECT g.id, g.name FROM aigov.ai_agents g WHERE g.tags ->> reset_demo.tag_key = reset_demo.tag_value ORDER BY g.name LOOP
    UPDATE aigov.findings f SET status = 'resolved', resolution = 'demo_reset', resolved_at = now()
    WHERE f.agent_id = a.id AND f.status NOT IN ('resolved', 'false_positive');
    GET DIAGNOSTICS n_findings = ROW_COUNT;
    UPDATE aigov.ai_agents g SET compliance_status = 'not_evaluated', risk_score = NULL, risk_category = NULL, last_evaluated_at = NULL
    WHERE g.id = a.id;
    PERFORM aigov.audit('demo.reset', 'service', aigov.api_actor(), 'aap', agent_id => a.id,
                        details => jsonb_build_object('reason', reason, 'findings_resolved', n_findings));
    agents := agents || jsonb_build_object('agent', a.name, 'findings_resolved', n_findings);
    total := total + n_findings;
  END LOOP;
  RETURN json_build_object('agents', agents, 'findings_resolved', total);
END
$$;

-- Latest assessment per agent: how many policies were evaluated and in which governance run (A1-3, A1-5)
CREATE VIEW api.agent_assessment AS
SELECT le.agent_id, a.name, le.governance_run_id, le.overall_status, le.risk_score, le.risk_category, le.evaluated_at,
       le.bundle_revision,
       (SELECT count(*) FROM aigov.policy_results r WHERE r.evaluation_id = le.evaluation_id) AS policies_evaluated,
       (SELECT count(*) FROM aigov.findings f WHERE f.agent_id = le.agent_id AND f.latest_evaluation_id IN
          (SELECT e.id FROM aigov.policy_evaluations e WHERE e.governance_run_id = le.governance_run_id)
          AND f.status NOT IN ('resolved', 'false_positive')) AS open_findings_from_run
FROM reporting.latest_evaluation le
JOIN aigov.ai_agents a ON a.id = le.agent_id
WHERE a.missing_since IS NULL;

-- Governance runs with what they produced (A1-5)
CREATE VIEW api.governance_runs AS
SELECT governance_run_id, run_type, status, started_at, finished_at, agents_evaluated, findings_opened, findings_closed, ai_explanations
FROM reporting.governance_runs_recent;

REVOKE ALL ON FUNCTION api.reset_demo(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reset_demo(text, text, text) TO aigov_remediator;
REVOKE ALL ON api.agent_assessment, api.governance_runs FROM PUBLIC;
GRANT SELECT ON api.agent_assessment, api.governance_runs TO aigov_evaluator, aigov_reader;

NOTIFY pgrst, 'reload schema';
