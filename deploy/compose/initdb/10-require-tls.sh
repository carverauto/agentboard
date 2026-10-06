#!/bin/sh
# Runs once, when the Postgres volume is first initialized: accept network
# connections only over TLS (local socket access inside the container is
# unchanged).
set -eu
hba="$PGDATA/pg_hba.conf"
sed -i -E 's/^host([[:space:]]+all[[:space:]]+all[[:space:]]+all[[:space:]]+)/hostssl\1/' "$hba"
printf 'hostnossl all all all reject\n' >> "$hba"
