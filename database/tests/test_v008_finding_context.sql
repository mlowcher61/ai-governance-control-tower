-- SQL assertions for V008: blast radius and registry facts in the finding context.
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO aigov.cloud_accounts (id, provider, account_ref) VALUES ('00000000-0000-0000-0000-00000000b801', 'aws', '666677778888');
INSERT INTO aigov.agent_identities (id, provider, principal_ref, collected_at) VALUES
  ('00000000-0000-0000-0000-00000000b802', 'aws', 'arn:aws:iam::666677778888:role/shared', now()),
  ('00000000-0000-0000-0000-00000000b803', 'aws', 'arn:aws:iam::666677778888:role/own', now());
INSERT INTO aigov.owners (id, name, email, approved) VALUES ('own-x', 'Team X', 'x@example.com', true);
INSERT INTO aigov.agent_registrations (registration_id, match_keys, owner_id, environment, data_classification)
VALUES ('REG-9001', '{"name": "a1"}', 'own-x', 'production', 'confidential');
INSERT INTO aigov.ai_agents (id, provider, platform, account_id, region, external_id, resource_ref, name, content_hash, identity_id, registration_id, registration_status) VALUES
  ('00000000-0000-0000-0000-00000000b811', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000b801', 'r', 'a1', 'arn:a1', 'a1', 'h', '00000000-0000-0000-0000-00000000b802', 'REG-9001', 'registered'),
  ('00000000-0000-0000-0000-00000000b812', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000b801', 'r', 'a2', 'arn:a2', 'a2', 'h', '00000000-0000-0000-0000-00000000b802', NULL, 'unregistered'),
  ('00000000-0000-0000-0000-00000000b813', 'aws', 'aws.bedrock_agentcore_runtime', '00000000-0000-0000-0000-00000000b801', 'r', 'a3', 'arn:a3', 'a3', 'h', '00000000-0000-0000-0000-00000000b803', NULL, 'unregistered');
INSERT INTO aigov.findings (id, agent_id, policy_id, finding_type, severity, fingerprint, deterministic_explanation) VALUES
  ('00000000-0000-0000-0000-00000000b821', '00000000-0000-0000-0000-00000000b811', 'AIGOV-IAM-001', 'violation', 'critical', 'f', 'x'),
  ('00000000-0000-0000-0000-00000000b823', '00000000-0000-0000-0000-00000000b813', 'AIGOV-IAM-001', 'violation', 'critical', 'f', 'x');
DO $$
DECLARE c json;
BEGIN
  EXECUTE 'SET LOCAL ROLE aigov_remediator';
  c := api.get_finding_context('00000000-0000-0000-0000-00000000b821');
  IF (c ->> 'agents_sharing_role')::int <> 1 THEN RAISE EXCEPTION 'shared role not counted: %', c; END IF;
  IF c -> 'registration' ->> 'owner_email' <> 'x@example.com' OR c -> 'registration' ->> 'data_classification' <> 'confidential' THEN
    RAISE EXCEPTION 'registry facts missing: %', c;
  END IF;
  c := api.get_finding_context('00000000-0000-0000-0000-00000000b823');
  IF (c ->> 'agents_sharing_role')::int <> 0 OR c -> 'registration' IS NOT NULL AND json_typeof(c -> 'registration') <> 'null' THEN
    RAISE EXCEPTION 'unshared, unregistered context wrong: %', c;
  END IF;
  RESET ROLE;
END $$;
ROLLBACK;
\echo 'test_v008_finding_context: all assertions passed'
