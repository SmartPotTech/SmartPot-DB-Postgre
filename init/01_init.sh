#!/bin/sh
# Inicio de una base nueva: aplica el esquema, crea el usuario de la aplicación (readWrite solo sobre su base, sin
# permisos de DDL) y carga los datos demo si SMARTPOT_SEED_DEMO=true. Lo ejecuta el entrypoint de PostgreSQL una
# sola vez, con el servidor ya levantado por el socket local. Las definiciones viven en /opt/smartpot.
set -eu

APP_USER="${SMARTPOT_DB_USERNAME:-smartpot}"
APP_PASSWORD="${SMARTPOT_DB_PASSWORD:-}"

if [ "${#APP_PASSWORD}" -lt 16 ]; then
    echo "SMARTPOT_DB_PASSWORD debe tener al menos 16 caracteres" >&2
    exit 1
fi

psql_super() {
    psql -v ON_ERROR_STOP=1 --no-psqlrc --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"
}

echo "SmartPot: aplicando el esquema en la base '$POSTGRES_DB'"
psql_super -f /opt/smartpot/schema.sql

echo "SmartPot: creando el usuario de la aplicación '$APP_USER'"
psql_super --set=app_user="$APP_USER" --set=app_password="$APP_PASSWORD" --set=app_db="$POSTGRES_DB" <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') THEN
        EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password');
    ELSE
        EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password');
    END IF;
END
$$;

-- La API solo hace DML: lee y escribe datos, no modifica el esquema.
GRANT CONNECT ON DATABASE :"app_db" TO :"app_user";
GRANT USAGE ON SCHEMA public TO :"app_user";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app_user";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";
SQL

if [ "$(printf '%s' "${SMARTPOT_SEED_DEMO:-false}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
    echo "SmartPot: cargando datos demo (demo@smartpot.app / SmartPot2026)"
    psql_super -f /opt/smartpot/demo.sql
else
    echo "SmartPot: SMARTPOT_SEED_DEMO=false, la base queda vacía"
fi

echo "SmartPot: inicialización completa"
