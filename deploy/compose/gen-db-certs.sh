#!/bin/sh
# Creates a private CA and a server certificate for the Compose Postgres.
# agentboard always connects to PostgreSQL over TLS and verifies the server
# certificate and hostname, so the local database needs a real certificate.
# Runs once: existing certificates in the volume are kept.
set -eu
dir=/certs
if [ -s "$dir/server.crt" ] && [ -s "$dir/server.key" ] && [ -s "$dir/ca.crt" ]; then
  echo "db-certs: certificates already present"
  exit 0
fi
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
openssl req -x509 -new -nodes -newkey rsa:3072 -sha256 -days 3650 \
  -subj "/CN=agentboard-compose-ca" -keyout "$work/ca.key" -out "$work/ca.crt"
openssl req -new -nodes -newkey rsa:3072 -sha256 \
  -subj "/CN=${DB_CERT_HOST:-db}" -keyout "$work/server.key" -out "$work/server.csr"
printf 'subjectAltName=DNS:%s,DNS:localhost\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n' \
  "${DB_CERT_HOST:-db}" > "$work/ext.cnf"
openssl x509 -req -sha256 -days 3650 -in "$work/server.csr" \
  -CA "$work/ca.crt" -CAkey "$work/ca.key" -CAcreateserial \
  -extfile "$work/ext.cnf" -out "$work/server.crt"
install -m 0644 "$work/ca.crt" "$dir/ca.crt"
install -m 0644 "$work/server.crt" "$dir/server.crt"
# Owned by the postgres user (UID 999) in the official image; PostgreSQL
# refuses a key that other users can read.
install -m 0600 -o 999 -g 999 "$work/server.key" "$dir/server.key"
# The CA key is discarded: delete the volume to issue new certificates.
echo "db-certs: issued CA and server certificate for ${DB_CERT_HOST:-db}"
