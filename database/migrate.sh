#!/bin/bash
# Forward-only migration runner (T1.01). Applies database/migrations/V###__*.sql in version order,
# each file plus its schema_migrations row in ONE transaction, and refuses to continue when an
# applied file's checksum changed (applied migrations must never be edited).
#
# Usage: migrate.sh <migrations-dir>
# Connection: standard libpq variables (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD).
set -euo pipefail
dir=${1:?usage: migrate.sh <migrations-dir>}
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
psql_q() { psql -X -v ON_ERROR_STOP=1 -qtA "$@"; }

psql_q -c "CREATE SCHEMA IF NOT EXISTS aigov" \
       -c "CREATE TABLE IF NOT EXISTS aigov.schema_migrations (
             version text PRIMARY KEY, description text NOT NULL, checksum text NOT NULL,
             applied_at timestamptz NOT NULL DEFAULT now(), applied_by text NOT NULL DEFAULT current_user)"

applied=0
for f in $(ls "$dir"/V[0-9][0-9][0-9]__*.sql | sort); do
  name=$(basename "$f" .sql)
  version=${name%%__*}
  description=${name#*__}
  sum=$(sha256sum "$f" | cut -d' ' -f1)
  recorded=$(psql_q -c "SELECT checksum FROM aigov.schema_migrations WHERE version = '$version'")
  if [[ -n "$recorded" ]]; then
    if [[ "$recorded" != "$sum" ]]; then
      echo "ERROR: $name was changed after it was applied (checksum $recorded -> $sum)." >&2
      echo "       Applied migrations are immutable: revert the edit and add a new migration." >&2
      exit 3
    fi
    echo "ok       $name"
    continue
  fi
  echo "applying $name"
  psql -X -v ON_ERROR_STOP=1 -q --single-transaction -f "$f" \
    -c "INSERT INTO aigov.schema_migrations (version, description, checksum) VALUES ('$version', '$description', '$sum')"
  applied=$((applied + 1))
done
echo "migrations complete: $applied applied, current version $(psql_q -c 'SELECT max(version) FROM aigov.schema_migrations')"
