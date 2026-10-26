# SmartPot-DB-Postgre

Base de datos de SmartPot sobre **PostgreSQL 17 + TimescaleDB**. Sustituye a la base documental anterior
(MongoDB, `SmartPot-DB`) manteniendo el mismo contrato de datos de cara al resto de la plataforma: los
identificadores siguen siendo ObjectId hexadecimales de 24 caracteres y los nombres que ven los demás componentes
(a través de la API) no cambian. La telemetría vive en una **hipertabla de TimescaleDB**, pensada para la
ingesta continua de lecturas de sensores.

La imagen trae el esquema, el usuario de la aplicación y, opcionalmente, datos de demostración. Solo la **API**
(`SmartPot-API-Go`) se conecta a esta base; para los demás servicios la migración es transparente.

## Modelo de datos

Diez tablas, todas con identificadores `CHAR(24)` generados por la API:

| Tabla                   | Contenido                                                                   |
|-------------------------|-----------------------------------------------------------------------------|
| `users`                 | Cuentas de la plataforma (correo único, hash BCrypt, rol).                  |
| `crops`                 | Cultivos reales o virtuales. `placement`, `device` y `health` como `JSONB`. |
| `readings`              | **Hipertabla**: telemetría de sensores. Una columna tipada por variable.    |
| `actuators`             | Salidas de cada cultivo (bomba, luz UV, ventilador, etc.) y su estado.      |
| `commands`              | Órdenes a los actuadores y su ciclo de vida.                                |
| `notifications`         | Alertas de la PWA (cuenta y cultivo).                                       |
| `password_reset_tokens` | Solo el SHA-256 del token de recuperación.                                  |
| `channel_links`         | Vínculo de una cuenta con un canal externo (Telegram).                      |
| `crop_channels`         | Avisos de un cultivo por un canal; `recipients` como `JSONB`.               |
| `virtual_devices`       | Configuración de simulación de un cultivo virtual.                          |

### Por qué PostgreSQL + TimescaleDB

- **Relacional tipado** para las entidades de negocio, con restricciones `CHECK` que reemplazan a los validadores
  `$jsonSchema` de la versión anterior, e índices únicos (correo, cultivo+tipo de actuador, etc.).
- **JSONB** para los subdocumentos ricos y opcionales (lugar, dispositivo, salud, destinatarios, eventos), sin
  perder la flexibilidad del modelo documental.
- **TimescaleDB** para `readings`: la tabla se particiona por tiempo en fragmentos de 7 días (`create_hypertable`)
  y una **política de retención** de 1 año descarta los fragmentos antiguos (equivale al índice TTL anterior). Las
  consultas de series temporales usan `time_bucket`, el equivalente nativo de `$dateTrunc`.

El esquema completo está en [`schema/schema.sql`](schema/schema.sql): es la única definición del modelo y es
idempotente.

## Seguridad

- La cuenta administradora (`POSTGRES_USER`) es la dueña del esquema y **no la usa la API**.
- El usuario de la aplicación (`SMARTPOT_DB_USERNAME`, por defecto `smartpot`) solo tiene permisos de **DML**
  (`SELECT`, `INSERT`, `UPDATE`, `DELETE`) sobre su base; no puede modificar el esquema ni administrar usuarios.
- La imagen corre endurecida (`read_only`, `cap_drop: ALL`, `no-new-privileges`), igual que el resto del stack.

## Variables de entorno

Copia `.env.example` a `.env` y complétalo. `SMARTPOT_DB_PASSWORD` debe tener al menos 16 caracteres.

| Variable                                        | Uso                                                                                         |
|-------------------------------------------------|---------------------------------------------------------------------------------------------|
| `POSTGRES_USER` / `POSTGRES_PASSWORD`           | Cuenta administradora (dueña del esquema).                                                  |
| `POSTGRES_DB`                                   | Base de la aplicación (por defecto `smartpot`).                                             |
| `SMARTPOT_DB_USERNAME` / `SMARTPOT_DB_PASSWORD` | Usuario de la aplicación (solo DML).                                                        |
| `SMARTPOT_SEED_DEMO`                            | `true` carga `demo@smartpot.app` con dos cultivos y 48 h de lecturas. Solo en local o demo. |

## Uso

```sh
cp .env.example .env     # completa las contraseñas
docker compose up -d --build
```

La API se conecta con una URL de PostgreSQL, por ejemplo:

```
postgres://smartpot:<APP_PASSWORD>@db-smartpot:5432/smartpot?sslmode=disable
```

## Migración de una base existente

El esquema es idempotente. Tras actualizar la imagen, aplica las tablas, índices o políticas nuevas sin tocar los
datos:

```sh
docker exec smartpot-db-postgre /opt/smartpot/migrate.sh
```

## Pruebas

`tests/validate.sh` arranca la imagen endurecida y valida el esquema, la hipertabla, la retención, los permisos del
usuario de la aplicación, las restricciones `CHECK`, la migración idempotente y los datos demo:

```sh
sh tests/validate.sh smartpot-db-postgre:ci true
```

Lo mismo corre en CI al construir la imagen (con y sin datos demo).

## Publicación y despliegue

Cada push a `main` construye y publica la imagen en GHCR (`ghcr.io/smartpottech/smartpot-db-postgre`) y, con los
secretos de Docker Hub, su réplica. El despliegue a producción lo coordina el workflow central de `.github`.

## Licencia

[MIT](LICENSE).
