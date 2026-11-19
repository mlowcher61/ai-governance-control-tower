-- V001 baseline (T1.01): governance inventory, evaluations, findings, remediation and audit.
-- See docs/plan/03-stage-one-plan.md section 5. Forward-only: never edit after it is applied;
-- add V002+ instead. Runs as the database owner (aigov_owner) inside one transaction.
-- No extensions are needed: gen_random_uuid() and sha256() are core in PostgreSQL 13+.

CREATE SCHEMA IF NOT EXISTS aigov;
REVOKE ALL ON SCHEMA aigov FROM PUBLIC;

-- ---------------------------------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------------------------------
CREATE TABLE aigov.cloud_accounts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider      text NOT NULL CHECK (provider IN ('aws', 'azure', 'gcp', 'generic')),
  account_ref   text NOT NULL,
  alias         text,
  default_environment text,
  remediation_allowlisted boolean NOT NULL DEFAULT false,   -- informational; the authority is OPA data
  UNIQUE (provider, account_ref)
);

CREATE TABLE aigov.owners (
  id          text PRIMARY KEY,
  name        text NOT NULL,
  email       text,
  approved    boolean NOT NULL DEFAULT false,
  approved_by text,
  approved_at date,
  source      text NOT NULL DEFAULT 'registry',
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE aigov.agent_registrations (
  registration_id text PRIMARY KEY,
  match_keys      jsonb NOT NULL,
  owner_id        text REFERENCES aigov.owners (id),
  business_purpose text,
  environment     text,
  data_classification text,
  declared_model  text,
  approved_tools  text[] NOT NULL DEFAULT '{}',
  risk_assessment jsonb,
  sensitive_data_approval jsonb,
  source_commit   text,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE aigov.ai_models (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider      text NOT NULL,
  model_id      text NOT NULL,
  model_arn     text,
  vendor        text,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, model_id)
);

CREATE TABLE aigov.agent_identities (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider      text NOT NULL,
  principal_ref text NOT NULL,
  permissions_boundary_ref text,
  trust_policy  jsonb,
  tags          jsonb NOT NULL DEFAULT '{}',
  collected_at  timestamptz NOT NULL,
  UNIQUE (provider, principal_ref)
);

CREATE TABLE aigov.ai_agents (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider        text NOT NULL,
  platform        text NOT NULL,
  account_id      uuid NOT NULL REFERENCES aigov.cloud_accounts (id),
  region          text,
  external_id     text NOT NULL,
  resource_ref    text NOT NULL,
  name            text NOT NULL,
  environment     text,
  status          text,
  model_id        uuid REFERENCES aigov.ai_models (id),
  identity_id     uuid REFERENCES aigov.agent_identities (id),
  registration_id text REFERENCES aigov.agent_registrations (registration_id),
  registration_status text NOT NULL DEFAULT 'unregistered'
                  CHECK (registration_status IN ('registered', 'unregistered', 'retired')),
  tags            jsonb NOT NULL DEFAULT '{}',
  attributes      jsonb NOT NULL DEFAULT '{}',
  evidence_status jsonb NOT NULL DEFAULT '{}',
  source_created_at timestamptz,
  source_updated_at timestamptz,
  first_seen_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  missing_since   timestamptz,
  content_hash    text NOT NULL,
  compliance_status text NOT NULL DEFAULT 'not_evaluated'
                  CHECK (compliance_status IN ('compliant', 'noncompliant', 'unknown', 'error', 'not_evaluated')),
  risk_score      smallint,
  risk_category   text,
  last_evaluated_at timestamptz,
  UNIQUE NULLS NOT DISTINCT (provider, account_id, region, external_id)
);

CREATE TABLE aigov.agent_tools (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id     uuid NOT NULL REFERENCES aigov.ai_agents (id) ON DELETE CASCADE,
  tool_type    text NOT NULL,
  external_id  text NOT NULL,
  name         text,
  state        text,
  executor_ref text,
  parent_signature text,
  schema_hash  text,
  attributes   jsonb NOT NULL DEFAULT '{}',
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agent_id, tool_type, external_id)
);

CREATE TABLE aigov.agent_data_sources (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id     uuid NOT NULL REFERENCES aigov.ai_agents (id) ON DELETE CASCADE,
  source_type  text NOT NULL,
  external_id  text NOT NULL,
  name         text,
  state        text,
  storage_ref  text,
  classification text,
  classification_source text,
  attributes   jsonb NOT NULL DEFAULT '{}',
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agent_id, source_type, external_id)
);

CREATE TABLE aigov.identity_permissions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  identity_id   uuid NOT NULL REFERENCES aigov.agent_identities (id) ON DELETE CASCADE,
  policy_type   text NOT NULL CHECK (policy_type IN ('aws_managed', 'customer_managed', 'inline', 'boundary')),
  policy_ref    text NOT NULL,
  policy_name   text,
  default_version text,
  document      jsonb NOT NULL,
  document_hash text NOT NULL,
  collected_at  timestamptz NOT NULL,
  removed_at    timestamptz,
  UNIQUE (identity_id, policy_type, policy_ref, document_hash)
);

-- ---------------------------------------------------------------------------------------------
-- Runs, snapshots and evaluations
-- ---------------------------------------------------------------------------------------------
CREATE TABLE aigov.governance_runs (
  id              uuid PRIMARY KEY,
  run_type        text NOT NULL CHECK (run_type IN ('assessment', 'remediation', 'targeted_reassessment', 'reconciliation')),
  trigger_type    text NOT NULL CHECK (trigger_type IN ('manual', 'schedule', 'event')),
  trigger_ref     text,
  ao_execution_id text,
  started_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz,
  status          text NOT NULL DEFAULT 'running'
);

CREATE TABLE aigov.discovery_runs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  governance_run_id uuid REFERENCES aigov.governance_runs (id),
  provider          text NOT NULL,
  scope             jsonb NOT NULL,
  aap_job_id        bigint,
  started_at        timestamptz NOT NULL DEFAULT now(),
  finished_at       timestamptz,
  status            text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'succeeded', 'partial', 'failed')),
  counts            jsonb NOT NULL DEFAULT '{}',
  errors            jsonb NOT NULL DEFAULT '[]'
);

CREATE TABLE aigov.agent_snapshots (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id         uuid NOT NULL REFERENCES aigov.ai_agents (id) ON DELETE CASCADE,
  discovery_run_id uuid NOT NULL REFERENCES aigov.discovery_runs (id),
  content_hash     text NOT NULL,
  record           jsonb NOT NULL,
  observed_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE aigov.policy_evaluations (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  governance_run_id uuid REFERENCES aigov.governance_runs (id),
  agent_id          uuid NOT NULL REFERENCES aigov.ai_agents (id),
  snapshot_id       uuid REFERENCES aigov.agent_snapshots (id),
  bundle_revision   text NOT NULL,
  opa_decision_id   text,
  input_hash        text NOT NULL,
  overall_status    text NOT NULL CHECK (overall_status IN ('compliant', 'noncompliant', 'unknown', 'error')),
  risk_score        smallint NOT NULL,
  risk_category     text NOT NULL,
  risk_factors      jsonb NOT NULL,
  evaluated_at      timestamptz NOT NULL DEFAULT now(),
  purpose           text NOT NULL DEFAULT 'assessment' CHECK (purpose IN ('assessment', 'pre_remediation', 'verification'))
);

CREATE TABLE aigov.policy_results (
  evaluation_id  uuid NOT NULL REFERENCES aigov.policy_evaluations (id) ON DELETE CASCADE,
  policy_id      text NOT NULL,
  policy_version text NOT NULL,
  decision       text NOT NULL CHECK (decision IN ('pass', 'fail', 'unknown', 'not_applicable', 'error')),
  severity       text NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low', 'info')),
  explanation    text NOT NULL,
  evidence       jsonb NOT NULL DEFAULT '[]',
  assumptions    text[] NOT NULL DEFAULT '{}',
  remediation    jsonb,
  controls       text[] NOT NULL DEFAULT '{}',
  PRIMARY KEY (evaluation_id, policy_id)
);

-- ---------------------------------------------------------------------------------------------
-- Findings, remediation and approvals
-- ---------------------------------------------------------------------------------------------
CREATE TABLE aigov.findings (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id          uuid NOT NULL REFERENCES aigov.ai_agents (id),
  policy_id         text NOT NULL,
  finding_type      text NOT NULL CHECK (finding_type IN ('violation', 'insufficient_evidence')),
  status            text NOT NULL DEFAULT 'open' CHECK (status IN
                    ('open', 'remediation_planned', 'awaiting_approval', 'remediating', 'verifying',
                     'resolved', 'risk_accepted', 'suppressed', 'false_positive')),
  severity          text NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low', 'info')),
  fingerprint       text NOT NULL,
  first_detected_at timestamptz NOT NULL DEFAULT now(),
  last_detected_at  timestamptz NOT NULL DEFAULT now(),
  source_change_at  timestamptz,
  resolved_at       timestamptz,
  resolution        text,
  latest_evaluation_id uuid REFERENCES aigov.policy_evaluations (id),
  deterministic_explanation text NOT NULL,
  ai_explanation    jsonb,
  remediation_attempts smallint NOT NULL DEFAULT 0,
  cooldown_until    timestamptz
);

CREATE TABLE aigov.remediation_actions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  governance_run_id uuid NOT NULL REFERENCES aigov.governance_runs (id),
  finding_id        uuid NOT NULL REFERENCES aigov.findings (id),
  action_type       text NOT NULL,
  mode              text NOT NULL CHECK (mode IN ('dry_run', 'enforce')),
  status            text NOT NULL CHECK (status IN ('planned', 'awaiting_approval', 'approved', 'rejected',
                    'expired', 'executing', 'succeeded', 'failed', 'verified', 'verification_failed',
                    'rolled_back', 'rollback_failed', 'skipped')),
  authz_decision    jsonb NOT NULL,
  ai_recommendation jsonb,
  ai_recommendation_accepted boolean,
  planned_change    jsonb,
  pre_state         jsonb,
  post_state        jsonb,
  aap_job_ids       bigint[] NOT NULL DEFAULT '{}',
  ao_execution_id   text,
  attempt_number    smallint NOT NULL,
  error             jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE aigov.approvals (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  remediation_action_id uuid NOT NULL REFERENCES aigov.remediation_actions (id),
  ao_approval_id        text,
  prompt                text,
  approvers_required    text[] NOT NULL,
  decision              text CHECK (decision IN ('approved', 'rejected', 'expired')),
  decided_by            text,
  decision_notes        text,
  requested_at          timestamptz NOT NULL DEFAULT now(),
  decided_at            timestamptz
);

-- One open finding per agent, policy and fingerprint
CREATE UNIQUE INDEX findings_open_uq ON aigov.findings (agent_id, policy_id, fingerprint)
  WHERE status NOT IN ('resolved', 'false_positive');
-- At most one active remediation per finding (loop and race prevention)
CREATE UNIQUE INDEX remediation_active_uq ON aigov.remediation_actions (finding_id)
  WHERE status IN ('planned', 'awaiting_approval', 'approved', 'executing');

-- ---------------------------------------------------------------------------------------------
-- Audit: append-only and hash-chained
-- ---------------------------------------------------------------------------------------------
CREATE TABLE aigov.audit_events (
  id                    bigserial PRIMARY KEY,
  occurred_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  governance_run_id     uuid,
  event_type            text NOT NULL,
  actor_type            text NOT NULL CHECK (actor_type IN ('service', 'human', 'ai', 'policy')),
  actor_id              text NOT NULL,
  agent_id              uuid,
  finding_id            uuid,
  remediation_action_id uuid,
  source_system         text NOT NULL CHECK (source_system IN ('aap', 'ao', 'opa', 'eda', 'aws', 'db')),
  source_ref            text,
  details               jsonb NOT NULL DEFAULT '{}',
  prev_hash             text NOT NULL,
  hash                  text NOT NULL
);

-- Canonical text of an audit row (everything except id and the hashes). jsonb text output is
-- deterministic, and the timestamp is rendered in UTC with microseconds.
CREATE FUNCTION aigov.audit_canonical(e aigov.audit_events) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'occurred_at', to_char(e.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'governance_run_id', e.governance_run_id,
    'event_type', e.event_type,
    'actor_type', e.actor_type,
    'actor_id', e.actor_id,
    'agent_id', e.agent_id,
    'finding_id', e.finding_id,
    'remediation_action_id', e.remediation_action_id,
    'source_system', e.source_system,
    'source_ref', e.source_ref,
    'details', e.details)::text
$$;

-- Serializes writers with a transaction-level advisory lock, then assigns the id AFTER taking the
-- lock, so id order always equals chain order even under concurrent inserts.
CREATE FUNCTION aigov.audit_events_hash() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  last_hash text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('aigov.audit_events'));
  NEW.id := nextval(pg_get_serial_sequence('aigov.audit_events', 'id'));
  NEW.occurred_at := coalesce(NEW.occurred_at, clock_timestamp());
  SELECT a.hash INTO last_hash FROM aigov.audit_events a ORDER BY a.id DESC LIMIT 1;
  NEW.prev_hash := coalesce(last_hash, repeat('0', 64));
  NEW.hash := encode(sha256(convert_to(NEW.prev_hash || '|' || aigov.audit_canonical(NEW), 'UTF8')), 'hex');
  RETURN NEW;
END
$$;

CREATE TRIGGER audit_events_hash BEFORE INSERT ON aigov.audit_events
  FOR EACH ROW EXECUTE FUNCTION aigov.audit_events_hash();

CREATE FUNCTION aigov.audit_events_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'aigov.audit_events is append-only (% rejected)', TG_OP
    USING ERRCODE = 'insufficient_privilege';
END
$$;

CREATE TRIGGER audit_events_immutable BEFORE UPDATE OR DELETE ON aigov.audit_events
  FOR EACH ROW EXECUTE FUNCTION aigov.audit_events_immutable();
CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON aigov.audit_events
  FOR EACH STATEMENT EXECUTE FUNCTION aigov.audit_events_immutable();

-- Walks the chain from from_id and returns the first row whose prev_hash or hash does not match
-- (NULL when the chain is intact).
CREATE FUNCTION aigov.verify_audit_chain(from_id bigint DEFAULT 0)
RETURNS TABLE (broken_id bigint, reason text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e aigov.audit_events;
  expected_prev text;
BEGIN
  SELECT a.hash INTO expected_prev FROM aigov.audit_events a WHERE a.id < from_id ORDER BY a.id DESC LIMIT 1;
  expected_prev := coalesce(expected_prev, repeat('0', 64));
  FOR e IN SELECT * FROM aigov.audit_events a WHERE a.id >= from_id ORDER BY a.id LOOP
    IF e.prev_hash <> expected_prev THEN
      broken_id := e.id; reason := 'prev_hash does not match the previous row'; RETURN NEXT; RETURN;
    END IF;
    IF e.hash <> encode(sha256(convert_to(e.prev_hash || '|' || aigov.audit_canonical(e), 'UTF8')), 'hex') THEN
      broken_id := e.id; reason := 'hash does not match the row content'; RETURN NEXT; RETURN;
    END IF;
    expected_prev := e.hash;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------------------------
-- Indexes (docs/plan/03 section 5.4)
-- ---------------------------------------------------------------------------------------------
CREATE INDEX ai_agents_compliance_idx ON aigov.ai_agents (compliance_status);
CREATE INDEX ai_agents_risk_idx ON aigov.ai_agents (risk_category);
CREATE INDEX ai_agents_registration_idx ON aigov.ai_agents (registration_status);
CREATE INDEX ai_agents_scope_idx ON aigov.ai_agents (account_id, region);
CREATE INDEX ai_agents_tags_idx ON aigov.ai_agents USING gin (tags jsonb_path_ops);
CREATE INDEX agent_snapshots_agent_idx ON aigov.agent_snapshots (agent_id, observed_at DESC);
CREATE INDEX policy_evaluations_agent_idx ON aigov.policy_evaluations (agent_id, evaluated_at DESC);
CREATE INDEX policy_results_policy_idx ON aigov.policy_results (policy_id, decision);
CREATE INDEX findings_status_idx ON aigov.findings (status, severity);
CREATE INDEX findings_detected_idx ON aigov.findings (first_detected_at);
CREATE INDEX findings_resolved_idx ON aigov.findings (resolved_at);
CREATE INDEX remediation_actions_status_idx ON aigov.remediation_actions (status, created_at);
CREATE INDEX audit_events_run_idx ON aigov.audit_events (governance_run_id);
CREATE INDEX audit_events_agent_idx ON aigov.audit_events (agent_id, occurred_at);
CREATE INDEX audit_events_type_idx ON aigov.audit_events (event_type, occurred_at);
CREATE INDEX audit_events_time_brin ON aigov.audit_events USING brin (occurred_at);

-- ---------------------------------------------------------------------------------------------
-- Privileges. Clients never touch aigov tables: writers go through SECURITY DEFINER functions
-- in schema api (V002), readers through api and reporting views. Auditors may read the audit log.
-- ---------------------------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA aigov FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA aigov FROM PUBLIC;
GRANT USAGE ON SCHEMA aigov TO aigov_auditor;
GRANT SELECT ON aigov.audit_events TO aigov_auditor;
GRANT EXECUTE ON FUNCTION aigov.verify_audit_chain(bigint), aigov.audit_canonical(aigov.audit_events) TO aigov_auditor;
