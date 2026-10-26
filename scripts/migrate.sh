#!/bin/sh
# Aplica el esquema (schema/schema.sql) a una base existente, que ya no ejecuta los scripts de inicio. Es
# idempotente: se puede correr después de cada actualización de la imagen para sumar tablas, índices o políticas
# nuevas sin tocar los datos.
#   docker exec smartpot-db-postgre /opt/smartpot/migrate.sh
# Se conecta por el socket local con la cuenta administradora del contenedor (POSTGRES_USER), que es la dueña del
# esquema; la clave no aparece en la línea de comandos.
set -eu

echo "SmartPot: aplicando el esquema en la base '${POSTGRES_DB:-smartpot}'"
psql -v ON_ERROR_STOP=1 --no-psqlrc \
    --username "${POSTGRES_USER:-postgres}" \
    --dbname "${POSTGRES_DB:-smartpot}" \
    -f /opt/smartpot/schema.sql

echo "SmartPot: esquema al día"
