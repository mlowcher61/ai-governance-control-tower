-- V016 (T3.05): reporting for the Stage 3 dashboards (docs/plan/05 section 6) and reports (section 8).
--   * aigov.compliance_snapshots + api.capture_compliance_snapshot(): one row per UTC day, upserted by every hourly
--     Reconcile and Sweep, so a day's row holds its last captured state (end of day for past days). The history is
--     kept even when agents, findings or evaluations are later removed. Read through reporting.compliance_trend.
--   * reporting.findings_event_attributed / reporting.mttd_daily - time to detect for findings opened by an
--     event-triggered targeted re-assessment (api.complete_targeted_assessment stamps source_change_at with the
--     CloudTrail event time): avg(first_detected_at - source_change_at).
--   * reporting.findings_remediated / reporting.mttr_daily - time to remediate for findings closed by a verified
--     remediation (resolution 'remediated'): avg(resolved_at - first_detected_at), split automatic / after approval.
--   * operations: reporting.remediations, reporting.pending_approvals, reporting.remediation_funnel,
--     reporting.change_events_daily, reporting.drift_events.
-- Readers: grafana_ro and aigov_auditor (granted explicitly; V005's grant covered only the views that existed then).
-- Forward-only: add V017+ for changes.

CREATE TABLE aigov.compliance_snapshots (
  day                 date PRIMARY KEY,
  captured_at         timestamptz NOT NULL DEFAULT now(),
  agents              int NOT NULL,
  compliant           int NOT NULL,
  noncompliant        int NOT NULL,
  unknown             int NOT NULL,
  not_evaluated       int NOT NULL,
  unregistered        int NOT NULL,
  open_findings       int NOT NULL,
  open_critical       int NOT NULL,
  open_high           int NOT NULL,
  open_medium         int NOT NULL,
  open_low            int NOT NULL,
  open_remediations   int NOT NULL,
  pending_approvals   int NOT NULL
);
REVOKE ALL ON aigov.compliance_snapshots FROM PUBLIC;

-- Same population as the dashboards: agents not missing; open findings as reporting.findings_open
CREATE FUNCTION api.capture_compliance_snapshot()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s aigov.compliance_snapshots;
BEGIN
  INSERT INTO aigov.compliance_snapshots AS c (day, agents, compliant, noncompliant, unknown, not_evaluated, unregistered,
         open_findings, open_critical, open_high, open_medium, open_low, open_remediations, pending_approvals)
  SELECT (now() AT TIME ZONE 'UTC')::date, a.agents, a.compliant, a.noncompliant, a.unknown, a.not_evaluated, a.unregistered,
         f.open, f.crit, f.high, f.med, f.low, r.open, r.pending
  FROM (SELECT count(*) AS agents,
               count(*) FILTER (WHERE x.compliance_status = 'compliant') AS compliant,
               count(*) FILTER (WHERE x.compliance_status = 'noncompliant') AS noncompliant,
               count(*) FILTER (WHERE x.compliance_status IN ('unknown', 'error')) AS unknown,
               count(*) FILTER (WHERE x.compliance_status = 'not_evaluated') AS not_evaluated,
               count(*) FILTER (WHERE x.registration_status = 'unregistered') AS unregistered
        FROM aigov.ai_agents x WHERE x.missing_since IS NULL) a,
       (SELECT count(*) AS open,
               count(*) FILTER (WHERE x.severity = 'critical') AS crit,
               count(*) FILTER (WHERE x.severity = 'high') AS high,
               count(*) FILTER (WHERE x.severity = 'medium') AS med,
               count(*) FILTER (WHERE x.severity IN ('low', 'info')) AS low
        FROM aigov.findings x JOIN aigov.ai_agents y ON y.id = x.agent_id
        WHERE x.status NOT IN ('resolved', 'false_positive') AND y.missing_since IS NULL) f,
       (SELECT count(*) FILTER (WHERE q.status IN ('planned', 'approved', 'executing', 'succeeded')) AS open,
               count(*) FILTER (WHERE q.status = 'awaiting_approval') AS pending
        FROM aigov.remediation_actions q) r
  ON CONFLICT (day) DO UPDATE SET captured_at = now(), agents = EXCLUDED.agents, compliant = EXCLUDED.compliant,
    noncompliant = EXCLUDED.noncompliant, unknown = EXCLUDED.unknown, not_evaluated = EXCLUDED.not_evaluated,
    unregistered = EXCLUDED.unregistered, open_findings = EXCLUDED.open_findings, open_critical = EXCLUDED.open_critical,
    open_high = EXCLUDED.open_high, open_medium = EXCLUDED.open_medium, open_low = EXCLUDED.open_low,
    open_remediations = EXCLUDED.open_remediations, pending_approvals = EXCLUDED.pending_approvals
  RETURNING c.* INTO s;
  RETURN row_to_json(s);
END
$$;

CREATE VIEW reporting.compliance_trend AS
SELECT day, agents, compliant, noncompliant, unknown, not_evaluated, unregistered,
       CASE WHEN agents > 0 THEN round(100.0 * compliant / agents, 1) END AS compliant_pct,
       open_findings, open_critical, open_high, open_medium, open_low, open_remediations, pending_approvals, captured_at
FROM aigov.compliance_snapshots;

-- Time to detect: only findings an AWS change event led to carry source_change_at
CREATE VIEW reporting.findings_event_attributed AS
SELECT f.id AS finding_id, f.agent_id, a.name AS agent_name, f.policy_id, f.severity, f.source_change_at,
       f.first_detected_at, round(extract(epoch FROM (f.first_detected_at - f.source_change_at)) / 60.0, 2) AS detect_minutes,
       ce.change_event_id, ce.event_name
FROM aigov.findings f
JOIN aigov.ai_agents a ON a.id = f.agent_id
LEFT JOIN LATERAL (SELECT c.id AS change_event_id, c.event_name
                   FROM aigov.audit_events o
                   JOIN aigov.governance_runs g ON g.id = o.governance_run_id AND g.trigger_type = 'event'
                   JOIN aigov.change_events c ON c.id::text = g.trigger_ref
                   WHERE o.finding_id = f.id AND o.event_type = 'finding.opened'
                   ORDER BY o.id LIMIT 1) ce ON true
WHERE f.source_change_at IS NOT NULL AND f.first_detected_at >= f.source_change_at;

CREATE VIEW reporting.mttd_daily AS
SELECT date_trunc('day', first_detected_at) AS day, count(*) AS findings,
       round(avg(detect_minutes), 2) AS mttd_minutes, max(detect_minutes) AS max_detect_minutes
FROM reporting.findings_event_attributed
GROUP BY 1;

-- Time to remediate: findings closed by a verified remediation; the route OPA chose is recorded in the plan
CREATE VIEW reporting.findings_remediated AS
SELECT f.id AS finding_id, f.agent_id, a.name AS agent_name, f.policy_id, f.severity, f.first_detected_at, f.resolved_at,
       round(extract(epoch FROM (f.resolved_at - f.first_detected_at)) / 60.0, 2) AS remediate_minutes,
       r.id AS remediation_id, r.action_type,
       CASE WHEN r.planned_change #>> '{route,route}' = 'approval'
              OR EXISTS (SELECT FROM aigov.approvals ap WHERE ap.remediation_action_id = r.id AND ap.kind = 'remediation'
                           AND ap.decision = 'approved')
            THEN 'approval' ELSE 'automatic' END AS route
FROM aigov.findings f
JOIN aigov.ai_agents a ON a.id = f.agent_id
JOIN LATERAL (SELECT q.* FROM aigov.remediation_actions q WHERE q.finding_id = f.id AND q.status = 'verified'
              ORDER BY q.updated_at DESC LIMIT 1) r ON true
WHERE f.resolution = 'remediated' AND f.resolved_at IS NOT NULL;

CREATE VIEW reporting.mttr_daily AS
SELECT date_trunc('day', resolved_at) AS day, count(*) AS remediated,
       round(avg(remediate_minutes), 2) AS mttr_minutes,
       count(*) FILTER (WHERE route = 'automatic') AS automatic,
       count(*) FILTER (WHERE route = 'approval') AS after_approval,
       round(avg(remediate_minutes) FILTER (WHERE route = 'automatic'), 2) AS mttr_automatic_minutes,
       round(avg(remediate_minutes) FILTER (WHERE route = 'approval'), 2) AS mttr_approval_minutes
FROM reporting.findings_remediated
GROUP BY 1;

-- Operations
CREATE VIEW reporting.remediations AS
SELECT r.id AS remediation_id, r.status,
       CASE WHEN r.status IN ('planned', 'awaiting_approval', 'approved', 'executing', 'succeeded') THEN 'open'
            WHEN r.status = 'verified' THEN 'verified'
            WHEN r.status IN ('failed', 'verification_failed', 'rollback_failed') THEN 'failed'
            ELSE 'closed' END AS status_group,
       r.action_type, r.mode, r.planned_change #>> '{route,route}' AS route, r.attempt_number,
       r.created_at, r.updated_at, round(extract(epoch FROM (now() - r.created_at)) / 3600.0, 1) AS age_hours,
       f.id AS finding_id, f.policy_id, f.severity, a.id AS agent_id, a.name AS agent_name,
       (SELECT ap.decided_by FROM aigov.approvals ap WHERE ap.remediation_action_id = r.id AND ap.kind = 'remediation'
        ORDER BY ap.decided_at DESC NULLS LAST LIMIT 1) AS decided_by,
       r.ao_execution_id, r.aap_job_ids
FROM aigov.remediation_actions r
JOIN aigov.findings f ON f.id = r.finding_id
JOIN aigov.ai_agents a ON a.id = f.agent_id;

-- An approval row is written when the decision is recorded, so a waiting remediation is one still awaiting_approval
CREATE VIEW reporting.pending_approvals AS
SELECT remediation_id, agent_name, policy_id, severity, action_type, updated_at AS requested_at,
       round(extract(epoch FROM (now() - updated_at)) / 60.0, 1) AS waiting_minutes, ao_execution_id
FROM reporting.remediations WHERE status = 'awaiting_approval';

CREATE VIEW reporting.remediation_funnel AS
SELECT s.stage, s.stage_order,
       (SELECT count(*) FROM aigov.remediation_actions r WHERE r.status = ANY (s.statuses)) AS remediations
FROM (VALUES
  ('planned', 1, ARRAY['planned', 'awaiting_approval', 'approved', 'rejected', 'expired', 'executing', 'succeeded', 'failed',
                       'verified', 'verification_failed', 'rolled_back', 'rollback_failed', 'skipped']),
  ('approved or automatic', 2, ARRAY['approved', 'executing', 'succeeded', 'failed', 'verified', 'verification_failed',
                                     'rolled_back', 'rollback_failed']),
  ('executed', 3, ARRAY['succeeded', 'verified', 'verification_failed', 'rolled_back', 'rollback_failed']),
  ('verified', 4, ARRAY['verified'])) AS s (stage, stage_order, statuses);

CREATE VIEW reporting.change_events_daily AS
SELECT date_trunc('day', received_at) AS day, count(*) AS received,
       count(*) FILTER (WHERE status = 'mapped') AS mapped,
       count(*) FILTER (WHERE status = 'ignored') AS ignored,
       count(*) FILTER (WHERE status = 'suppressed') AS suppressed,
       count(*) FILTER (WHERE ao_execution_id IS NOT NULL) AS reassessments_started,
       round(avg(extract(epoch FROM (received_at - event_time))) FILTER (WHERE event_time IS NOT NULL), 1) AS avg_delivery_seconds
FROM aigov.change_events GROUP BY 1;

CREATE VIEW reporting.drift_events AS
SELECT e.id AS event_id, e.occurred_at, e.agent_id, a.name AS agent_name,
       e.event_type = 'agent.drift_attributed' AS attributed,
       (SELECT string_agg(p, ', ') FROM jsonb_array_elements_text(e.details -> 'changed_paths') p) AS changed_paths,
       jsonb_array_length(coalesce(e.details -> 'change_event_ids', '[]')) AS change_events
FROM aigov.audit_events e JOIN aigov.ai_agents a ON a.id = e.agent_id
WHERE e.event_type IN ('agent.drift_attributed', 'agent.drift_unattributed');

REVOKE ALL ON reporting.compliance_trend, reporting.findings_event_attributed, reporting.mttd_daily,
  reporting.findings_remediated, reporting.mttr_daily, reporting.remediations, reporting.pending_approvals,
  reporting.remediation_funnel, reporting.change_events_daily, reporting.drift_events FROM PUBLIC;
GRANT SELECT ON reporting.compliance_trend, reporting.findings_event_attributed, reporting.mttd_daily,
  reporting.findings_remediated, reporting.mttr_daily, reporting.remediations, reporting.pending_approvals,
  reporting.remediation_funnel, reporting.change_events_daily, reporting.drift_events TO grafana_ro, aigov_auditor;
REVOKE ALL ON FUNCTION api.capture_compliance_snapshot() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.capture_compliance_snapshot() TO aigov_remediator;
