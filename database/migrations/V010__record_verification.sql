-- V010 (T2.07): verification of an executed remediation (docs/plan/04 section 9.1).
--   api.record_verification records the verification evaluation and decides, in one transaction:
--     target policy pass (computed here from the OPA result), no regressions (a policy that passed in the agent's last
--     evaluation before the remediation and fails now; computed here), the effective-permission probes denied and the
--     agent operational (reported by the Verify job from AWS). verified -> the finding is resolved (api.close_finding);
--     otherwise verification_failed, and the finding stays for rollback or a human.
--   The Verify job runs with the remediator role only, so it also reads api.evaluation_inputs.
-- Forward-only: add V011+ for changes.

CREATE FUNCTION api.record_verification(remediation_id uuid, result jsonb, input_hash text, checks jsonb,
                                        aap_job_id bigint DEFAULT NULL, opa_decision_id text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  ra aigov.remediation_actions;
  f aigov.findings;
  ev json;
  eval_id uuid;
  baseline uuid;
  target text;
  regressed text[];
  sim text := coalesce(checks ->> 'simulation_admin_probes', 'unknown');
  agent_status text := coalesce(checks ->> 'agent_status', 'unknown');
  ok boolean;
  new_status text;
  report jsonb;
BEGIN
  SELECT * INTO ra FROM aigov.remediation_actions x WHERE x.id = record_verification.remediation_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown remediation_id'); END IF;
  IF ra.status <> 'succeeded' THEN
    PERFORM aigov.api_error(format('only an executed (succeeded) remediation is verified; this one is %s', ra.status));
  END IF;
  SELECT * INTO f FROM aigov.findings WHERE id = ra.finding_id FOR UPDATE;
  IF sim NOT IN ('all_denied', 'some_allowed', 'unknown', 'not_applicable') THEN
    PERFORM aigov.api_error('checks.simulation_admin_probes must be all_denied, some_allowed, unknown or not_applicable');
  END IF;

  -- The baseline for the regression check: the agent's last evaluation before the remediation was planned
  SELECT e.id INTO baseline FROM aigov.policy_evaluations e
  WHERE e.agent_id = f.agent_id AND e.evaluated_at < ra.created_at ORDER BY e.evaluated_at DESC LIMIT 1;

  ev := api.record_evaluation(ra.governance_run_id, f.agent_id, 'verification', result, input_hash, opa_decision_id);
  eval_id := (ev ->> 'evaluation_id')::uuid;

  SELECT pr.decision INTO target FROM aigov.policy_results pr WHERE pr.evaluation_id = eval_id AND pr.policy_id = f.policy_id;
  SELECT coalesce(array_agg(b.policy_id ORDER BY b.policy_id), '{}') INTO regressed
  FROM aigov.policy_results b JOIN aigov.policy_results n ON n.policy_id = b.policy_id AND n.evaluation_id = eval_id
  WHERE b.evaluation_id = baseline AND b.decision = 'pass' AND n.decision = 'fail';

  ok := target = 'pass' AND cardinality(regressed) = 0 AND sim IN ('all_denied', 'not_applicable')
        AND upper(agent_status) IN ('READY', 'PREPARED');
  new_status := CASE WHEN ok THEN 'verified' ELSE 'verification_failed' END;
  report := jsonb_build_object('evaluation_id', eval_id, 'baseline_evaluation_id', baseline,
                               'target_policy_decision', coalesce(target, 'missing'), 'regressions', cardinality(regressed),
                               'regressed_policies', to_jsonb(regressed), 'simulation_admin_probes', sim,
                               'agent_status', agent_status, 'functional_check', coalesce(checks ->> 'functional_check', 'skipped'));

  UPDATE aigov.remediation_actions x
  SET status = new_status, updated_at = now(),
      post_state = coalesce(x.post_state, '{}'::jsonb) || jsonb_build_object('verification', report),
      error = CASE WHEN ok THEN x.error ELSE jsonb_build_object('phase', 'verify', 'checks', report) END,
      aap_job_ids = CASE WHEN record_verification.aap_job_id IS NULL OR record_verification.aap_job_id = ANY (x.aap_job_ids)
                         THEN x.aap_job_ids ELSE x.aap_job_ids || record_verification.aap_job_id END
  WHERE x.id = ra.id;
  UPDATE aigov.findings x SET status = aigov.finding_status_for(new_status)
  WHERE x.id = f.id AND x.status NOT IN ('resolved', 'false_positive');
  PERFORM aigov.audit(CASE WHEN ok THEN 'verification.passed' ELSE 'verification.failed' END, 'service', aigov.api_actor(),
                      'aap', ra.governance_run_id, f.agent_id, f.id, aap_job_id::text,
                      jsonb_build_object('from', 'succeeded', 'to', new_status, 'action_type', ra.action_type) || report, ra.id);
  IF ok THEN
    PERFORM api.close_finding(f.id, eval_id, 'remediated');
  END IF;

  SELECT * INTO f FROM aigov.findings WHERE id = ra.finding_id;
  RETURN jsonb_build_object('remediation_id', ra.id, 'status', new_status, 'finding_status', f.status) || report;
END
$$;

REVOKE ALL ON FUNCTION api.record_verification(uuid, jsonb, text, jsonb, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_verification(uuid, jsonb, text, jsonb, bigint, text) TO aigov_remediator;
GRANT SELECT ON api.evaluation_inputs TO aigov_remediator;
-- Functions inside a view run with the CALLER's privileges (as for the evaluator in V002).
GRANT USAGE ON SCHEMA aigov TO aigov_remediator;
GRANT EXECUTE ON FUNCTION aigov.rfc3339(text), aigov.rfc3339_members(jsonb) TO aigov_remediator;
