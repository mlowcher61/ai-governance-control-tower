-- V008 (T2.04): get_finding_context also returns what the Plan job needs for the blast radius and the governance
-- tags: other inventoried agents that use the same execution role, and the registry facts (owner, environment,
-- data classification). Forward-only: add V009+ for changes.

CREATE OR REPLACE FUNCTION api.get_finding_context(finding_id uuid)
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
                              AND r.status IN ('planned', 'awaiting_approval', 'approved', 'executing')),
    -- blast radius: other agents in the inventory that run as the same role
    'agents_sharing_role', CASE WHEN a.identity_id IS NULL THEN NULL ELSE
      (SELECT count(*) FROM aigov.ai_agents o WHERE o.identity_id = a.identity_id AND o.id <> a.id AND o.missing_since IS NULL) END,
    'tags', a.tags,
    'registration', CASE WHEN g.registration_id IS NULL THEN NULL ELSE json_build_object(
      'registration_id', g.registration_id, 'owner_id', o2.id, 'owner_name', o2.name, 'owner_email', o2.email,
      'owner_approved', o2.approved, 'environment', g.environment, 'data_classification', g.data_classification) END)
  INTO res
  FROM aigov.findings f
  JOIN aigov.ai_agents a ON a.id = f.agent_id
  JOIN aigov.cloud_accounts c ON c.id = a.account_id
  LEFT JOIN aigov.agent_identities i ON i.id = a.identity_id
  LEFT JOIN aigov.agent_registrations g ON g.registration_id = a.registration_id
  LEFT JOIN aigov.owners o2 ON o2.id = g.owner_id
  WHERE f.id = get_finding_context.finding_id;
  IF res IS NULL THEN PERFORM aigov.api_error('unknown finding_id'); END IF;
  RETURN res;
END
$$;

REVOKE ALL ON FUNCTION api.get_finding_context(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_finding_context(uuid) TO aigov_remediator;

NOTIFY pgrst, 'reload schema';
