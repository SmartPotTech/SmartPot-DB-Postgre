#!/bin/sh
# Arranca la imagen endurecida y valida el esquema, la hipertabla, los permisos del usuario de la aplicación, las
# restricciones (CHECK), la migración idempotente y los datos demo.
#   sh tests/validate.sh <imagen> <true|false>
set -eu

IMAGE="${1:-smartpot-db-postgre:ci}"
DEMO="${2:-false}"
NAME="smartpot-db-postgre-validate"
APP_PASS="app-password-ci-1234"
ROOT_PASS="root-password-ci-123"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name "$NAME" \
  --read-only --tmpfs /tmp --tmpfs /run/postgresql \
  --cap-drop ALL --security-opt no-new-privileges \
  -e POSTGRES_USER=smartpot-root -e POSTGRES_PASSWORD="$ROOT_PASS" -e POSTGRES_DB=smartpot \
  -e SMARTPOT_DB_USERNAME=smartpot -e SMARTPOT_DB_PASSWORD="$APP_PASS" -e SMARTPOT_SEED_DEMO="$DEMO" \
  "$IMAGE" >/dev/null

# Las consultas de la aplicación usan el usuario smartpot; las de administración, la cuenta root del contenedor.
app() { docker exec -e PGPASSWORD="$APP_PASS" "$NAME" psql -tA -v ON_ERROR_STOP=1 -U smartpot -d smartpot -c "$1"; }
root() { docker exec "$NAME" psql -tA -v ON_ERROR_STOP=1 -U smartpot-root -d smartpot -c "$1"; }
migrate() { docker exec "$NAME" /opt/smartpot/migrate.sh; }

# Se espera a que el servidor acepte conexiones y a que el usuario de la aplicación exista (fin del init).
ok=0
for _ in $(seq 1 90); do
  if docker exec -e PGPASSWORD="$APP_PASS" "$NAME" psql -tA -U smartpot -d smartpot -c "SELECT 1" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ "$ok" = "1" ] || { echo "FAIL el usuario de la aplicación no pudo conectarse"; docker logs "$NAME" | tail -40; exit 1; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1 (esperado $3, obtenido $2)"; fail=1; fi; }

check "diez tablas" "$(app "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'")" "10"
check "readings es una hipertabla de TimescaleDB" \
  "$(app "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_name='readings'")" "1"
check "readings tiene política de retención" \
  "$(app "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_retention' AND hypertable_name='readings'")" "1"

check "el usuario de la app escribe en su base" \
  "$(app "INSERT INTO users (id, email, password_hash, role, created_at) VALUES ('0000000000000000000000ci','ci@example.com',repeat('x',60),'USER',now()) RETURNING 'ok'")" "ok"
check "el usuario de la app no crea tablas (sin DDL)" \
  "$(app 'CREATE TABLE ci_denied (id int)' 2>&1 >/dev/null | grep -qi 'permi\|denied\|permission' && echo denegado || echo permitido)" "denegado"

check "el CHECK rechaza un rol inválido" \
  "$(app "INSERT INTO users (id,email,password_hash,role,created_at) VALUES ('0000000000000000000000r1','r1@x.co',repeat('x',60),'ROOT',now())" 2>&1 >/dev/null | grep -qi 'check\|violates' && echo rechazado || echo aceptado)" "rechazado"
check "el CHECK rechaza un modo de simulación desconocido" \
  "$(app "INSERT INTO virtual_devices (id,crop_id,owner_id,mode,interval_seconds,created_at,updated_at) VALUES ('0000000000000000000000v1','c','o','RANDOM',30,now(),now())" 2>&1 >/dev/null | grep -qi 'check\|violates' && echo rechazado || echo aceptado)" "rechazado"
check "el CHECK rechaza un resumen diario con hora inválida no aplica (texto libre), pero sí un delivery inválido" \
  "$(app "INSERT INTO crop_channels (id,crop_id,owner_id,type,enabled,delivery) VALUES ('0000000000000000000000d1','c','o','TELEGRAM',true,'HOURLY')" 2>&1 >/dev/null | grep -qi 'check\|violates' && echo rechazado || echo aceptado)" "rechazado"
check "la restricción única por cultivo y tipo de actuador" \
  "$(app "INSERT INTO actuators (id,crop_id,type,active,created_at) VALUES ('0000000000000000000000a1','cropci','FAN',false,now()),('0000000000000000000000a2','cropci','FAN',false,now())" 2>&1 >/dev/null | grep -qi 'duplicate\|unique\|violates' && echo rechazado || echo aceptado)" "rechazado"

migrate >/dev/null
check "la migración es idempotente (segunda corrida sin error)" "$(migrate >/dev/null 2>&1 && echo ok || echo err)" "ok"

if [ "$DEMO" = "true" ]; then
  check "cuenta demo" "$(app "SELECT count(*) FROM users WHERE email='demo@smartpot.app'")" "1"
  check "cultivos demo" "$(app "SELECT count(*) FROM crops")" "2"
  check "cultivos demo al aire libre en Medellín" \
    "$(app "SELECT count(*) FROM crops WHERE placement->>'setting'='OUTDOOR' AND placement->'location'->>'name'='Medellín'")" "2"
  check "48 h de lecturas por cultivo (576)" "$(app "SELECT count(*) FROM readings")" "576"
else
  check "sin cultivos" "$(app "SELECT count(*) FROM crops")" "0"
fi

[ "$fail" -eq 0 ] || docker logs "$NAME" | tail -30
exit "$fail"
