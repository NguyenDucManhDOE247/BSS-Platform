#!/bin/bash
# Creates per-service databases on first start.
# Postgres image runs everything in /docker-entrypoint-initdb.d/ once.
set -e

for db in customer product orders billing; do
  echo "Creating database: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE $db;
    GRANT ALL PRIVILEGES ON DATABASE $db TO $POSTGRES_USER;
EOSQL
done
