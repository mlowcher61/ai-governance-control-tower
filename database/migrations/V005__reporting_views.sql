-- V005 (T1.12): reporting views for the Grafana dashboards (docs/plan/05 section 6).
-- Dashboards query only these views, never the aigov tables, so the schema can evolve without breaking them.
-- Readers: grafana_ro (Grafana) and aigov_auditor. Forward-only: add V006+ for changes.

-- Latest assessment evaluation per agent
CREATE VIEW reporting.latest_evaluation AS
SELECT DISTINCT ON (e.agent_id)
       e.id AS evaluation_id, e.agent_id, e.governance_run_id, e.bundle_revision, e.overall_status,
       e.risk_score, e.risk_category, e.risk_factors, e.evaluated_at
FROM aigov.policy_evaluations e
WHERE e.purpose = 'assessment'
ORDER BY e.agent_id, e.evaluated_at DESC, e.id;

-- Agents currently in the inventory (not missing)
CREATE VIEW reporting.agent_current AS
SELECT a.id AS agent_id, a.name, a.provider, a.platform, c.account_ref, a.region, a.external_id, a.resource_ref,
       coalesce(a.environment, g.environment, 'unknown') AS environment, a.status,
       a.registration_status, a.registration_id, o.name AS owner_name, coalesce(o.approved, false) AS owner_approved,
       coalesce(m.model_id, g.declared_model) AS model, (m.model_id IS NULL AND g.declared_model IS NOT NULL) AS model_declared,
       i.principal_ref AS execution_role, a.compliance_status, a.risk_score, coalesce(a.risk_category, 'not evaluated') AS risk_category,
       CASE coalesce(a.risk_category, '') WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END AS risk_rank,
       (SELECT count(*) FROM aigov.findings f WHERE f.agent_id = a.id AND f.status NOT IN ('resolved', 'false_positive')) AS open_findings,
       a.evidence_status, a.tags, a.first_seen_at, a.last_seen_at, a.last_evaluated_at
FROM aigov.ai_agents a
JOIN aigov.cloud_accounts c ON c.id = a.account_id
LEFT JOIN aigov.ai_models m ON m.id = a.model_id
LEFT JOIN aigov.agent_identities i ON i.id = a.identity_id
LEFT JOIN aigov.agent_registrations g ON g.registration_id = a.registration_id
LEFT JOIN aigov.owners o ON o.id = g.owner_id
WHERE a.missing_since IS NULL AND a.registration_status <> 'retired';

-- Open findings with age and the advisory AI headline
CREATE VIEW reporting.findings_open AS
SELECT f.id AS finding_id, f.agent_id, a.name AS agent_name, a.platform, f.policy_id, f.finding_type, f.status,
       f.severity,
       CASE f.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END AS severity_rank,
       f.deterministic_explanation, f.ai_explanation ->> 'headline' AS ai_headline,
       f.ai_explanation ->> 'risk_explanation' AS ai_risk_explanation,
       f.ai_explanation ->> 'recommended_next_step' AS ai_next_step,
       f.first_detected_at, f.last_detected_at,
       round(extract(epoch FROM (now() - f.first_detected_at)) / 86400.0, 1) AS age_days
FROM aigov.findings f
JOIN aigov.ai_agents a ON a.id = f.agent_id
WHERE f.status NOT IN ('resolved', 'false_positive') AND a.missing_since IS NULL;

-- Per-policy results of each agent's latest assessment, with the AI explanation of the matching finding
CREATE VIEW reporting.policy_results_latest AS
SELECT le.agent_id, a.name AS agent_name, r.policy_id, r.policy_version, r.decision, r.severity, r.explanation,
       r.evidence, r.assumptions, r.controls, r.remediation ->> 'summary' AS remediation_summary,
       f.ai_explanation ->> 'headline' AS ai_headline, f.ai_explanation ->> 'risk_explanation' AS ai_risk_explanation,
       le.evaluated_at, le.bundle_revision
FROM reporting.latest_evaluation le
JOIN aigov.ai_agents a ON a.id = le.agent_id
JOIN aigov.policy_results r ON r.evaluation_id = le.evaluation_id
LEFT JOIN aigov.findings f ON f.agent_id = le.agent_id AND f.policy_id = r.policy_id
     AND f.status NOT IN ('resolved', 'false_positive');

-- Risk factors of each agent's latest assessment
CREATE VIEW reporting.agent_risk_factors AS
SELECT le.agent_id, a.name AS agent_name, x ->> 'factor' AS factor, (x ->> 'points')::int AS points
FROM reporting.latest_evaluation le
JOIN aigov.ai_agents a ON a.id = le.agent_id
CROSS JOIN LATERAL jsonb_array_elements(le.risk_factors) AS x;

-- The execution role's current policies, flagged when the latest assessment cites them (IAM-001 / IAM-002)
CREATE VIEW reporting.agent_permissions AS
SELECT a.id AS agent_id, a.name AS agent_name, i.principal_ref AS execution_role, p.policy_type, p.policy_ref,
       coalesce(p.policy_name, p.policy_ref) AS policy_name, jsonb_array_length(p.document) AS statements,
       EXISTS (SELECT FROM jsonb_array_elements(p.document) s, jsonb_array_elements_text(coalesce(s -> 'actions', '[]')) act
               WHERE s ->> 'effect' = 'Allow' AND act IN ('*', '*:*')) AS grants_all_actions,
       EXISTS (SELECT FROM reporting.policy_results_latest r, jsonb_array_elements(r.evidence) ev
               WHERE r.agent_id = a.id AND r.policy_id = 'AIGOV-IAM-001' AND r.decision = 'fail'
                 AND ev -> 'value' ->> 'source' = p.policy_ref) AS flagged_admin,
       EXISTS (SELECT FROM reporting.policy_results_latest r, jsonb_array_elements(r.evidence) ev
               WHERE r.agent_id = a.id AND r.policy_id = 'AIGOV-IAM-002' AND r.decision = 'fail'
                 AND ev -> 'value' ->> 'source' = p.policy_ref) AS flagged_dangerous,
       p.collected_at
FROM aigov.ai_agents a
JOIN aigov.agent_identities i ON i.id = a.identity_id
JOIN aigov.identity_permissions p ON p.identity_id = i.id AND p.removed_at IS NULL
WHERE a.missing_since IS NULL;

-- Share of latest policy results that are decided (not unknown): how complete the evidence is
CREATE VIEW reporting.evidence_coverage AS
SELECT count(*) FILTER (WHERE r.decision <> 'unknown') AS decided,
       count(*) FILTER (WHERE r.decision = 'unknown') AS unknown,
       count(*) AS total,
       CASE WHEN count(*) = 0 THEN NULL
            ELSE round(100.0 * count(*) FILTER (WHERE r.decision <> 'unknown') / count(*), 1) END AS coverage_pct
FROM reporting.policy_results_latest r
JOIN aigov.ai_agents a ON a.id = r.agent_id
WHERE a.missing_since IS NULL;

-- Daily compliance: each agent's last assessment of the day
CREATE VIEW reporting.compliance_daily AS
WITH daily AS (
  SELECT DISTINCT ON (date_trunc('day', e.evaluated_at), e.agent_id)
         date_trunc('day', e.evaluated_at) AS day, e.agent_id, e.overall_status
  FROM aigov.policy_evaluations e
  WHERE e.purpose = 'assessment'
  ORDER BY date_trunc('day', e.evaluated_at), e.agent_id, e.evaluated_at DESC
)
SELECT day,
       count(*) FILTER (WHERE overall_status = 'compliant') AS compliant,
       count(*) FILTER (WHERE overall_status = 'noncompliant') AS noncompliant,
       count(*) FILTER (WHERE overall_status IN ('unknown', 'error')) AS unknown,
       count(*) AS agents,
       round(100.0 * count(*) FILTER (WHERE overall_status = 'compliant') / count(*), 1) AS compliant_pct
FROM daily
GROUP BY day;

-- Governance runs with what each one did
CREATE VIEW reporting.governance_runs_recent AS
SELECT g.id AS governance_run_id, g.run_type, g.trigger_type, g.status, g.started_at, g.finished_at,
       round(extract(epoch FROM (coalesce(g.finished_at, now()) - g.started_at)) / 60.0, 1) AS duration_min,
       g.ao_execution_id,
       (SELECT count(DISTINCT e.agent_id) FROM aigov.policy_evaluations e WHERE e.governance_run_id = g.id) AS agents_evaluated,
       (SELECT count(*) FROM aigov.audit_events ae WHERE ae.governance_run_id = g.id AND ae.event_type = 'finding.opened') AS findings_opened,
       (SELECT count(*) FROM aigov.audit_events ae WHERE ae.governance_run_id = g.id AND ae.event_type = 'finding.auto_closed') AS findings_closed,
       (SELECT count(*) FROM aigov.audit_events ae WHERE ae.governance_run_id = g.id AND ae.event_type = 'ai.explanation_generated') AS ai_explanations
FROM aigov.governance_runs g;

-- Configuration history per agent (a snapshot is written only when the content changed)
CREATE VIEW reporting.agent_changes AS
SELECT s.agent_id, a.name AS agent_name, s.observed_at, s.content_hash, s.discovery_run_id,
       s.record #>> '{identity,principal_ref}' AS execution_role,
       (SELECT string_agg(coalesce(p ->> 'name', p ->> 'ref'), ', ' ORDER BY p ->> 'ref')
        FROM jsonb_array_elements(coalesce(s.record #> '{identity,policies}', '[]')) p) AS role_policies,
       s.record ->> 'status' AS status
FROM aigov.agent_snapshots s
JOIN aigov.ai_agents a ON a.id = s.agent_id;

-- Audit timeline per agent (hash-chained log; details summarized)
CREATE VIEW reporting.agent_audit AS
SELECT e.id AS event_id, e.occurred_at, e.agent_id, a.name AS agent_name, e.event_type, e.actor_type, e.actor_id,
       e.source_system, e.source_ref, e.governance_run_id,
       coalesce(e.details ->> 'policy_id', e.details ->> 'overall_status', e.details ->> 'external_id', '') AS subject
FROM aigov.audit_events e
JOIN aigov.ai_agents a ON a.id = e.agent_id;

REVOKE ALL ON ALL TABLES IN SCHEMA reporting FROM PUBLIC;
GRANT USAGE ON SCHEMA reporting TO grafana_ro, aigov_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO grafana_ro, aigov_auditor;
