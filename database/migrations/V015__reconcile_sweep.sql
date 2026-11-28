-- V015 (T3.04): scheduled reconciliation (docs/plan/05 section 2.6). Events are the source of speed; reconciliation is
-- the source of completeness. api.reconcile_sweep (hourly, AI Governance - Reconcile and Sweep):
--   1. verifies the audit hash chain incrementally from the last checkpoint (audit.chain_broken when a row was altered);
--   2. expires remediations nobody acted on: awaiting_approval -> expired (as a rejection), planned or approved ->
--      skipped, executing -> failed (stuck), each older than stale_minutes;
--   3. confirms agents missing for more than missing_hours (agent.missing_confirmed, once per absence);
--   4. explains configuration drift since the last sweep: the changed paths between an agent's snapshot and the
--      previous one, attributed to a change event when one explains it, otherwise unattributed (a gap in event
--      coverage).
-- Forward-only: add V016+ for changes.

CREATE TABLE aigov.audit_checkpoints (
  id               bigserial PRIMARY KEY,
  checked_at       timestamptz NOT NULL DEFAULT now(),
  verified_from_id bigint NOT NULL,
  verified_to_id   bigint NOT NULL,
  status           text NOT NULL CHECK (status IN ('intact', 'broken')),
  broken_id        bigint,
  reason           text
);
CREATE TABLE aigov.sweep_state (
  id              int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  last_drift_check timestamptz NOT NULL DEFAULT '1970-01-01'
);
INSERT INTO aigov.sweep_state DEFAULT VALUES;
REVOKE ALL ON aigov.audit_checkpoints, aigov.sweep_state FROM PUBLIC;

-- Paths whose values differ between two JSON documents (objects are compared key by key; arrays and scalars whole)
CREATE FUNCTION aigov.jsonb_diff_paths(a jsonb, b jsonb, prefix text DEFAULT '') RETURNS SETOF text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE k text;
BEGIN
  IF jsonb_typeof(a) = 'object' AND jsonb_typeof(b) = 'object' THEN
    FOR k IN SELECT key FROM (SELECT jsonb_object_keys(a) AS key UNION SELECT jsonb_object_keys(b)) keys ORDER BY 1 LOOP
      RETURN QUERY SELECT * FROM aigov.jsonb_diff_paths(a -> k, b -> k, CASE WHEN prefix = '' THEN k ELSE prefix || '.' || k END);
    END LOOP;
  ELSIF a IS DISTINCT FROM b THEN
    RETURN NEXT prefix;
  END IF;
END
$$;

CREATE FUNCTION api.reconcile_sweep(stale_minutes int DEFAULT 120, missing_hours int DEFAULT 24)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  last_cp aigov.audit_checkpoints;
  from_id bigint;
  to_id bigint;
  broken record;
  chain jsonb;
  ra aigov.remediation_actions;
  expired jsonb := '[]';
  skipped jsonb := '[]';
  failed jsonb := '[]';
  missing jsonb := '[]';
  drift jsonb := '[]';
  agt record;
  snap record;
  since timestamptz;
  paths text[];
  ces uuid[];
BEGIN
  -- 1. Audit chain, incrementally (first, so the events this sweep writes are verified by the next one)
  SELECT * INTO last_cp FROM aigov.audit_checkpoints WHERE status = 'intact' ORDER BY id DESC LIMIT 1;
  from_id := coalesce(last_cp.verified_to_id + 1, 0);
  SELECT coalesce(max(id), 0) INTO to_id FROM aigov.audit_events;
  SELECT * INTO broken FROM aigov.verify_audit_chain(from_id) LIMIT 1;
  INSERT INTO aigov.audit_checkpoints (verified_from_id, verified_to_id, status, broken_id, reason)
  VALUES (from_id, to_id, CASE WHEN broken.broken_id IS NULL THEN 'intact' ELSE 'broken' END, broken.broken_id, broken.reason);
  chain := jsonb_build_object('status', CASE WHEN broken.broken_id IS NULL THEN 'intact' ELSE 'broken' END,
                              'verified_from_id', from_id, 'verified_to_id', to_id,
                              'broken_id', broken.broken_id, 'reason', broken.reason);
  IF broken.broken_id IS NOT NULL THEN
    PERFORM aigov.audit('audit.chain_broken', 'service', aigov.api_actor(), 'db',
                        details => chain);
  END IF;

  -- 2. Remediations nobody acted on
  FOR ra IN SELECT * FROM aigov.remediation_actions r
            WHERE r.status IN ('awaiting_approval', 'planned', 'approved', 'executing')
              AND r.updated_at < now() - make_interval(mins => stale_minutes) ORDER BY r.updated_at LOOP
    IF ra.status = 'awaiting_approval' THEN
      PERFORM api.record_approval(ra.id, 'expired', NULL, format('no decision within %s minutes (Reconcile and Sweep)', stale_minutes));
      expired := expired || to_jsonb(ra.id);
    ELSIF ra.status IN ('planned', 'approved') THEN
      PERFORM api.update_remediation(ra.id, 'skipped', NULL,
                                     jsonb_build_object('phase', 'sweep', 'message', format('%s for more than %s minutes', ra.status, stale_minutes)));
      skipped := skipped || to_jsonb(ra.id);
    ELSE
      PERFORM api.update_remediation(ra.id, 'failed', NULL,
                                     jsonb_build_object('phase', 'sweep', 'message', format('executing for more than %s minutes', stale_minutes)));
      failed := failed || to_jsonb(ra.id);
    END IF;
  END LOOP;

  -- 3. Agents missing for a long time (confirmed once per absence)
  FOR agt IN SELECT a.id, a.name, a.missing_since FROM aigov.ai_agents a
             WHERE a.missing_since < now() - make_interval(hours => missing_hours)
               AND NOT EXISTS (SELECT FROM aigov.audit_events e WHERE e.agent_id = a.id AND e.event_type = 'agent.missing_confirmed'
                                 AND e.occurred_at >= a.missing_since) LOOP
    PERFORM aigov.audit('agent.missing_confirmed', 'service', aigov.api_actor(), 'db', NULL, agt.id,
                        details => jsonb_build_object('name', agt.name, 'missing_since', agt.missing_since, 'after_hours', missing_hours));
    missing := missing || jsonb_build_object('agent_id', agt.id, 'name', agt.name, 'missing_since', agt.missing_since);
  END LOOP;

  -- 4. Configuration drift since the last sweep
  SELECT last_drift_check INTO since FROM aigov.sweep_state WHERE id = 1 FOR UPDATE;
  FOR snap IN
    SELECT s.id, s.agent_id, s.record, s.observed_at, a.name,
           (SELECT p.record FROM aigov.agent_snapshots p WHERE p.agent_id = s.agent_id AND p.observed_at < s.observed_at
            ORDER BY p.observed_at DESC LIMIT 1) AS prev_record,
           (SELECT p.observed_at FROM aigov.agent_snapshots p WHERE p.agent_id = s.agent_id AND p.observed_at < s.observed_at
            ORDER BY p.observed_at DESC LIMIT 1) AS prev_at
    FROM aigov.agent_snapshots s JOIN aigov.ai_agents a ON a.id = s.agent_id
    WHERE s.observed_at > since ORDER BY s.observed_at LOOP
    CONTINUE WHEN snap.prev_record IS NULL;   -- a new agent, not drift
    SELECT coalesce(array_agg(pth), '{}') INTO paths
    FROM aigov.jsonb_diff_paths(snap.prev_record - 'content_hash' - 'collected_at' - 'observed_at',
                                snap.record - 'content_hash' - 'collected_at' - 'observed_at') pth
    WHERE pth NOT LIKE 'identity.collected_at%';
    CONTINUE WHEN cardinality(paths) = 0;
    SELECT coalesce(array_agg(c.id ORDER BY c.received_at), '{}') INTO ces FROM aigov.change_events c
    WHERE snap.agent_id = ANY (c.agent_ids) AND c.status = 'mapped'
      AND c.received_at BETWEEN snap.prev_at AND snap.observed_at;
    PERFORM aigov.audit(CASE WHEN cardinality(ces) > 0 THEN 'agent.drift_attributed' ELSE 'agent.drift_unattributed' END,
                        'service', aigov.api_actor(), 'db', NULL, snap.agent_id,
                        details => jsonb_build_object('snapshot_id', snap.id, 'changed_paths', to_jsonb(paths),
                                                      'change_event_ids', to_jsonb(ces), 'previous_observed_at', snap.prev_at));
    drift := drift || jsonb_build_object('agent', snap.name, 'agent_id', snap.agent_id, 'changed_paths', to_jsonb(paths),
                                         'attributed', cardinality(ces) > 0, 'change_event_ids', to_jsonb(ces));
  END LOOP;
  UPDATE aigov.sweep_state SET last_drift_check = now() WHERE id = 1;

  PERFORM aigov.audit('reconcile.sweep_completed', 'service', aigov.api_actor(), 'db',
                      details => jsonb_build_object('chain', chain, 'expired', expired, 'skipped', skipped, 'failed', failed,
                                                    'missing_confirmed', missing, 'drift', drift));
  RETURN json_build_object('chain', chain, 'expired_remediations', expired, 'skipped_remediations', skipped,
                           'failed_remediations', failed, 'missing_confirmed', missing, 'drift', drift);
END
$$;

REVOKE ALL ON FUNCTION api.reconcile_sweep(int, int), aigov.jsonb_diff_paths(jsonb, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reconcile_sweep(int, int) TO aigov_remediator;
