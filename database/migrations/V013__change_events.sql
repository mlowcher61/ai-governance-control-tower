-- V013 (T3.02): AWS change events (docs/plan/05 sections 2.3 and 3).
--   aigov.change_events stores each event once (CloudTrail event ID; SQS may deliver a message more than once).
--   api.record_change_event maps it to inventory agents - a runtime or agent ID to that agent, an IAM role name to every
--   present agent running as that role - and records the status:
--     mapped      the event concerns governed agents (Process Change Event then starts a targeted re-assessment);
--     ignored     no agent is affected (reason not_agent_related), or the call failed (reason failed_call);
--     suppressed  the change was made by a governance role (loop prevention; EDA normally drops these first).
--   api.update_change_event records the automation orchestrator execution started for it.
-- Forward-only: add V014+ for changes.

CREATE TABLE aigov.change_events (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id        text NOT NULL UNIQUE,
  received_at     timestamptz NOT NULL DEFAULT now(),
  event_time      timestamptz,
  event_source    text NOT NULL,
  event_name      text NOT NULL,
  region          text,
  caller          text,
  target_type     text,
  target          text,
  status          text NOT NULL CHECK (status IN ('mapped', 'ignored', 'suppressed')),
  reason          text,
  agent_ids       uuid[] NOT NULL DEFAULT '{}',
  ao_execution_id text,
  raw             jsonb NOT NULL
);
CREATE INDEX change_events_received_idx ON aigov.change_events (received_at DESC);
REVOKE ALL ON aigov.change_events FROM PUBLIC;

CREATE FUNCTION api.record_change_event(event jsonb, suppress_callers text[] DEFAULT '{}')
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  d jsonb := coalesce(event -> 'detail', '{}');
  params jsonb := coalesce(d -> 'requestParameters', '{}');
  eid text := d ->> 'eventID';
  caller text := d -> 'userIdentity' ->> 'arn';
  ttype text;
  tgt text;
  agents uuid[] := '{}';
  st text;
  why text;
  existing aigov.change_events;
  cid uuid;
  p text;
BEGIN
  IF coalesce(eid, '') = '' OR coalesce(d ->> 'eventName', '') = '' OR coalesce(d ->> 'eventSource', '') = '' THEN
    PERFORM aigov.api_error('event.detail needs eventID, eventName and eventSource (an EventBridge CloudTrail event)');
  END IF;
  SELECT * INTO existing FROM aigov.change_events c WHERE c.event_id = eid;
  IF FOUND THEN
    RETURN json_build_object('change_event_id', existing.id, 'status', existing.status, 'reason', existing.reason,
                             'agent_ids', existing.agent_ids, 'duplicate', true);
  END IF;

  -- The target: role, agent runtime (by ID or by ARN in tagging calls) or Classic agent
  IF params ? 'roleName' THEN
    ttype := 'role'; tgt := params ->> 'roleName';
  ELSIF params ? 'agentRuntimeId' THEN
    ttype := 'agent_runtime'; tgt := params ->> 'agentRuntimeId';
  ELSIF params ->> 'resourceArn' ~ ':runtime/[^/]+$' THEN
    ttype := 'agent_runtime'; tgt := substring(params ->> 'resourceArn' from ':runtime/([^/]+)$');
  ELSIF params ? 'agentId' THEN
    ttype := 'agent'; tgt := params ->> 'agentId';
  ELSIF params ? 'policyArn' THEN
    ttype := 'policy'; tgt := params ->> 'policyArn';
  END IF;

  IF d ? 'errorCode' THEN
    st := 'ignored'; why := 'failed_call';
  ELSE
    FOREACH p IN ARRAY coalesce(suppress_callers, '{}') LOOP
      IF caller ILIKE '%' || p || '%' THEN st := 'suppressed'; why := 'governance_role:' || p; END IF;
    END LOOP;
  END IF;

  IF st IS NULL THEN
    IF ttype = 'role' THEN
      SELECT coalesce(array_agg(a.id ORDER BY a.name), '{}') INTO agents
      FROM aigov.ai_agents a JOIN aigov.agent_identities i ON i.id = a.identity_id
      WHERE a.missing_since IS NULL AND (i.principal_ref LIKE '%:role/' || tgt OR i.principal_ref LIKE '%/' || tgt);
    ELSIF ttype IN ('agent_runtime', 'agent') THEN
      SELECT coalesce(array_agg(a.id ORDER BY a.name), '{}') INTO agents
      FROM aigov.ai_agents a WHERE a.missing_since IS NULL AND a.external_id = tgt;
    END IF;
    st := CASE WHEN cardinality(agents) > 0 THEN 'mapped' ELSE 'ignored' END;
    why := CASE WHEN st = 'ignored' THEN 'not_agent_related' END;
  END IF;

  INSERT INTO aigov.change_events (event_id, event_time, event_source, event_name, region, caller, target_type, target,
                                   status, reason, agent_ids, raw)
  VALUES (eid, (d ->> 'eventTime')::timestamptz, d ->> 'eventSource', d ->> 'eventName', d ->> 'awsRegion', caller, ttype,
          tgt, st, why, agents, event)
  RETURNING id INTO cid;
  PERFORM aigov.audit(CASE st WHEN 'mapped' THEN 'event.received' ELSE 'event.' || st END, 'service', aigov.api_actor(),
                      'aws', NULL, CASE WHEN cardinality(agents) = 1 THEN agents[1] END, NULL, eid,
                      jsonb_build_object('change_event_id', cid, 'event_name', d ->> 'eventName',
                                         'event_source', d ->> 'eventSource', 'caller', caller, 'target_type', ttype,
                                         'target', tgt, 'status', st, 'reason', why, 'agent_ids', to_jsonb(agents)));
  RETURN json_build_object('change_event_id', cid, 'status', st, 'reason', why, 'agent_ids', agents, 'duplicate', false,
                           'target_type', ttype, 'target', tgt);
END
$$;

CREATE FUNCTION api.update_change_event(change_event_id uuid, ao_execution_id text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  UPDATE aigov.change_events c SET ao_execution_id = update_change_event.ao_execution_id
  WHERE c.id = update_change_event.change_event_id;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown change_event_id'); END IF;
  RETURN json_build_object('ok', true);
END
$$;

-- Reporting (Grafana, reader): the recent events and what happened to them
CREATE VIEW api.change_events AS
SELECT c.id AS change_event_id, c.received_at, c.event_time, c.event_source, c.event_name, c.region, c.caller,
       c.target_type, c.target, c.status, c.reason, c.agent_ids, c.ao_execution_id
FROM aigov.change_events c;

REVOKE ALL ON FUNCTION api.record_change_event(jsonb, text[]), api.update_change_event(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_change_event(jsonb, text[]), api.update_change_event(uuid, text) TO aigov_discovery;
REVOKE ALL ON api.change_events FROM PUBLIC;
GRANT SELECT ON api.change_events TO aigov_reader, aigov_discovery, aigov_auditor;
