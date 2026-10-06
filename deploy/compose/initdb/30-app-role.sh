#!/bin/sh
# Keep the bootstrap superuser separate. PostgreSQL cannot demote its bootstrap
# role; create a normal database-owning application role instead.
set -eu
if [ "$POSTGRES_USER" = "${AGENTBOARD_DATABASE_USER:-agentboard}" ]; then
  echo "POSTGRES_USER and AGENTBOARD_DATABASE_USER must be different" >&2
  exit 1
fi
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 \
  --set app_user="${AGENTBOARD_DATABASE_USER:-agentboard}" \
  --set app_password="$POSTGRES_PASSWORD" --set app_db="$POSTGRES_DB" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=:'app_user') \gexec
ALTER ROLE :"app_user" NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER DATABASE :"app_db" OWNER TO :"app_user";
ALTER SCHEMA public OWNER TO :"app_user";
SQL
