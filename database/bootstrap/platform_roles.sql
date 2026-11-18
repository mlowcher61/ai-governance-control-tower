-- Platform bootstrap (T0.06): login roles, schemas and a health RPC so PostgREST and Grafana
-- can start before the Stage 1 schema exists. Idempotent; re-run by every platform deploy.
-- Business tables, RPC functions and per-role grants are created by database/migrations (T1.01+).
-- psql variables: auth_pw (PostgREST authenticator), grafana_pw (Grafana read-only), db, owner.
\set ON_ERROR_STOP on

SELECT 'CREATE ROLE aigov_authenticator LOGIN NOINHERIT'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'aigov_authenticator') \gexec
SELECT 'CREATE ROLE aigov_api_anon NOLOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'aigov_api_anon') \gexec
SELECT 'CREATE ROLE grafana_ro LOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafana_ro') \gexec

ALTER ROLE aigov_authenticator PASSWORD :'auth_pw';
ALTER ROLE grafana_ro PASSWORD :'grafana_pw';
GRANT aigov_api_anon TO aigov_authenticator;

REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO aigov_authenticator, grafana_ro;

CREATE SCHEMA IF NOT EXISTS api AUTHORIZATION :"owner";
CREATE SCHEMA IF NOT EXISTS reporting AUTHORIZATION :"owner";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA api TO aigov_api_anon;
GRANT USAGE ON SCHEMA reporting TO grafana_ro;

-- The only object the anonymous API role can reach: a liveness RPC (GET /rpc/health).
CREATE OR REPLACE FUNCTION api.health() RETURNS json
LANGUAGE sql STABLE AS $$
  SELECT json_build_object('status', 'ok', 'database', current_database(),
                           'server_version', current_setting('server_version'))
$$;
ALTER FUNCTION api.health() OWNER TO :"owner";
REVOKE ALL ON FUNCTION api.health() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.health() TO aigov_api_anon;

NOTIFY pgrst, 'reload schema';
