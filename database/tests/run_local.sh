#!/bin/bash
# Run the database tests against a throwaway PostgreSQL 16 container (podman or docker):
# bootstrap roles -> migrations (twice, to prove idempotency) -> SQL tests -> PostgREST HTTP tests.
#   database/tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
engine=$(command -v podman || command -v docker)
name=aigov-sqltest-$$
port=${AIGOV_TEST_API_PORT:-3300}
"$engine" run -d --rm --name "$name" -p "127.0.0.1:$port:3000" -e POSTGRES_PASSWORD=pw docker.io/library/postgres:16 >/dev/null
trap '"$engine" rm -f "$name-api" "$name" >/dev/null 2>&1' EXIT
until "$engine" exec "$name" pg_isready -U postgres -q; do sleep 1; done
sleep 2
"$engine" cp database "$name":/database
"$engine" exec -e PGUSER=postgres "$name" bash /database/tests/ci_setup.sh
"$engine" exec -e PGUSER=aigov_owner -e PGPASSWORD=owner -e PGHOST=127.0.0.1 -e PGDATABASE=aigov "$name" \
  bash -c 'bash /database/migrate.sh /database/migrations && bash /database/migrate.sh /database/migrations'
# The tests switch to each API role (SET ROLE), so they run as the superuser.
"$engine" exec -e PGUSER=postgres -e PGDATABASE=aigov "$name" \
  bash -c 'for t in /database/tests/test_*.sql; do psql -X -q -v ON_ERROR_STOP=1 -f "$t" || exit 1; done'

# HTTP tests through PostgREST (same image as the cluster) sharing the database container's network.
secret=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
"$engine" run -d --rm --name "$name-api" --network "container:$name" \
  -e PGRST_DB_URI="postgres://aigov_authenticator:auth@127.0.0.1:5432/aigov" -e PGRST_DB_SCHEMAS=api \
  -e PGRST_DB_ANON_ROLE=aigov_api_anon -e PGRST_JWT_SECRET="$secret" docker.io/postgrest/postgrest:v16.6 >/dev/null
for _ in $(seq 30); do curl -sf "http://127.0.0.1:$port/rpc/health" >/dev/null && break; sleep 1; done
AIGOV_API_URL="http://127.0.0.1:$port" AIGOV_JWT_SECRET="$secret" python3 database/tests/test_api_http.py
# Contract test: discovery fixtures in -> policy-input fixtures out (needs jsonschema).
AIGOV_API_URL="http://127.0.0.1:$port" AIGOV_JWT_SECRET="$secret" "${AIGOV_PYTHON:-python3}" database/tests/test_contracts_api.py
