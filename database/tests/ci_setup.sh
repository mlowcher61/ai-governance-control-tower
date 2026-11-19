#!/bin/bash
# Create the database and owner the way the Red Hat PostgreSQL image does, then run the platform
# bootstrap as the superuser. Used by CI and run_local.sh. Connection: libpq variables (superuser).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
psql -X -v ON_ERROR_STOP=1 -q -c "CREATE ROLE aigov_owner LOGIN PASSWORD 'owner'" -c "CREATE DATABASE aigov OWNER aigov_owner"
psql -X -v ON_ERROR_STOP=1 -q -d aigov -v db=aigov -v owner=aigov_owner -v auth_pw=auth -v grafana_pw=graf \
  -f "$here/bootstrap/platform_roles.sql"
