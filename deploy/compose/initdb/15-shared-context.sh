#!/bin/sh
# Install the extension through the bootstrap operator, before creating the API role.
set -eu
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 \
  --command "CREATE EXTENSION IF NOT EXISTS pg_textsearch VERSION '1.5.1';"
