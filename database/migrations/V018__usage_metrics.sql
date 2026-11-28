-- V018 (T3.07): AI usage and estimated cost (docs/plan/05 sections 4 and 9).
--   * aigov.usage_metrics: one row per UTC day, metric and AI agent (or foundation model) - CloudWatch usage (AgentCore,
--     Bedrock Agents, Bedrock models) and the estimated cost (usage x the customer's unit prices). source cost_explorer
--     (actual cost) is reserved; this deployment uses estimates only (decision 2026-11-28).
--   * api.record_usage(account_ref, rows): upserts the rows of Collect Usage and Cost (re-collecting a day replaces it)
--     and links agent rows to the inventory by runtime/agent ARN; audited as usage.collected.
--   * reporting.usage_daily (long), reporting.usage_agent_daily and reporting.usage_summary_daily (one row per agent or
--     per day with invocations, sessions, errors, tokens, vCPU-hours, GB-hours and the estimated cost).
-- Readers: grafana_ro and aigov_auditor. Forward-only: add V019+ for changes.

CREATE TABLE aigov.usage_metrics (
  id            bigserial PRIMARY KEY,
  day           date NOT NULL,
  account_id    uuid NOT NULL REFERENCES aigov.cloud_accounts (id),
  scope         text NOT NULL CHECK (scope IN ('agent', 'model')),
  scope_ref     text NOT NULL,
  agent_id      uuid REFERENCES aigov.ai_agents (id),
  source        text NOT NULL CHECK (source IN ('cloudwatch', 'estimate', 'cost_explorer')),
  namespace     text NOT NULL DEFAULT '',
  metric        text NOT NULL,
  measure       text NOT NULL,
  statistic     text NOT NULL,
  value         numeric NOT NULL,
  unit          text NOT NULL DEFAULT '',
  collected_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (day, account_id, scope_ref, source, namespace, metric, statistic)
);
CREATE INDEX usage_metrics_agent_day_idx ON aigov.usage_metrics (agent_id, day);
CREATE INDEX usage_metrics_day_idx ON aigov.usage_metrics (day);
REVOKE ALL ON aigov.usage_metrics FROM PUBLIC;

CREATE FUNCTION api.record_usage(account_ref text, rows jsonb)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  acct uuid;
  n int := 0;
  matched int;
  unmatched jsonb;
  days jsonb;
BEGIN
  SELECT c.id INTO acct FROM aigov.cloud_accounts c WHERE c.account_ref = record_usage.account_ref;
  IF acct IS NULL THEN PERFORM aigov.api_error('unknown account_ref'); END IF;
  IF jsonb_typeof(rows) IS DISTINCT FROM 'array' THEN PERFORM aigov.api_error('rows must be an array'); END IF;
  IF EXISTS (SELECT FROM jsonb_array_elements(rows) r
             WHERE NOT (r ? 'day' AND r ? 'scope' AND r ? 'scope_ref' AND r ? 'source' AND r ? 'metric' AND r ? 'value')
                OR jsonb_typeof(r -> 'value') <> 'number') THEN
    PERFORM aigov.api_error('each row needs day, scope, scope_ref, source, metric and a numeric value');
  END IF;

  INSERT INTO aigov.usage_metrics AS u (day, account_id, scope, scope_ref, agent_id, source, namespace, metric, measure,
                                        statistic, value, unit)
  SELECT (r ->> 'day')::date, acct, r ->> 'scope', r ->> 'scope_ref',
         CASE WHEN r ->> 'scope' = 'agent' THEN
           (SELECT a.id FROM aigov.ai_agents a
            WHERE a.account_id = acct
              AND (a.resource_ref = r ->> 'scope_ref' OR position(a.external_id IN r ->> 'scope_ref') > 0)
            ORDER BY (a.resource_ref = r ->> 'scope_ref') DESC, a.missing_since NULLS FIRST LIMIT 1) END,
         r ->> 'source', coalesce(r ->> 'namespace', ''), r ->> 'metric', coalesce(nullif(r ->> 'measure', ''), r ->> 'metric'),
         coalesce(nullif(r ->> 'statistic', ''), 'Sum'), (r ->> 'value')::numeric, coalesce(r ->> 'unit', '')
  FROM jsonb_array_elements(rows) r
  ON CONFLICT (day, account_id, scope_ref, source, namespace, metric, statistic)
  DO UPDATE SET value = EXCLUDED.value, unit = EXCLUDED.unit, measure = EXCLUDED.measure,
                agent_id = coalesce(EXCLUDED.agent_id, u.agent_id), collected_at = now();
  GET DIAGNOSTICS n = ROW_COUNT;

  SELECT count(DISTINCT u.agent_id), coalesce(jsonb_agg(DISTINCT u.scope_ref) FILTER (WHERE u.agent_id IS NULL), '[]')
  INTO matched, unmatched
  FROM aigov.usage_metrics u
  WHERE u.account_id = acct AND u.scope = 'agent'
    AND (u.day, u.scope_ref) IN (SELECT (r ->> 'day')::date, r ->> 'scope_ref' FROM jsonb_array_elements(rows) r);
  SELECT coalesce(jsonb_agg(DISTINCT r ->> 'day'), '[]') INTO days FROM jsonb_array_elements(rows) r;

  PERFORM aigov.audit('usage.collected', 'service', aigov.api_actor(), 'aws',
                      details => jsonb_build_object('account_ref', account_ref, 'rows', n, 'days', days,
                                                    'agents_matched', matched, 'unmatched_refs', unmatched));
  RETURN json_build_object('recorded', n, 'agents_matched', matched, 'unmatched_refs', unmatched);
END
$$;

CREATE VIEW reporting.usage_daily AS
SELECT u.day, u.agent_id, coalesce(a.name, u.scope_ref) AS subject, u.scope, u.scope_ref, u.source,
       CASE u.source WHEN 'estimate' THEN 'estimate' WHEN 'cost_explorer' THEN 'actual' END AS cost_kind,
       u.namespace, u.metric, u.measure, u.statistic, u.value, u.unit, u.collected_at
FROM aigov.usage_metrics u
LEFT JOIN aigov.ai_agents a ON a.id = u.agent_id;

CREATE VIEW reporting.usage_agent_daily AS
SELECT u.day, u.agent_id, a.name AS agent_name,
       sum(u.value) FILTER (WHERE u.measure = 'invocations') AS invocations,
       sum(u.value) FILTER (WHERE u.measure = 'sessions') AS sessions,
       sum(u.value) FILTER (WHERE u.measure = 'errors') AS errors,
       sum(u.value) FILTER (WHERE u.measure = 'input_tokens') AS input_tokens,
       sum(u.value) FILTER (WHERE u.measure = 'output_tokens') AS output_tokens,
       round(avg(u.value) FILTER (WHERE u.measure = 'latency_ms'), 1) AS latency_ms,
       sum(u.value) FILTER (WHERE u.measure = 'vcpu_hours') AS vcpu_hours,
       sum(u.value) FILTER (WHERE u.measure = 'memory_gb_hours') AS memory_gb_hours,
       sum(u.value) FILTER (WHERE u.source = 'estimate') AS estimated_cost,
       sum(u.value) FILTER (WHERE u.source = 'cost_explorer') AS actual_cost,
       max(u.unit) FILTER (WHERE u.source IN ('estimate', 'cost_explorer')) AS currency
FROM aigov.usage_metrics u
JOIN aigov.ai_agents a ON a.id = u.agent_id
GROUP BY u.day, u.agent_id, a.name;

CREATE VIEW reporting.usage_summary_daily AS
SELECT u.day,
       sum(u.value) FILTER (WHERE u.measure = 'invocations' AND u.scope = 'agent') AS agent_invocations,
       sum(u.value) FILTER (WHERE u.measure = 'sessions' AND u.scope = 'agent') AS agent_sessions,
       sum(u.value) FILTER (WHERE u.measure = 'errors' AND u.scope = 'agent') AS agent_errors,
       sum(u.value) FILTER (WHERE u.measure = 'invocations' AND u.scope = 'model') AS model_invocations,
       sum(u.value) FILTER (WHERE u.measure = 'input_tokens' AND u.scope = 'model') AS input_tokens,
       sum(u.value) FILTER (WHERE u.measure = 'output_tokens' AND u.scope = 'model') AS output_tokens,
       sum(u.value) FILTER (WHERE u.measure = 'vcpu_hours') AS vcpu_hours,
       sum(u.value) FILTER (WHERE u.measure = 'memory_gb_hours') AS memory_gb_hours,
       sum(u.value) FILTER (WHERE u.source = 'estimate') AS estimated_cost,
       sum(u.value) FILTER (WHERE u.source = 'cost_explorer') AS actual_cost,
       count(DISTINCT u.agent_id) FILTER (WHERE u.measure = 'invocations' AND u.value > 0) AS active_agents,
       max(u.unit) FILTER (WHERE u.source IN ('estimate', 'cost_explorer')) AS currency
FROM aigov.usage_metrics u
GROUP BY u.day;

REVOKE ALL ON reporting.usage_daily, reporting.usage_agent_daily, reporting.usage_summary_daily FROM PUBLIC;
GRANT SELECT ON reporting.usage_daily, reporting.usage_agent_daily, reporting.usage_summary_daily TO grafana_ro, aigov_auditor;
REVOKE ALL ON FUNCTION api.record_usage(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_usage(text, jsonb) TO aigov_discovery;
