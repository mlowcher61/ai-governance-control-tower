#!/bin/bash
# Run the database tests against a throwaway PostgreSQL 16 container (podman or docker):
# bootstrap roles -> migrations (twice, to prove idempotency) -> SQL tests.
#   database/tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
engine=$(command -v podman || command -v docker)
name=aigov-sqltest-$$
"$engine" run -d --rm --name "$name" -e POSTGRES_PASSWORD=pw docker.io/library/postgres:16 >/dev/null
trap '"$engine" rm -f "$name" >/dev/null' EXIT
until "$engine" exec "$name" pg_isready -U postgres -q; do sleep 1; done
sleep 2
"$engine" cp database "$name":/database
"$engine" exec -e PGUSER=postgres "$name" bash /database/tests/ci_setup.sh
"$engine" exec -e PGUSER=aigov_owner -e PGPASSWORD=owner -e PGHOST=127.0.0.1 -e PGDATABASE=aigov "$name" \
  bash -c 'bash /database/migrate.sh /database/migrations && bash /database/migrate.sh /database/migrations && for t in /database/tests/test_*.sql; do psql -X -q -f "$t"; done'
