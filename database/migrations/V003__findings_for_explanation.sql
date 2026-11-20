-- V003 (T1.10): the findings the AI explanation step may see.
--
-- docs/plan/08: the AI task agent only receives deterministic, structured data. Anything an agent owner
-- controls (tags, descriptions, quoted values inside explanations) is masked, so prompt-injection text cannot
-- reach the prompt. Contract: schemas/findings-for-explanation.v1.json. Forward-only: add V004+ for changes.

-- Owner-controlled values appear in single quotes inside policy explanations (for example invalid tag
-- values). They are masked, every character outside a safe set is dropped, and the text is truncated.
CREATE FUNCTION aigov.safe_text(t text, max_len int DEFAULT 600) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT left(btrim(regexp_replace(
           regexp_replace(coalesce(t, ''), '''[^'']*''', '<value>', 'g'),
           '[^A-Za-z0-9 .,:;()/_=*@<>+-]', ' ', 'g')), max_len)
$$;

CREATE VIEW api.findings_for_explanation AS
SELECT
  f.id AS finding_id,
  f.policy_id,
  f.finding_type,
  f.severity,
  aigov.safe_text(f.deterministic_explanation) AS deterministic_explanation,
  jsonb_build_object(
    'name', CASE WHEN a.name ~ '^[A-Za-z0-9_.-]{1,100}$' THEN a.name ELSE 'agent-' || left(a.id::text, 8) END,
    'platform', a.platform,
    'environment', CASE WHEN a.environment ~ '^[a-z0-9_-]+$' THEN a.environment END,
    'risk_category', a.risk_category) AS agent,
  -- Next steps come only from the policy's own remediation text (never from the agent or the AI).
  CASE WHEN f.finding_type = 'insufficient_evidence'
       THEN jsonb_build_array('Ask the agent owner to supply the missing information in the governance registry',
                              'Fix the discovery permissions so the evidence can be collected')
       ELSE jsonb_build_array(aigov.safe_text(coalesce(pr.remediation ->> 'summary', 'Review the finding with the agent owner'), 200))
  END AS allowed_next_steps,
  CASE f.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END AS severity_rank,
  f.last_detected_at,
  f.ai_explanation IS NOT NULL AS explained
FROM aigov.findings f
JOIN aigov.ai_agents a ON a.id = f.agent_id
LEFT JOIN aigov.policy_results pr ON pr.evaluation_id = f.latest_evaluation_id AND pr.policy_id = f.policy_id
WHERE f.status NOT IN ('resolved', 'false_positive', 'suppressed');

REVOKE ALL ON api.findings_for_explanation FROM PUBLIC;
REVOKE ALL ON FUNCTION aigov.safe_text(text, int) FROM PUBLIC;
GRANT SELECT ON api.findings_for_explanation TO aigov_evaluator;
-- Functions inside a view run with the caller's privileges.
GRANT EXECUTE ON FUNCTION aigov.safe_text(text, int) TO aigov_evaluator;

NOTIFY pgrst, 'reload schema';
