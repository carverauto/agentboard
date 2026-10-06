#!/bin/sh
# Creates the `mattermost` role and database used by the optional chat
# profile. Runs automatically when the Postgres volume is first initialized,
# and is safe to re-run (see docs/setup/mattermost.md):
#
#   docker compose exec db /docker-entrypoint-initdb.d/20-mattermost.sh
set -eu
if [ -z "${MATTERMOST_DB_PASSWORD:-}" ]; then
  echo "20-mattermost: MATTERMOST_DB_PASSWORD is not set; skipping Mattermost database"
  exit 0
fi
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname postgres \
  -v mm_password="$MATTERMOST_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE mattermost LOGIN PASSWORD %L', :'mm_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mattermost') \gexec
SELECT format('ALTER ROLE mattermost LOGIN PASSWORD %L', :'mm_password') \gexec
SELECT 'CREATE DATABASE mattermost OWNER mattermost'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'mattermost') \gexec
SQL
echo "20-mattermost: role and database ready"
