-- SQL assertions for V018: usage rows are upserted per day, linked to the inventory by runtime ARN, summed per agent
-- and per day with the estimated cost, and only the discovery role may record them.
\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  IF NOT has_function_privilege('aigov_discovery', 'api.record_usage(text,jsonb)', 'EXECUTE')
     OR has_function_privilege('aigov_reader', 'api.record_usage(text,jsonb)', 'EXECUTE')
     OR has_function_privilege('grafana_ro', 'api.record_usage(text,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'record_usage grants are wrong';
  END IF;
  IF has_table_privilege('grafana_ro', 'aigov.usage_metrics', 'SELECT')
     OR NOT has_table_privilege('grafana_ro', 'reporting.usage_summary_daily', 'SELECT') THEN
    RAISE EXCEPTION 'usage table/view grants are wrong';
  END IF;
END $$;

INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000f801', 'aws', '818181818181');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash) VALUES
  ('00000000-0000-0000-0000-00000000f811', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000f801', 'us-west-1',
   'use_one-AbC123', 'arn:aws:bedrock-agentcore:us-west-1:818181818181:runtime/use_one-AbC123', 'use-one', 'h'),
  ('00000000-0000-0000-0000-00000000f812', 'aws', 'aws.bedrock_agent', '00000000-0000-0000-0000-00000000f801', 'us-west-1',
   'AGENT12345', 'arn:aws:bedrock:us-west-1:818181818181:agent/AGENT12345', 'use-two', 'h');

DO $$
DECLARE r json; s record; rt text := 'arn:aws:bedrock-agentcore:us-west-1:818181818181:runtime/use_one-AbC123';
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_discovery';
  PERFORM set_config('request.jwt.claims', '{"role": "aigov_discovery", "sub": "usage-test"}', true);
  r := api.record_usage('818181818181', jsonb_build_array(
    jsonb_build_object('day', '2001-05-01', 'scope', 'agent', 'scope_ref', rt, 'source', 'cloudwatch', 'namespace', 'AWS/Bedrock-AgentCore',
                       'metric', 'Invocations', 'measure', 'invocations', 'statistic', 'Sum', 'value', 5),
    jsonb_build_object('day', '2001-05-01', 'scope', 'agent', 'scope_ref', rt, 'source', 'cloudwatch', 'namespace', 'AWS/Bedrock-AgentCore',
                       'metric', 'CPUUsed-vCPUHours', 'measure', 'vcpu_hours', 'statistic', 'Sum', 'value', 0.25),
    jsonb_build_object('day', '2001-05-01', 'scope', 'agent', 'scope_ref', rt, 'source', 'estimate', 'metric', 'estimated_cost',
                       'measure', 'estimated_cost', 'statistic', 'Sum', 'value', 0.04, 'unit', 'USD'),
    -- a Bedrock agent alias metric links to the agent by its ID inside the alias ARN
    jsonb_build_object('day', '2001-05-01', 'scope', 'agent', 'scope_ref', 'arn:aws:bedrock:us-west-1:818181818181:agent-alias/AGENT12345/ALIAS1',
                       'source', 'cloudwatch', 'namespace', 'AWS/Bedrock/Agents', 'metric', 'InvocationCount', 'measure', 'invocations',
                       'statistic', 'Sum', 'value', 2),
    -- an agent the inventory does not know, and model tokens with their estimate
    jsonb_build_object('day', '2001-05-01', 'scope', 'agent', 'scope_ref', 'arn:aws:bedrock-agentcore:us-west-1:818181818181:runtime/shadow-ZZ',
                       'source', 'cloudwatch', 'namespace', 'AWS/Bedrock-AgentCore', 'metric', 'Invocations', 'measure', 'invocations',
                       'statistic', 'Sum', 'value', 7),
    jsonb_build_object('day', '2001-05-01', 'scope', 'model', 'scope_ref', 'amazon.nova-lite-v1:0', 'source', 'cloudwatch',
                       'namespace', 'AWS/Bedrock', 'metric', 'InputTokenCount', 'measure', 'input_tokens', 'statistic', 'Sum', 'value', 1000),
    jsonb_build_object('day', '2001-05-01', 'scope', 'model', 'scope_ref', 'amazon.nova-lite-v1:0', 'source', 'estimate',
                       'metric', 'estimated_cost', 'measure', 'estimated_cost', 'statistic', 'Sum', 'value', 0.5, 'unit', 'USD')));
  IF (r ->> 'recorded')::int <> 7 OR (r ->> 'agents_matched')::int <> 2
     OR r -> 'unmatched_refs' ->> 0 <> 'arn:aws:bedrock-agentcore:us-west-1:818181818181:runtime/shadow-ZZ' THEN
    RAISE EXCEPTION 'record_usage result wrong: %', r;
  END IF;
  -- Re-collecting the day replaces the value (no duplicate)
  r := api.record_usage('818181818181', jsonb_build_array(
    jsonb_build_object('day', '2001-05-01', 'scope', 'agent', 'scope_ref', rt, 'source', 'cloudwatch', 'namespace', 'AWS/Bedrock-AgentCore',
                       'metric', 'Invocations', 'measure', 'invocations', 'statistic', 'Sum', 'value', 6)));
  BEGIN
    PERFORM api.record_usage('999999999999', '[]');
    RAISE EXCEPTION 'unknown account accepted';
  EXCEPTION WHEN raise_exception THEN RAISE; WHEN OTHERS THEN NULL;
  END;
  BEGIN
    PERFORM api.record_usage('818181818181', '[{"day": "2001-05-02", "scope": "agent", "scope_ref": "x", "source": "cloudwatch", "metric": "m", "value": "5"}]');
    RAISE EXCEPTION 'non-numeric value accepted';
  EXCEPTION WHEN raise_exception THEN RAISE; WHEN OTHERS THEN NULL;
  END;
  RESET ROLE;

  IF (SELECT count(*) FROM aigov.usage_metrics WHERE scope_ref = rt AND metric = 'Invocations') <> 1 THEN
    RAISE EXCEPTION 'upsert duplicated the row';
  END IF;
  SELECT * INTO s FROM reporting.usage_agent_daily WHERE agent_id = '00000000-0000-0000-0000-00000000f811' AND day = '2001-05-01';
  IF s.invocations <> 6 OR s.vcpu_hours <> 0.25 OR s.estimated_cost <> 0.04 OR s.currency <> 'USD' OR s.agent_name <> 'use-one' THEN
    RAISE EXCEPTION 'usage_agent_daily wrong: %', s;
  END IF;
  IF (SELECT invocations FROM reporting.usage_agent_daily WHERE agent_id = '00000000-0000-0000-0000-00000000f812') <> 2 THEN
    RAISE EXCEPTION 'alias ARN not linked to the Bedrock agent';
  END IF;
  SELECT * INTO s FROM reporting.usage_summary_daily WHERE day = '2001-05-01';
  IF s.agent_invocations <> 15 OR s.input_tokens <> 1000 OR s.estimated_cost <> 0.54 OR s.active_agents <> 2 THEN
    RAISE EXCEPTION 'usage_summary_daily wrong: %', s;
  END IF;
  IF (SELECT count(*) FROM reporting.usage_daily WHERE day = '2001-05-01' AND cost_kind = 'estimate') <> 2
     OR (SELECT subject FROM reporting.usage_daily WHERE scope = 'model' LIMIT 1) <> 'amazon.nova-lite-v1:0' THEN
    RAISE EXCEPTION 'usage_daily wrong';
  END IF;
  IF NOT EXISTS (SELECT FROM aigov.audit_events WHERE event_type = 'usage.collected' AND details ->> 'account_ref' = '818181818181') THEN
    RAISE EXCEPTION 'usage.collected not audited';
  END IF;
END $$;
ROLLBACK;
\echo 'test_v018_usage_metrics: all assertions passed'
