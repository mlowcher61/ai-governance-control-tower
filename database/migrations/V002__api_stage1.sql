-- V002 API layer, Stage 1 set (T1.02). See docs/plan/03-stage-one-plan.md section 5.5 and
-- docs/plan/08-security-and-governance.md section 4.3.
--
-- Clients (PostgREST, selected by the JWT "role" claim) never touch aigov tables. They call the
-- SECURITY DEFINER functions and read the views in schema api. Each function is executable only by
-- the role that needs it. Forward-only: never edit after it is applied; add V003+ instead.

-- ---------------------------------------------------------------------------------------------
-- Schema additions
-- ---------------------------------------------------------------------------------------------
-- IAM policy simulator results for the identity (probe action -> allowed | denied), part of the
-- policy input (identity.simulation).
ALTER TABLE aigov.agent_identities
  ADD COLUMN simulation jsonb NOT NULL DEFAULT '{}';

-- New functions created by the owner are not executable by PUBLIC (grants below are explicit).
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
GRANT USAGE ON SCHEMA api TO aigov_discovery, aigov_registry, aigov_evaluator, aigov_remediator,
  aigov_reader, aigov_auditor;

-- ---------------------------------------------------------------------------------------------
-- Internal helpers (schema aigov: not reachable through the API)
-- ---------------------------------------------------------------------------------------------

-- Identity of the API caller for audit rows: the JWT "sub" claim, else its "role" claim, else the
-- database session user (migrations, psql).
CREATE FUNCTION aigov.api_actor() RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub',
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
                  session_user::text)
$$;

-- Raise a client error (PostgREST maps SQLSTATE 22023 to HTTP 400).
CREATE FUNCTION aigov.api_error(msg text) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  RAISE EXCEPTION '%', msg USING ERRCODE = 'invalid_parameter_value';
END
$$;

-- Content hash of a discovery record: sha256 of its canonical jsonb text without the fields that
-- change on every collection. jsonb output is key-ordered, so equal content gives equal hashes.
CREATE FUNCTION aigov.record_content_hash(rec jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT encode(sha256(convert_to(
    ((rec - 'content_hash' - 'collected_at' - 'observed_at') #- '{identity,collected_at}')::text,
    'UTF8')), 'hex')
$$;

-- Registry dates (YYYY-MM-DD) as RFC 3339 timestamps; timestamps are normalized to UTC.
CREATE FUNCTION aigov.rfc3339(v text) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE
    WHEN v IS NULL OR v = '' THEN NULL
    WHEN v ~ '^\d{4}-\d{2}-\d{2}$' THEN v || 'T00:00:00Z'
    ELSE to_char(v::timestamptz AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  END
$$;

-- Normalize every date-like member of a registry jsonb object (risk assessment, approvals).
CREATE FUNCTION aigov.rfc3339_members(obj jsonb) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN obj IS NULL OR jsonb_typeof(obj) <> 'object' THEN obj ELSE
    (SELECT coalesce(jsonb_object_agg(k, CASE
       WHEN k ~ '(_at|_on|_date)$' AND jsonb_typeof(v) = 'string' THEN to_jsonb(aigov.rfc3339(v #>> '{}'))
       ELSE v END), '{}'::jsonb)
     FROM jsonb_each(obj) AS e (k, v))
  END
$$;

-- Best registration for an agent: every key in match_keys must equal the agent's value. The most
-- specific match (most keys) wins; ties are broken by registration_id so matching is deterministic.
CREATE FUNCTION aigov.match_registration(agent_id uuid) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT r.registration_id
  FROM aigov.ai_agents a
  JOIN aigov.cloud_accounts c ON c.id = a.account_id
  CROSS JOIN LATERAL (SELECT jsonb_strip_nulls(jsonb_build_object(
      'provider', a.provider, 'platform', a.platform, 'account_ref', c.account_ref, 'region', a.region,
      'name', a.name, 'external_id', a.external_id, 'resource_ref', a.resource_ref)) AS keys) k
  JOIN aigov.agent_registrations r ON k.keys @> r.match_keys AND r.match_keys <> '{}'::jsonb
  WHERE a.id = match_registration.agent_id
  ORDER BY (SELECT count(*) FROM jsonb_object_keys(r.match_keys)) DESC, r.registration_id
  LIMIT 1
$$;

-- Re-match one agent to the registry; returns true when its registration changed.
CREATE FUNCTION aigov.rematch_agent(agent_id uuid) RETURNS boolean
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  new_reg text := aigov.match_registration(agent_id);
  n int;
BEGIN
  UPDATE aigov.ai_agents a
  SET registration_id = new_reg,
      registration_status = CASE WHEN new_reg IS NULL THEN 'unregistered' ELSE 'registered' END
  WHERE a.id = rematch_agent.agent_id AND a.registration_id IS DISTINCT FROM new_reg;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END
$$;

-- Insert an audit row; returns its id.
CREATE FUNCTION aigov.audit(event_type text, actor_type text, actor_id text, source_system text,
                            governance_run_id uuid DEFAULT NULL, agent_id uuid DEFAULT NULL,
                            finding_id uuid DEFAULT NULL, source_ref text DEFAULT NULL,
                            details jsonb DEFAULT '{}', remediation_action_id uuid DEFAULT NULL)
RETURNS bigint
LANGUAGE sql SET search_path = pg_catalog, pg_temp AS $$
  INSERT INTO aigov.audit_events (event_type, actor_type, actor_id, source_system, governance_run_id,
                                  agent_id, finding_id, source_ref, details, remediation_action_id,
                                  prev_hash, hash)
  VALUES (event_type, actor_type, actor_id, source_system, governance_run_id, agent_id, finding_id,
          source_ref, coalesce(details, '{}'), remediation_action_id, '', '')
  RETURNING id
$$;

-- Make sure a governance run row exists (runs started outside AO, for example a manual job).
CREATE FUNCTION aigov.ensure_governance_run(run_id uuid, run_type text DEFAULT 'assessment',
                                            trigger_type text DEFAULT 'manual') RETURNS uuid
LANGUAGE sql SET search_path = pg_catalog, pg_temp AS $$
  INSERT INTO aigov.governance_runs (id, run_type, trigger_type)
  VALUES (coalesce(run_id, gen_random_uuid()), coalesce(run_type, 'assessment'), coalesce(trigger_type, 'manual'))
  ON CONFLICT (id) DO UPDATE SET id = EXCLUDED.id
  RETURNING id
$$;

-- ---------------------------------------------------------------------------------------------
-- Liveness and identity (every API role)
-- ---------------------------------------------------------------------------------------------
-- SECURITY INVOKER on purpose: current_user is the role PostgREST switched to from the JWT.
CREATE FUNCTION api.whoami() RETURNS json
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT json_build_object('role', current_user, 'actor', aigov_actor.actor)
  FROM (SELECT coalesce(nullif(current_setting('request.jwt.claims', true), '')::json ->> 'sub',
                        current_user::text) AS actor) aigov_actor
$$;

-- ---------------------------------------------------------------------------------------------
-- Discovery (aigov_discovery)
-- ---------------------------------------------------------------------------------------------
-- scope: {"provider": "aws", "account_ref": "123456789012", "regions": ["us-west-1"],
--         "platforms": ["aws.bedrock_agentcore_runtime"]}
CREATE FUNCTION api.start_discovery_run(scope jsonb, governance_run_id uuid DEFAULT NULL,
                                        aap_job_id bigint DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  run_id uuid;
  gov_id uuid;
BEGIN
  IF scope IS NULL OR jsonb_typeof(scope) <> 'object'
     OR coalesce(scope ->> 'provider', '') = '' OR coalesce(scope ->> 'account_ref', '') = '' THEN
    PERFORM aigov.api_error('scope must be an object with provider and account_ref');
  END IF;
  IF scope ? 'regions' AND jsonb_typeof(scope -> 'regions') <> 'array' THEN
    PERFORM aigov.api_error('scope.regions must be an array');
  END IF;
  gov_id := aigov.ensure_governance_run(governance_run_id);
  INSERT INTO aigov.discovery_runs (governance_run_id, provider, scope, aap_job_id)
  VALUES (gov_id, scope ->> 'provider', scope, aap_job_id)
  RETURNING id INTO run_id;
  PERFORM aigov.audit('discovery.run_started', 'service', aigov.api_actor(), 'aap', gov_id,
                      source_ref => aap_job_id::text,
                      details => jsonb_build_object('discovery_run_id', run_id, 'scope', scope));
  RETURN json_build_object('discovery_run_id', run_id, 'governance_run_id', gov_id);
END
$$;

-- records: array of normalized discovery records (schemas/discovery-record.v1.json, T1.03):
--   provider, platform, account_ref, region, external_id, resource_ref, name, status, environment,
--   tags, attributes, evidence_status, source_created_at, source_updated_at,
--   foundation_model {model_id, model_arn, vendor} | null,
--   identity {principal_ref, permissions_boundary_ref, trust_policy, tags, simulation,
--             policies [{type, ref, name, default_version, statements}]} | null,
--   tools [{type, external_id, name, state, executor_ref, parent_signature, schema_hash, attributes}],
--   data_sources [{type, external_id, name, state, storage_ref, classification, classification_source, attributes}]
-- Idempotent: an unchanged record writes no snapshot and no audit event.
-- Related sets (permissions, tools, data sources) are replaced only when their evidence domain
-- was collected, so an AccessDenied never erases what is known.
CREATE FUNCTION api.record_discovery(discovery_run_id uuid, records jsonb)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  run aigov.discovery_runs;
  rec jsonb;
  ev jsonb;
  acct_id uuid;
  mdl_id uuid;
  ident_id uuid;
  agt_id uuid;
  hash text;
  prev_hash text;
  is_new boolean;
  change text;
  res jsonb := '[]';
  i int := 0;
BEGIN
  SELECT * INTO run FROM aigov.discovery_runs d WHERE d.id = record_discovery.discovery_run_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown discovery_run_id'); END IF;
  IF run.status <> 'running' THEN
    PERFORM aigov.api_error(format('discovery run %s is already %s', run.id, run.status));
  END IF;
  IF records IS NULL OR jsonb_typeof(records) <> 'array' THEN
    PERFORM aigov.api_error('records must be an array');
  END IF;

  FOR rec IN SELECT value FROM jsonb_array_elements(records) LOOP
    i := i + 1;
    IF coalesce(rec ->> 'provider', '') = '' OR coalesce(rec ->> 'platform', '') = ''
       OR coalesce(rec ->> 'account_ref', '') = '' OR coalesce(rec ->> 'external_id', '') = ''
       OR coalesce(rec ->> 'resource_ref', '') = '' OR coalesce(rec ->> 'name', '') = '' THEN
      PERFORM aigov.api_error(format('record %s: provider, platform, account_ref, external_id, resource_ref and name are required', i));
    END IF;
    IF rec ->> 'provider' <> run.provider OR rec ->> 'account_ref' <> run.scope ->> 'account_ref' THEN
      PERFORM aigov.api_error(format('record %s (%s) is outside the run scope', i, rec ->> 'external_id'));
    END IF;
    ev := coalesce(rec -> 'evidence_status', '{}');
    hash := aigov.record_content_hash(rec);

    INSERT INTO aigov.cloud_accounts (provider, account_ref, alias)
    VALUES (rec ->> 'provider', rec ->> 'account_ref', rec ->> 'account_alias')
    ON CONFLICT (provider, account_ref) DO UPDATE SET alias = coalesce(EXCLUDED.alias, aigov.cloud_accounts.alias)
    RETURNING id INTO acct_id;

    mdl_id := NULL;
    IF coalesce(rec #>> '{foundation_model,model_id}', '') <> '' THEN
      INSERT INTO aigov.ai_models (provider, model_id, model_arn, vendor)
      VALUES (rec ->> 'provider', rec #>> '{foundation_model,model_id}', rec #>> '{foundation_model,model_arn}',
              rec #>> '{foundation_model,vendor}')
      ON CONFLICT (provider, model_id) DO UPDATE
        SET model_arn = coalesce(EXCLUDED.model_arn, aigov.ai_models.model_arn),
            vendor = coalesce(EXCLUDED.vendor, aigov.ai_models.vendor)
      RETURNING id INTO mdl_id;
    END IF;

    ident_id := NULL;
    IF coalesce(rec #>> '{identity,principal_ref}', '') <> '' THEN
      INSERT INTO aigov.agent_identities (provider, principal_ref, permissions_boundary_ref, trust_policy, tags,
                                          simulation, collected_at)
      VALUES (rec ->> 'provider', rec #>> '{identity,principal_ref}', rec #>> '{identity,permissions_boundary_ref}',
              rec #> '{identity,trust_policy}', coalesce(rec #> '{identity,tags}', '{}'),
              coalesce(rec #> '{identity,simulation}', '{}'), now())
      ON CONFLICT (provider, principal_ref) DO UPDATE
        SET permissions_boundary_ref = EXCLUDED.permissions_boundary_ref,
            trust_policy = EXCLUDED.trust_policy, tags = EXCLUDED.tags,
            simulation = CASE WHEN ev ->> 'identity_simulation' = 'collected' THEN EXCLUDED.simulation
                              ELSE aigov.agent_identities.simulation END,
            collected_at = EXCLUDED.collected_at
      RETURNING id INTO ident_id;

      IF ev ->> 'identity' = 'collected' THEN
        INSERT INTO aigov.identity_permissions (identity_id, policy_type, policy_ref, policy_name, default_version,
                                                document, document_hash, collected_at)
        SELECT ident_id, p ->> 'type', p ->> 'ref', p ->> 'name', p ->> 'default_version',
               coalesce(p -> 'statements', '[]'),
               encode(sha256(convert_to(coalesce(p -> 'statements', '[]')::text, 'UTF8')), 'hex'), now()
        FROM jsonb_array_elements(coalesce(rec #> '{identity,policies}', '[]')) AS p
        ON CONFLICT (identity_id, policy_type, policy_ref, document_hash) DO UPDATE
          SET removed_at = NULL, policy_name = EXCLUDED.policy_name,
              default_version = EXCLUDED.default_version, collected_at = EXCLUDED.collected_at;
        UPDATE aigov.identity_permissions ip SET removed_at = now()
        WHERE ip.identity_id = ident_id AND ip.removed_at IS NULL
          AND NOT EXISTS (
            SELECT FROM jsonb_array_elements(coalesce(rec #> '{identity,policies}', '[]')) AS p
            WHERE p ->> 'type' = ip.policy_type AND p ->> 'ref' = ip.policy_ref
              AND encode(sha256(convert_to(coalesce(p -> 'statements', '[]')::text, 'UTF8')), 'hex') = ip.document_hash);
      END IF;
    END IF;

    SELECT a.id, a.content_hash INTO agt_id, prev_hash
    FROM aigov.ai_agents a
    WHERE a.provider = rec ->> 'provider' AND a.account_id = acct_id
      AND a.region IS NOT DISTINCT FROM (rec ->> 'region') AND a.external_id = rec ->> 'external_id'
    FOR UPDATE;
    is_new := NOT FOUND;

    INSERT INTO aigov.ai_agents AS a (provider, platform, account_id, region, external_id, resource_ref, name,
                                      environment, status, model_id, identity_id, tags, attributes, evidence_status,
                                      source_created_at, source_updated_at, content_hash)
    VALUES (rec ->> 'provider', rec ->> 'platform', acct_id, rec ->> 'region', rec ->> 'external_id',
            rec ->> 'resource_ref', rec ->> 'name', nullif(lower(rec ->> 'environment'), ''), rec ->> 'status',
            mdl_id, ident_id, coalesce(rec -> 'tags', '{}'), coalesce(rec -> 'attributes', '{}'), ev,
            (rec ->> 'source_created_at')::timestamptz, (rec ->> 'source_updated_at')::timestamptz, hash)
    ON CONFLICT (provider, account_id, region, external_id) DO UPDATE
      SET platform = EXCLUDED.platform, resource_ref = EXCLUDED.resource_ref, name = EXCLUDED.name,
          environment = EXCLUDED.environment, status = EXCLUDED.status, model_id = EXCLUDED.model_id,
          identity_id = coalesce(EXCLUDED.identity_id, a.identity_id), tags = EXCLUDED.tags,
          attributes = EXCLUDED.attributes, evidence_status = EXCLUDED.evidence_status,
          source_created_at = EXCLUDED.source_created_at, source_updated_at = EXCLUDED.source_updated_at,
          content_hash = EXCLUDED.content_hash, last_seen_at = now(), missing_since = NULL
    RETURNING a.id INTO agt_id;

    IF ev ->> 'tools' = 'collected' THEN
      INSERT INTO aigov.agent_tools AS t (agent_id, tool_type, external_id, name, state, executor_ref,
                                          parent_signature, schema_hash, attributes)
      SELECT agt_id, x ->> 'type', x ->> 'external_id', x ->> 'name', x ->> 'state', x ->> 'executor_ref',
             x ->> 'parent_signature', x ->> 'schema_hash', coalesce(x -> 'attributes', '{}')
      FROM jsonb_array_elements(coalesce(rec -> 'tools', '[]')) AS x
      ON CONFLICT (agent_id, tool_type, external_id) DO UPDATE
        SET name = EXCLUDED.name, state = EXCLUDED.state, executor_ref = EXCLUDED.executor_ref,
            parent_signature = EXCLUDED.parent_signature, schema_hash = EXCLUDED.schema_hash,
            attributes = EXCLUDED.attributes, last_seen_at = now();
      DELETE FROM aigov.agent_tools t
      WHERE t.agent_id = agt_id AND NOT EXISTS (
        SELECT FROM jsonb_array_elements(coalesce(rec -> 'tools', '[]')) AS x
        WHERE x ->> 'type' = t.tool_type AND x ->> 'external_id' = t.external_id);
    END IF;

    IF ev ->> 'data_sources' = 'collected' THEN
      INSERT INTO aigov.agent_data_sources AS s (agent_id, source_type, external_id, name, state, storage_ref,
                                                 classification, classification_source, attributes)
      SELECT agt_id, x ->> 'type', x ->> 'external_id', x ->> 'name', x ->> 'state', x ->> 'storage_ref',
             x ->> 'classification', x ->> 'classification_source', coalesce(x -> 'attributes', '{}')
      FROM jsonb_array_elements(coalesce(rec -> 'data_sources', '[]')) AS x
      ON CONFLICT (agent_id, source_type, external_id) DO UPDATE
        SET name = EXCLUDED.name, state = EXCLUDED.state, storage_ref = EXCLUDED.storage_ref,
            classification = EXCLUDED.classification, classification_source = EXCLUDED.classification_source,
            attributes = EXCLUDED.attributes, last_seen_at = now();
      DELETE FROM aigov.agent_data_sources s
      WHERE s.agent_id = agt_id AND NOT EXISTS (
        SELECT FROM jsonb_array_elements(coalesce(rec -> 'data_sources', '[]')) AS x
        WHERE x ->> 'type' = s.source_type AND x ->> 'external_id' = s.external_id);
    END IF;

    PERFORM aigov.rematch_agent(agt_id);

    change := CASE WHEN is_new THEN 'new' WHEN prev_hash IS DISTINCT FROM hash THEN 'changed' ELSE 'unchanged' END;
    -- A snapshot is written whenever the content differs from the agent's latest snapshot.
    IF (SELECT s.content_hash FROM aigov.agent_snapshots s WHERE s.agent_id = agt_id
        ORDER BY s.observed_at DESC LIMIT 1) IS DISTINCT FROM hash THEN
      INSERT INTO aigov.agent_snapshots (agent_id, discovery_run_id, content_hash, record, observed_at)
      VALUES (agt_id, run.id, hash, rec || jsonb_build_object('content_hash', hash), clock_timestamp());
      PERFORM aigov.audit(CASE WHEN is_new THEN 'discovery.agent_observed' ELSE 'agent.config_drift' END,
                          'service', aigov.api_actor(), 'aap', run.governance_run_id, agt_id,
                          source_ref => run.aap_job_id::text,
                          details => jsonb_build_object('discovery_run_id', run.id, 'external_id', rec ->> 'external_id',
                                                        'platform', rec ->> 'platform', 'content_hash', hash,
                                                        'previous_hash', prev_hash, 'evidence_status', ev));
    END IF;

    res := res || jsonb_build_object('external_id', rec ->> 'external_id', 'agent_id', agt_id,
                                     'change', change, 'content_hash', hash);
  END LOOP;
  RETURN res::json;
END
$$;

-- Close a run. Only a 'succeeded' run marks agents in its scope that it did not see as missing
-- (missing_since); agents are never deleted. Returns the run summary.
CREATE FUNCTION api.complete_discovery_run(discovery_run_id uuid, status text,
                                           counts jsonb DEFAULT '{}', errors jsonb DEFAULT '[]')
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  run aigov.discovery_runs;
  missing jsonb := '[]';
  r record;
BEGIN
  IF status NOT IN ('succeeded', 'partial', 'failed') THEN
    PERFORM aigov.api_error('status must be succeeded, partial or failed');
  END IF;
  SELECT * INTO run FROM aigov.discovery_runs d WHERE d.id = complete_discovery_run.discovery_run_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown discovery_run_id'); END IF;
  IF run.status <> 'running' THEN
    PERFORM aigov.api_error(format('discovery run %s is already %s', run.id, run.status));
  END IF;

  IF status = 'succeeded' THEN
    FOR r IN
      UPDATE aigov.ai_agents a SET missing_since = now()
      FROM aigov.cloud_accounts c
      WHERE c.id = a.account_id AND c.provider = run.provider AND c.account_ref = run.scope ->> 'account_ref'
        AND a.missing_since IS NULL AND a.last_seen_at < run.started_at
        AND (NOT run.scope ? 'regions' OR a.region IN (SELECT jsonb_array_elements_text(run.scope -> 'regions')))
        AND (NOT run.scope ? 'platforms' OR a.platform IN (SELECT jsonb_array_elements_text(run.scope -> 'platforms')))
      RETURNING a.id, a.external_id
    LOOP
      missing := missing || jsonb_build_object('agent_id', r.id, 'external_id', r.external_id);
      PERFORM aigov.audit('agent.missing', 'service', aigov.api_actor(), 'aap', run.governance_run_id, r.id,
                          source_ref => run.aap_job_id::text,
                          details => jsonb_build_object('discovery_run_id', run.id, 'external_id', r.external_id));
    END LOOP;
  END IF;

  UPDATE aigov.discovery_runs d
  SET status = complete_discovery_run.status, finished_at = now(),
      counts = coalesce(complete_discovery_run.counts, '{}') || jsonb_build_object('missing', jsonb_array_length(missing)),
      errors = coalesce(complete_discovery_run.errors, '[]')
  WHERE d.id = run.id;
  PERFORM aigov.audit('discovery.run_completed', 'service', aigov.api_actor(), 'aap', run.governance_run_id,
                      source_ref => run.aap_job_id::text,
                      details => jsonb_build_object('discovery_run_id', run.id, 'status', status,
                                                    'counts', counts, 'errors', errors, 'missing', missing));
  RETURN json_build_object('discovery_run_id', run.id, 'governance_run_id', run.governance_run_id,
                           'status', status, 'missing', missing);
END
$$;

-- ---------------------------------------------------------------------------------------------
-- Registry (aigov_registry)
-- ---------------------------------------------------------------------------------------------
-- The registry in Git is authoritative: owners and registrations not in the payload are removed,
-- and every agent is re-matched. owners: [{id, name, email, approved, approved_by, approved_at}],
-- registrations: [{registration_id, match_keys, owner_id, business_purpose, environment,
-- data_classification, declared_model, approved_tools, risk_assessment, sensitive_data_approval}].
CREATE FUNCTION api.load_registry(owners jsonb, registrations jsonb, source_commit text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  rematched int := 0;
  a record;
  result json;
BEGIN
  IF jsonb_typeof(load_registry.owners) IS DISTINCT FROM 'array' OR jsonb_typeof(load_registry.registrations) IS DISTINCT FROM 'array' THEN
    PERFORM aigov.api_error('owners and registrations must be arrays');
  END IF;
  IF EXISTS (SELECT FROM jsonb_array_elements(load_registry.owners) o WHERE coalesce(o ->> 'id', '') = '' OR coalesce(o ->> 'name', '') = '') THEN
    PERFORM aigov.api_error('every owner needs id and name');
  END IF;
  IF EXISTS (SELECT FROM jsonb_array_elements(load_registry.registrations) r
             WHERE coalesce(r ->> 'registration_id', '') = ''
                OR jsonb_typeof(r -> 'match_keys') IS DISTINCT FROM 'object' OR r -> 'match_keys' = '{}'::jsonb) THEN
    PERFORM aigov.api_error('every registration needs registration_id and a non-empty match_keys object');
  END IF;

  INSERT INTO aigov.owners AS o (id, name, email, approved, approved_by, approved_at, source, updated_at)
  SELECT x ->> 'id', x ->> 'name', x ->> 'email', coalesce((x ->> 'approved')::boolean, false),
         x ->> 'approved_by', (x ->> 'approved_at')::date, 'registry', now()
  FROM jsonb_array_elements(load_registry.owners) AS x
  ON CONFLICT (id) DO UPDATE
    SET name = EXCLUDED.name, email = EXCLUDED.email, approved = EXCLUDED.approved,
        approved_by = EXCLUDED.approved_by, approved_at = EXCLUDED.approved_at, updated_at = now()
    WHERE (o.name, o.email, o.approved, o.approved_by, o.approved_at)
          IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.email, EXCLUDED.approved, EXCLUDED.approved_by, EXCLUDED.approved_at);

  INSERT INTO aigov.agent_registrations AS g (registration_id, match_keys, owner_id, business_purpose, environment,
                                              data_classification, declared_model, approved_tools, risk_assessment,
                                              sensitive_data_approval, source_commit, updated_at)
  SELECT x ->> 'registration_id', x -> 'match_keys', x ->> 'owner_id', x ->> 'business_purpose',
         nullif(lower(x ->> 'environment'), ''), x ->> 'data_classification', x ->> 'declared_model',
         coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(x -> 'approved_tools', '[]'))), '{}'),
         x -> 'risk_assessment', x -> 'sensitive_data_approval', load_registry.source_commit, now()
  FROM jsonb_array_elements(load_registry.registrations) AS x
  ON CONFLICT (registration_id) DO UPDATE
    SET match_keys = EXCLUDED.match_keys, owner_id = EXCLUDED.owner_id, business_purpose = EXCLUDED.business_purpose,
        environment = EXCLUDED.environment, data_classification = EXCLUDED.data_classification,
        declared_model = EXCLUDED.declared_model, approved_tools = EXCLUDED.approved_tools,
        risk_assessment = EXCLUDED.risk_assessment, sensitive_data_approval = EXCLUDED.sensitive_data_approval,
        source_commit = EXCLUDED.source_commit, updated_at = now();

  -- Remove what the registry no longer declares (agents lose the registration first).
  UPDATE aigov.ai_agents ag SET registration_id = NULL, registration_status = 'unregistered'
  WHERE ag.registration_id IS NOT NULL
    AND ag.registration_id NOT IN (SELECT x ->> 'registration_id' FROM jsonb_array_elements(load_registry.registrations) x);
  DELETE FROM aigov.agent_registrations ar
  WHERE ar.registration_id NOT IN (SELECT x ->> 'registration_id' FROM jsonb_array_elements(load_registry.registrations) x);
  DELETE FROM aigov.owners ow
  WHERE ow.source = 'registry' AND ow.id NOT IN (SELECT x ->> 'id' FROM jsonb_array_elements(load_registry.owners) x);

  FOR a IN SELECT id FROM aigov.ai_agents LOOP
    IF aigov.rematch_agent(a.id) THEN rematched := rematched + 1; END IF;
  END LOOP;

  SELECT json_build_object(
    'owners', (SELECT count(*) FROM aigov.owners),
    'registrations', (SELECT count(*) FROM aigov.agent_registrations),
    'registered_agents', (SELECT count(*) FROM aigov.ai_agents WHERE registration_status = 'registered'),
    'unregistered_agents', (SELECT count(*) FROM aigov.ai_agents WHERE registration_status = 'unregistered'),
    'agents_rematched', rematched,
    'source_commit', load_registry.source_commit) INTO result;
  PERFORM aigov.audit('registry.loaded', 'service', aigov.api_actor(), 'aap', source_ref => load_registry.source_commit,
                      details => result::jsonb);
  RETURN result;
END
$$;

-- ---------------------------------------------------------------------------------------------
-- Evaluation (aigov_evaluator)
-- ---------------------------------------------------------------------------------------------
-- The OPA policy input (docs/plan/03 section 6.2) for every agent that is not missing, without the
-- "evaluation" block, which the Evaluate job adds (governance_run_id, evaluated_at, purpose).
CREATE VIEW api.evaluation_inputs AS
SELECT
  a.id AS agent_id,
  a.content_hash,
  jsonb_build_object(
    'schema_version', '1.0',
    'agent', jsonb_build_object(
      'id', a.id, 'provider', a.provider, 'platform', a.platform, 'external_id', a.external_id,
      'resource_ref', a.resource_ref, 'name', a.name, 'account_ref', c.account_ref, 'region', a.region,
      'environment', a.environment, 'status', a.status, 'foundation_model', m.model_id,
      'tags', a.tags, 'guardrail', a.attributes -> 'guardrail', 'attributes', a.attributes,
      'source_created_at', to_char(a.source_created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'source_updated_at', to_char(a.source_updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
    'identity', CASE WHEN i.id IS NULL THEN NULL ELSE jsonb_build_object(
      'principal_ref', i.principal_ref,
      'permissions_boundary_ref', i.permissions_boundary_ref,
      'policies', coalesce((
        SELECT jsonb_agg(jsonb_build_object('type', p.policy_type, 'ref', p.policy_ref, 'name', p.policy_name,
                                            'statements', p.document) ORDER BY p.policy_type, p.policy_ref)
        FROM aigov.identity_permissions p WHERE p.identity_id = i.id AND p.removed_at IS NULL), '[]'),
      'simulation', i.simulation) END,
    'tools', coalesce((
      SELECT jsonb_agg(jsonb_build_object('type', t.tool_type, 'external_id', t.external_id, 'name', t.name,
                                          'state', t.state, 'executor_ref', t.executor_ref,
                                          'parent_signature', t.parent_signature) ORDER BY t.tool_type, t.external_id)
      FROM aigov.agent_tools t WHERE t.agent_id = a.id), '[]'),
    'data_sources', coalesce((
      SELECT jsonb_agg(jsonb_build_object('type', s.source_type, 'external_id', s.external_id, 'name', s.name,
                                          'storage_ref', s.storage_ref, 'classification', s.classification,
                                          'classification_source', s.classification_source)
                       ORDER BY s.source_type, s.external_id)
      FROM aigov.agent_data_sources s WHERE s.agent_id = a.id), '[]'),
    'registration', CASE WHEN g.registration_id IS NULL THEN jsonb_build_object('status', a.registration_status)
      ELSE jsonb_build_object(
        'status', a.registration_status, 'registration_id', g.registration_id,
        'owner', CASE WHEN o.id IS NULL THEN NULL ELSE jsonb_build_object(
          'id', o.id, 'name', o.name, 'approved', o.approved, 'approved_by', o.approved_by,
          'approved_at', to_char(o.approved_at, 'YYYY-MM-DD"T00:00:00Z"')) END,
        'business_purpose', g.business_purpose, 'environment', g.environment,
        'data_classification', g.data_classification, 'declared_model', g.declared_model,
        'approved_tools', to_jsonb(g.approved_tools),
        'risk_assessment', aigov.rfc3339_members(g.risk_assessment),
        'sensitive_data_approval', aigov.rfc3339_members(g.sensitive_data_approval)) END,
    'evidence', a.evidence_status || jsonb_build_object('registration', 'collected')
  ) AS input
FROM aigov.ai_agents a
JOIN aigov.cloud_accounts c ON c.id = a.account_id
LEFT JOIN aigov.ai_models m ON m.id = a.model_id
LEFT JOIN aigov.agent_identities i ON i.id = a.identity_id
LEFT JOIN aigov.agent_registrations g ON g.registration_id = a.registration_id
LEFT JOIN aigov.owners o ON o.id = g.owner_id
WHERE a.missing_since IS NULL;

-- Store an OPA aggregate result (docs/plan/03 section 6.4, with full per-policy results) and run the
-- finding lifecycle for assessment and verification evaluations:
--   fail    -> open or refresh a 'violation' finding
--   unknown -> open or refresh an 'insufficient_evidence' finding; an unresolved violation of the
--              same policy stays open instead (unknown evidence never closes or weakens it)
--   pass / not_applicable -> auto-close open findings of that policy that are still 'open'
--   error   -> no finding change
-- Findings in a remediation state are never auto-closed here (Stage 2 close_finding does that).
CREATE FUNCTION api.record_evaluation(governance_run_id uuid, agent_id uuid, purpose text, result jsonb,
                                      input_hash text, opa_decision_id text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  agt aigov.ai_agents;
  gov_id uuid;
  eval_id uuid;
  bundle text := coalesce(result ->> 'bundle_revision', 'unknown');
  actor text;
  r jsonb;
  ftype text;
  fid uuid;
  cur aigov.findings;
  opened int := 0;
  refreshed int := 0;
  closed int := 0;
BEGIN
  IF purpose NOT IN ('assessment', 'pre_remediation', 'verification') THEN
    PERFORM aigov.api_error('purpose must be assessment, pre_remediation or verification');
  END IF;
  IF result IS NULL OR jsonb_typeof(result) <> 'object'
     OR coalesce(result ->> 'overall_status', '') NOT IN ('compliant', 'noncompliant', 'unknown', 'error')
     OR jsonb_typeof(result -> 'results') IS DISTINCT FROM 'array'
     OR jsonb_typeof(result #> '{risk,score}') IS DISTINCT FROM 'number' OR coalesce(result #>> '{risk,category}', '') = '' THEN
    PERFORM aigov.api_error('result must contain overall_status, risk.score, risk.category and a results array');
  END IF;
  IF coalesce(input_hash, '') = '' THEN PERFORM aigov.api_error('input_hash is required'); END IF;
  SELECT * INTO agt FROM aigov.ai_agents a WHERE a.id = record_evaluation.agent_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM aigov.api_error('unknown agent_id'); END IF;
  IF result ? 'agent_id' AND result ->> 'agent_id' IS DISTINCT FROM agent_id::text THEN
    PERFORM aigov.api_error('result.agent_id does not match agent_id');
  END IF;

  gov_id := aigov.ensure_governance_run(governance_run_id);
  actor := 'opa:' || bundle;

  INSERT INTO aigov.policy_evaluations (governance_run_id, agent_id, snapshot_id, bundle_revision, opa_decision_id,
                                        input_hash, overall_status, risk_score, risk_category, risk_factors, purpose)
  VALUES (gov_id, agt.id,
          (SELECT s.id FROM aigov.agent_snapshots s WHERE s.agent_id = agt.id ORDER BY s.observed_at DESC LIMIT 1),
          bundle, opa_decision_id, input_hash, result ->> 'overall_status',
          least(greatest((result #>> '{risk,score}')::numeric, 0), 100)::smallint,
          result #>> '{risk,category}', coalesce(result #> '{risk,factors}', '[]'), purpose)
  RETURNING id INTO eval_id;

  INSERT INTO aigov.policy_results (evaluation_id, policy_id, policy_version, decision, severity, explanation,
                                    evidence, assumptions, remediation, controls)
  SELECT eval_id, x ->> 'policy_id', coalesce(x ->> 'policy_version', '0'), x ->> 'decision',
         coalesce(x ->> 'severity', 'info'), coalesce(x ->> 'explanation', ''), coalesce(x -> 'evidence', '[]'),
         coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(x -> 'assumptions', '[]'))), '{}'),
         x -> 'remediation',
         coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(x -> 'controls', '[]'))), '{}')
  FROM jsonb_array_elements(result -> 'results') AS x;

  UPDATE aigov.ai_agents a
  SET compliance_status = result ->> 'overall_status',
      risk_score = least(greatest((result #>> '{risk,score}')::numeric, 0), 100)::smallint,
      risk_category = result #>> '{risk,category}', last_evaluated_at = now()
  WHERE a.id = agt.id;

  PERFORM aigov.audit('policy.evaluated', 'policy', actor, 'opa', gov_id, agt.id, source_ref => opa_decision_id,
                      details => jsonb_build_object('evaluation_id', eval_id, 'purpose', purpose,
                                                    'overall_status', result ->> 'overall_status',
                                                    'risk', result -> 'risk', 'summary', result -> 'summary',
                                                    'bundle_revision', bundle, 'input_hash', input_hash));

  IF purpose IN ('assessment', 'verification') THEN
    FOR r IN SELECT value FROM jsonb_array_elements(result -> 'results') LOOP
      CONTINUE WHEN r ->> 'decision' = 'error';
      ftype := CASE r ->> 'decision' WHEN 'fail' THEN 'violation' WHEN 'unknown' THEN 'insufficient_evidence' END;

      -- Close open findings of this policy that the current decision no longer supports.
      FOR cur IN
        SELECT * FROM aigov.findings f
        WHERE f.agent_id = agt.id AND f.policy_id = r ->> 'policy_id' AND f.status = 'open'
          AND ftype IS DISTINCT FROM f.finding_type
          AND NOT (f.finding_type = 'violation' AND r ->> 'decision' = 'unknown')
      LOOP
        UPDATE aigov.findings f SET status = 'resolved', resolution = 'no_longer_detected', resolved_at = now(),
                                    latest_evaluation_id = eval_id
        WHERE f.id = cur.id;
        closed := closed + 1;
        PERFORM aigov.audit('finding.auto_closed', 'policy', actor, 'opa', gov_id, agt.id, cur.id, opa_decision_id,
                            jsonb_build_object('policy_id', cur.policy_id, 'finding_type', cur.finding_type,
                                               'decision', r ->> 'decision', 'evaluation_id', eval_id));
      END LOOP;

      CONTINUE WHEN ftype IS NULL;
      -- Unknown evidence never weakens a violation: while one is unresolved, no
      -- insufficient_evidence finding is added next to it.
      CONTINUE WHEN ftype = 'insufficient_evidence' AND EXISTS (
        SELECT FROM aigov.findings f WHERE f.agent_id = agt.id AND f.policy_id = r ->> 'policy_id'
          AND f.finding_type = 'violation' AND f.status NOT IN ('resolved', 'false_positive'));
      SELECT * INTO cur FROM aigov.findings f
      WHERE f.agent_id = agt.id AND f.policy_id = r ->> 'policy_id' AND f.finding_type = ftype
        AND f.status NOT IN ('resolved', 'false_positive')
      FOR UPDATE;
      IF FOUND THEN
        UPDATE aigov.findings f
        SET last_detected_at = now(), latest_evaluation_id = eval_id,
            severity = coalesce(r ->> 'severity', f.severity),
            deterministic_explanation = coalesce(nullif(r ->> 'explanation', ''), f.deterministic_explanation)
        WHERE f.id = cur.id;
        refreshed := refreshed + 1;
        IF cur.severity IS DISTINCT FROM coalesce(r ->> 'severity', cur.severity)
           OR cur.deterministic_explanation IS DISTINCT FROM coalesce(nullif(r ->> 'explanation', ''), cur.deterministic_explanation) THEN
          PERFORM aigov.audit('finding.updated', 'policy', actor, 'opa', gov_id, agt.id, cur.id, opa_decision_id,
                              jsonb_build_object('policy_id', cur.policy_id, 'severity', r ->> 'severity',
                                                 'previous_severity', cur.severity, 'evaluation_id', eval_id));
        END IF;
      ELSE
        INSERT INTO aigov.findings (agent_id, policy_id, finding_type, severity, fingerprint, source_change_at,
                                    latest_evaluation_id, deterministic_explanation)
        VALUES (agt.id, r ->> 'policy_id', ftype, coalesce(r ->> 'severity', 'info'),
                encode(sha256(convert_to(agt.id::text || '|' || (r ->> 'policy_id') || '|' || ftype, 'UTF8')), 'hex'),
                agt.source_updated_at, eval_id, coalesce(nullif(r ->> 'explanation', ''), r ->> 'policy_id'))
        RETURNING id INTO fid;
        opened := opened + 1;
        PERFORM aigov.audit('finding.opened', 'policy', actor, 'opa', gov_id, agt.id, fid, opa_decision_id,
                            jsonb_build_object('policy_id', r ->> 'policy_id', 'finding_type', ftype,
                                               'severity', r ->> 'severity', 'evaluation_id', eval_id));
      END IF;
    END LOOP;
  END IF;

  RETURN json_build_object('evaluation_id', eval_id, 'governance_run_id', gov_id,
                           'overall_status', result ->> 'overall_status',
                           'findings', json_build_object('opened', opened, 'refreshed', refreshed, 'auto_closed', closed));
END
$$;

-- Attach advisory AI explanations to open findings. explanations: [{finding_id, headline,
-- risk_explanation, business_impact, recommended_next_step}]. Only these keys are kept, each
-- trimmed to 2000 characters; findings that are not open are skipped, not failed.
CREATE FUNCTION api.record_explanations(governance_run_id uuid, explanations jsonb, model text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  x jsonb;
  f aigov.findings;
  expl jsonb;
  gov_id uuid;
  updated int := 0;
  skipped jsonb := '[]';
BEGIN
  IF jsonb_typeof(explanations) IS DISTINCT FROM 'array' THEN PERFORM aigov.api_error('explanations must be an array'); END IF;
  IF coalesce(model, '') = '' THEN PERFORM aigov.api_error('model is required'); END IF;
  gov_id := aigov.ensure_governance_run(governance_run_id);
  FOR x IN SELECT value FROM jsonb_array_elements(explanations) LOOP
    IF coalesce(x ->> 'finding_id', '') !~ '^[0-9a-fA-F-]{36}$' THEN
      skipped := skipped || jsonb_build_object('finding_id', x -> 'finding_id', 'reason', 'invalid finding_id');
      CONTINUE;
    END IF;
    SELECT * INTO f FROM aigov.findings WHERE id = (x ->> 'finding_id')::uuid FOR UPDATE;
    IF NOT FOUND OR f.status IN ('resolved', 'false_positive', 'suppressed') THEN
      skipped := skipped || jsonb_build_object('finding_id', x ->> 'finding_id', 'reason', 'not an open finding');
      CONTINUE;
    END IF;
    SELECT jsonb_object_agg(k, left(x ->> k, 2000)) INTO expl
    FROM unnest(ARRAY['headline', 'risk_explanation', 'business_impact', 'recommended_next_step']) AS k
    WHERE coalesce(x ->> k, '') <> '';
    expl := coalesce(expl, '{}') || jsonb_build_object('model', model, 'advisory', true,
                                                       'generated_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
    UPDATE aigov.findings SET ai_explanation = expl WHERE id = f.id;
    updated := updated + 1;
    PERFORM aigov.audit('ai.explanation_generated', 'ai', 'llm:' || model, 'ao', gov_id, f.agent_id, f.id,
                        details => jsonb_build_object('policy_id', f.policy_id, 'recorded_by', aigov.api_actor()));
  END LOOP;
  RETURN json_build_object('updated', updated, 'skipped', skipped);
END
$$;

-- ---------------------------------------------------------------------------------------------
-- Generic audit append (writer roles)
-- ---------------------------------------------------------------------------------------------
-- event: {event_type, actor_type?, actor_id?, source_system?, governance_run_id?, agent_id?,
--         finding_id?, remediation_action_id?, source_ref?, details?}. actor_id defaults to the caller.
CREATE FUNCTION api.append_audit_event(event jsonb)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  new_id bigint;
BEGIN
  IF jsonb_typeof(event) IS DISTINCT FROM 'object' OR coalesce(event ->> 'event_type', '') !~ '^[a-z][a-z_]*(\.[a-z][a-z_]*)+$' THEN
    PERFORM aigov.api_error('event.event_type is required, for example "discovery.run_started"');
  END IF;
  IF jsonb_typeof(coalesce(event -> 'details', '{}')) <> 'object' THEN
    PERFORM aigov.api_error('event.details must be an object');
  END IF;
  new_id := aigov.audit(event ->> 'event_type', coalesce(event ->> 'actor_type', 'service'),
                        coalesce(nullif(event ->> 'actor_id', ''), aigov.api_actor()),
                        coalesce(event ->> 'source_system', 'aap'),
                        (event ->> 'governance_run_id')::uuid, (event ->> 'agent_id')::uuid,
                        (event ->> 'finding_id')::uuid, event ->> 'source_ref',
                        coalesce(event -> 'details', '{}') || jsonb_build_object('recorded_by', aigov.api_actor()),
                        (event ->> 'remediation_action_id')::uuid);
  RETURN (SELECT json_build_object('id', e.id, 'hash', e.hash) FROM aigov.audit_events e WHERE e.id = new_id);
END
$$;

-- ---------------------------------------------------------------------------------------------
-- Read-only views (aigov_reader, the AO worker)
-- ---------------------------------------------------------------------------------------------
CREATE VIEW api.agent_overview AS
SELECT a.id AS agent_id, a.name, a.provider, a.platform, c.account_ref, a.region, a.external_id, a.resource_ref,
       coalesce(a.environment, g.environment) AS environment, a.status, a.registration_status, a.registration_id,
       o.name AS owner_name, o.approved AS owner_approved, m.model_id AS foundation_model,
       i.principal_ref AS identity_ref, a.compliance_status, a.risk_score, a.risk_category, a.last_evaluated_at,
       (SELECT count(*) FROM aigov.findings f WHERE f.agent_id = a.id AND f.status NOT IN ('resolved', 'false_positive'))
         AS open_findings,
       a.evidence_status, a.first_seen_at, a.last_seen_at, a.missing_since
FROM aigov.ai_agents a
JOIN aigov.cloud_accounts c ON c.id = a.account_id
LEFT JOIN aigov.ai_models m ON m.id = a.model_id
LEFT JOIN aigov.agent_identities i ON i.id = a.identity_id
LEFT JOIN aigov.agent_registrations g ON g.registration_id = a.registration_id
LEFT JOIN aigov.owners o ON o.id = g.owner_id;

CREATE VIEW api.findings_open AS
SELECT f.id AS finding_id, f.agent_id, a.name AS agent_name, a.platform, c.account_ref, a.region,
       f.policy_id, f.finding_type, f.status, f.severity, f.deterministic_explanation, f.ai_explanation,
       f.first_detected_at, f.last_detected_at, f.remediation_attempts, f.latest_evaluation_id
FROM aigov.findings f
JOIN aigov.ai_agents a ON a.id = f.agent_id
JOIN aigov.cloud_accounts c ON c.id = a.account_id
WHERE f.status NOT IN ('resolved', 'false_positive');

-- ---------------------------------------------------------------------------------------------
-- Privileges: each function only for its role (docs/plan/08 section 4.3)
-- ---------------------------------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA aigov FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA api FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA api FROM PUBLIC;
GRANT EXECUTE ON FUNCTION aigov.verify_audit_chain(bigint), aigov.audit_canonical(aigov.audit_events) TO aigov_auditor;

GRANT EXECUTE ON FUNCTION api.health() TO aigov_api_anon;
GRANT EXECUTE ON FUNCTION api.whoami() TO aigov_discovery, aigov_registry, aigov_evaluator, aigov_remediator,
  aigov_reader, aigov_auditor;
GRANT EXECUTE ON FUNCTION api.start_discovery_run(jsonb, uuid, bigint), api.record_discovery(uuid, jsonb),
  api.complete_discovery_run(uuid, text, jsonb, jsonb) TO aigov_discovery;
GRANT EXECUTE ON FUNCTION api.load_registry(jsonb, jsonb, text) TO aigov_registry;
GRANT SELECT ON api.evaluation_inputs TO aigov_evaluator;
-- Functions inside a view run with the CALLER's privileges: the evaluator needs the two pure date
-- helpers used by api.evaluation_inputs (USAGE on aigov grants no table access).
GRANT USAGE ON SCHEMA aigov TO aigov_evaluator;
GRANT EXECUTE ON FUNCTION aigov.rfc3339(text), aigov.rfc3339_members(jsonb) TO aigov_evaluator;
GRANT EXECUTE ON FUNCTION api.record_evaluation(uuid, uuid, text, jsonb, text, text),
  api.record_explanations(uuid, jsonb, text) TO aigov_evaluator;
GRANT EXECUTE ON FUNCTION api.append_audit_event(jsonb) TO aigov_discovery, aigov_registry, aigov_evaluator,
  aigov_remediator;
GRANT SELECT ON api.agent_overview, api.findings_open TO aigov_reader, aigov_evaluator;

NOTIFY pgrst, 'reload schema';
