#!/bin/sh
# Inicio de una base nueva: aplica el esquema, crea el usuario de la aplicación (readWrite solo sobre su base, sin
# permisos de DDL) y carga los datos demo si SMARTPOT_SEED_DEMO=true. Lo ejecuta el entrypoint de PostgreSQL una
# sola vez, con el servidor ya levantado por el socket local. Las definiciones viven en /opt/smartpot.
set -eu

APP_USER="${SMARTPOT_DB_USERNAME:-smartpot}"
APP_PASSWORD="${SMARTPOT_DB_PASSWORD:-}"
INGEST_USER="${SMARTPOT_INGEST_USERNAME:-smartpot_ingest}"
INGEST_PASSWORD="${SMARTPOT_INGEST_PASSWORD:-${APP_PASSWORD}}"

if [ "${#APP_PASSWORD}" -lt 16 ]; then
    echo "SMARTPOT_DB_PASSWORD debe tener al menos 16 caracteres" >&2
    exit 1
fi

psql_super() {
    psql -v ON_ERROR_STOP=1 --no-psqlrc --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"
}

echo "SmartPot: aplicando el esquema en la base '$POSTGRES_DB'"
psql_super -f /opt/smartpot/schema.sql

echo "SmartPot: configurando roles diferenciados ('$APP_USER' transaccional y '$INGEST_USER' ingesta asíncrona)"
psql_super --set=app_user="$APP_USER" --set=app_password="$APP_PASSWORD" --set=ingest_user="$INGEST_USER" --set=ingest_password="$INGEST_PASSWORD" --set=app_db="$POSTGRES_DB" <<'SQL'
-- 1. Rol de la aplicación transaccional (synchronous_commit = on)
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
UNION ALL
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
\gexec

ALTER ROLE :"app_user" SET synchronous_commit = 'on';

-- 2. Rol de ingesta masiva de telemetría (synchronous_commit = off, commit_delay = 10ms)
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'ingest_user', :'ingest_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'ingest_user')
UNION ALL
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'ingest_user', :'ingest_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'ingest_user')
\gexec

ALTER ROLE :"ingest_user" SET synchronous_commit = 'off';
ALTER ROLE :"ingest_user" SET commit_delay = 10000;

-- Permisos DML para la API y rol transaccional
GRANT CONNECT ON DATABASE :"app_db" TO :"app_user", :"ingest_user";
GRANT USAGE ON SCHEMA public TO :"app_user", :"ingest_user";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app_user";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";

-- Permisos específicos para el rol de ingesta sobre telemetría
GRANT SELECT, INSERT ON TABLE readings TO :"ingest_user";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"ingest_user";

-- Ajustes de rendimiento del motor para carga mixta IoT y telemetría de alta frecuencia
ALTER SYSTEM SET shared_buffers = '256MB';
ALTER SYSTEM SET work_mem = '16MB';
ALTER SYSTEM SET effective_cache_size = '768MB';
ALTER SYSTEM SET wal_compression = 'zstd';
ALTER SYSTEM SET checkpoint_completion_target = '0.9';
ALTER SYSTEM SET random_page_cost = '1.1';
SELECT pg_reload_conf();
SQL

if [ "$(printf '%s' "${SMARTPOT_SEED_DEMO:-false}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
    echo "SmartPot: cargando datos demo (demo@smartpot.app / SmartPot2026)"
    psql_super -f /opt/smartpot/demo.sql
else
    echo "SmartPot: SMARTPOT_SEED_DEMO=false, la base queda vacía"
fi

echo "SmartPot: inicialización completa"
