-- V017 (T3.06): what the Stage 3 dashboards need beyond V005 and V016 (docs/plan/05 sections 6.1-6.4).
--   * Event pipeline health: api.record_dead_letters(n) stores the dead-letter queue depth Reconcile and Sweep counts
--     each hour (aigov.sweep_state), so Grafana can show it.
--   * reporting.audit_chain_status - the last chain check, events written since, the last sweep and dead letters (one row).
--   * reporting.audit_chain_checks - every chain check (checkpoint) for the Audit Explorer.
--   * reporting.audit_timeline - every audit event with agent, finding and a short subject, for any governance run.
--   * reporting.bundle_revisions - the policy bundle revisions evaluations used, and which are in use now.
--   * reporting.compliance_history - one row per day: the compliance snapshot where one exists (V016), otherwise the
--     day derived from assessments (V005 compliance_daily), so the trend also covers the days before snapshots.
--   * reporting.agent_resources - tools and data sources per agent, with approval for high-risk tools (AIGOV-TOOL-001).
--   * Fix to V016: reporting.findings_event_attributed (and so reporting.mttd_daily) counted every finding, because V002
--     gives each new finding source_change_at = the agent's last update time. Only findings opened by an event-triggered
--     targeted re-assessment are event-attributed; the detection time is measured from that change event's CloudTrail time.
-- Readers: grafana_ro and aigov_auditor. Forward-only: add V018+ for changes.

ALTER TABLE aigov.sweep_state ADD COLUMN dead_letters int, ADD COLUMN dead_letters_checked_at timestamptz;

CREATE FUNCTION api.record_dead_letters(dead_letters int)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF dead_letters IS NULL OR dead_letters < 0 THEN PERFORM aigov.api_error('dead_letters must be a count (0 or more)'); END IF;
  UPDATE aigov.sweep_state s SET dead_letters = record_dead_letters.dead_letters, dead_letters_checked_at = now() WHERE s.id = 1;
  RETURN json_build_object('dead_letters', dead_letters, 'checked_at', now());
END
$$;

CREATE VIEW reporting.audit_chain_status AS
SELECT c.status AS chain_status, c.checked_at AS last_checked_at, c.verified_from_id, c.verified_to_id, c.broken_id, c.reason,
       (SELECT max(e.id) FROM aigov.audit_events e) AS latest_event_id,
       (SELECT count(*) FROM aigov.audit_events e WHERE e.id > coalesce(c.verified_to_id, 0)) AS events_since_check,
       (SELECT max(e.occurred_at) FROM aigov.audit_events e WHERE e.event_type = 'reconcile.sweep_completed') AS last_sweep_at,
       s.dead_letters, s.dead_letters_checked_at
FROM aigov.sweep_state s
LEFT JOIN LATERAL (SELECT * FROM aigov.audit_checkpoints k ORDER BY k.id DESC LIMIT 1) c ON true;

CREATE VIEW reporting.audit_chain_checks AS
SELECT k.id AS check_id, k.checked_at, k.status, k.verified_from_id, k.verified_to_id,
       (SELECT count(*) FROM aigov.audit_events e WHERE e.id > k.verified_from_id AND e.id <= k.verified_to_id) AS events_checked,
       k.broken_id, k.reason
FROM aigov.audit_checkpoints k;

CREATE VIEW reporting.audit_timeline AS
SELECT e.id AS event_id, e.occurred_at, e.governance_run_id, e.event_type, e.actor_type, e.actor_id, e.source_system, e.source_ref,
       e.agent_id, a.name AS agent_name, e.finding_id, f.policy_id, e.remediation_action_id,
       coalesce(e.details ->> 'policy_id', f.policy_id, e.details ->> 'outcome', e.details ->> 'decision',
                e.details ->> 'overall_status', e.details ->> 'run_type', e.details ->> 'status', '') AS subject,
       left(e.details::text, 500) AS details
FROM aigov.audit_events e
LEFT JOIN aigov.ai_agents a ON a.id = e.agent_id
LEFT JOIN aigov.findings f ON f.id = e.finding_id;

CREATE VIEW reporting.bundle_revisions AS
SELECT e.bundle_revision, min(e.evaluated_at) AS first_used_at, max(e.evaluated_at) AS last_used_at, count(*) AS evaluations,
       count(DISTINCT e.agent_id) AS agents,
       EXISTS (SELECT FROM reporting.latest_evaluation l WHERE l.bundle_revision = e.bundle_revision) AS in_use,
       e.bundle_revision ~ '^[0-9a-f]{7,40}$' AS is_commit
FROM aigov.policy_evaluations e
GROUP BY e.bundle_revision;

CREATE VIEW reporting.compliance_history AS
SELECT s.day, s.agents, s.compliant, s.noncompliant, s.unknown,
       CASE WHEN s.agents > 0 THEN round(100.0 * s.compliant / s.agents, 1) END AS compliant_pct,
       s.open_critical + s.open_high AS open_critical_high, 'snapshot'::text AS source
FROM aigov.compliance_snapshots s
UNION ALL
SELECT d.day::date, d.agents::int, d.compliant::int, d.noncompliant::int, d.unknown::int, d.compliant_pct, NULL::int, 'assessments'::text
FROM reporting.compliance_daily d
WHERE NOT EXISTS (SELECT FROM aigov.compliance_snapshots s WHERE s.day = d.day::date);

CREATE VIEW reporting.agent_resources AS
SELECT t.agent_id, 'tool'::text AS kind, t.tool_type AS type, coalesce(t.name, t.external_id) AS name, t.state,
       NULL::text AS classification, t.parent_signature,
       CASE WHEN t.parent_signature IS NULL THEN NULL ELSE t.parent_signature = ANY (coalesce(g.approved_tools, '{}')) END AS approved,
       t.last_seen_at
FROM aigov.agent_tools t
JOIN aigov.ai_agents a ON a.id = t.agent_id
LEFT JOIN aigov.agent_registrations g ON g.registration_id = a.registration_id
UNION ALL
SELECT d.agent_id, 'data source', d.source_type, coalesce(d.name, d.external_id), d.state, d.classification, NULL, NULL, d.last_seen_at
FROM aigov.agent_data_sources d;

REVOKE ALL ON reporting.audit_chain_status, reporting.audit_chain_checks, reporting.audit_timeline, reporting.bundle_revisions,
  reporting.compliance_history, reporting.agent_resources FROM PUBLIC;
GRANT SELECT ON reporting.audit_chain_status, reporting.audit_chain_checks, reporting.audit_timeline, reporting.bundle_revisions,
  reporting.compliance_history, reporting.agent_resources TO grafana_ro, aigov_auditor;
REVOKE ALL ON FUNCTION api.record_dead_letters(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_dead_letters(int) TO aigov_remediator;

-- Same columns as V016 (CREATE OR REPLACE keeps reporting.mttd_daily and the grants); driven from the event-triggered runs
CREATE OR REPLACE VIEW reporting.findings_event_attributed AS
SELECT DISTINCT ON (f.id)
       f.id AS finding_id, f.agent_id, a.name AS agent_name, f.policy_id, f.severity, c.event_time AS source_change_at,
       f.first_detected_at, round(extract(epoch FROM (f.first_detected_at - c.event_time)) / 60.0, 2) AS detect_minutes,
       c.id AS change_event_id, c.event_name
FROM aigov.governance_runs g
JOIN aigov.change_events c ON c.id::text = g.trigger_ref
JOIN aigov.audit_events o ON o.governance_run_id = g.id AND o.event_type = 'finding.opened'
JOIN aigov.findings f ON f.id = o.finding_id
JOIN aigov.ai_agents a ON a.id = f.agent_id
WHERE g.run_type = 'targeted_reassessment' AND g.trigger_type = 'event'
  AND c.event_time IS NOT NULL AND f.first_detected_at >= c.event_time
ORDER BY f.id, o.id;
