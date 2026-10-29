-- Esquema de SmartPot sobre PostgreSQL + TimescaleDB. Es la única definición del modelo de datos: lo usan el
-- inicio de una base nueva (init/01_init.sh) y la migración de una base existente (scripts/migrate.sh).
-- Es idempotente: se puede correr varias veces sin cambiar nada (CREATE ... IF NOT EXISTS).
--
-- Los identificadores son ObjectId hexadecimales de 24 caracteres generados por la API (CHAR(24)), para que los
-- ids expuestos a los demás componentes (URL, usuario MQTT por cultivo, JSON) no cambien respecto a la versión
-- anterior sobre MongoDB. Los subdocumentos ricos (lugar, dispositivo, salud, manual, destinatarios, eventos) se
-- guardan como JSONB; las variables de telemetría, en columnas tipadas para aprovechar TimescaleDB.

CREATE
EXTENSION IF NOT EXISTS timescaledb;

-- Cuentas de la plataforma.
CREATE TABLE IF NOT EXISTS users
(
    id
    CHAR
(
    24
) PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    last_name TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL CHECK
(
    role
    IN
(
    'USER',
    'ADMIN'
)),
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ
    );
CREATE UNIQUE INDEX IF NOT EXISTS users_email_key ON users (email);

-- Cultivos reales (con dispositivo) o virtuales (simulados). kind y form son fijos/editables según la API.
CREATE TABLE IF NOT EXISTS crops
(
    id
    CHAR
(
    24
) PRIMARY KEY,
    owner_id CHAR
(
    24
) NOT NULL,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK
(
    type
    IN
(
    'TOMATO',
    'LETTUCE',
    'STRAWBERRY',
    'BASIL',
    'SPINACH',
    'PEPPER'
)),
    kind TEXT CHECK
(
    kind
    IN
(
    'REAL',
    'VIRTUAL'
)),
    form TEXT CHECK
(
    form
    IN
(
    'POT',
    'NFT',
    'TOWER',
    'RAFT'
)),
    placement JSONB,
    automation_enabled BOOLEAN NOT NULL,
    device JSONB,
    health JSONB,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ
    );
CREATE INDEX IF NOT EXISTS crops_owner_created ON crops (owner_id, created_at DESC);
-- Para sincronizar en el broker las cuentas de los cultivos con clave de dispositivo al reconectar.
CREATE INDEX IF NOT EXISTS crops_with_device_key ON crops ((device ->> 'keyCiphertext')) WHERE device ->> 'keyCiphertext' IS NOT NULL;

-- Telemetría de los sensores: hipertabla de TimescaleDB particionada por tiempo. Cada variable es una columna
-- opcional (°C, % HR, lux, pH, ppm, hPa y % de humedad del sustrato).
CREATE TABLE IF NOT EXISTS readings
(
    id
    CHAR
(
    24
) NOT NULL,
    crop_id CHAR
(
    24
) NOT NULL,
    measured_at TIMESTAMPTZ NOT NULL,
    source TEXT CHECK
(
    source
    IN
(
    'MQTT',
    'HTTP'
)),
    temperature DOUBLE PRECISION,
    humidity DOUBLE PRECISION,
    brightness DOUBLE PRECISION,
    ph DOUBLE PRECISION,
    tds DOUBLE PRECISION,
    atmosphere DOUBLE PRECISION,
    soil_moisture DOUBLE PRECISION
    );
-- Hipertabla con fragmentos (chunks) de 7 días; la columna de partición es measured_at.
-- Argumentos posicionales a propósito (create_default_indexes, if_not_exists): evitan el operador `=>`,
-- que algunos formateadores de SQL parten en `= >` y rompen el arranque de la base.
SELECT create_hypertable('readings', by_range('measured_at', INTERVAL '7 days'), TRUE, TRUE);
CREATE INDEX IF NOT EXISTS readings_crop_measured ON readings (crop_id, measured_at DESC);
CREATE INDEX IF NOT EXISTS readings_crop_measured_covering ON readings (crop_id, measured_at DESC) INCLUDE (temperature, humidity, brightness, ph, tds, atmosphere, soil_moisture);
CREATE INDEX IF NOT EXISTS readings_measured_at_brin ON readings USING BRIN (measured_at);

-- Retención de 1 año: TimescaleDB descarta los fragmentos antiguos (equivale al índice TTL anterior).
-- Tercer argumento posicional = if_not_exists (ver nota de arriba sobre `=>`).
SELECT add_retention_policy('readings', INTERVAL '365 days', TRUE);

-- Compresión columnar nativa de TimescaleDB para fragmentos históricos mayores a 30 días.
-- Agrupa por cultivo y ordena por tiempo descendente para maximizar el ratio de compresión.
ALTER TABLE readings SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'crop_id',
    timescaledb.compress_orderby = 'measured_at DESC'
);
SELECT add_compression_policy('readings', INTERVAL '30 days', TRUE);

-- Vista materializada continua para acelerar consultas analíticas y series temporales sin escanear datos crudos.
CREATE MATERIALIZED VIEW IF NOT EXISTS readings_hourly
WITH (timescaledb.continuous) AS
SELECT crop_id,
       time_bucket('1 hour', measured_at) AS bucket,
       min(temperature) AS min_temperature,
       avg(temperature) AS avg_temperature,
       max(temperature) AS max_temperature,
       min(humidity) AS min_humidity,
       avg(humidity) AS avg_humidity,
       max(humidity) AS max_humidity,
       min(brightness) AS min_brightness,
       avg(brightness) AS avg_brightness,
       max(brightness) AS max_brightness,
       min(ph) AS min_ph,
       avg(ph) AS avg_ph,
       max(ph) AS max_ph,
       min(tds) AS min_tds,
       avg(tds) AS avg_tds,
       max(tds) AS max_tds,
       min(atmosphere) AS min_atmosphere,
       avg(atmosphere) AS avg_atmosphere,
       max(atmosphere) AS max_atmosphere,
       min(soil_moisture) AS min_soil_moisture,
       avg(soil_moisture) AS avg_soil_moisture,
       max(soil_moisture) AS max_soil_moisture,
       count(*) AS reading_count
FROM readings
GROUP BY crop_id, bucket
WITH NO DATA;

-- Política de refresco automático: refresca ventanas de 30 días a 1 hora hacia atrás.
SELECT add_continuous_aggregate_policy('readings_hourly',
    start_offset => INTERVAL '30 days',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour',
    if_not_exists => TRUE);

-- Salidas de cada cultivo (bomba, luz UV, ventilador, humidificador y dosificadores) y su estado confirmado.
CREATE TABLE IF NOT EXISTS actuators
(
    id
    CHAR
(
    24
) PRIMARY KEY,
    crop_id CHAR
(
    24
) NOT NULL,
    type TEXT NOT NULL CHECK
(
    type
    IN
(
    'WATER_PUMP',
    'UV_LIGHT',
    'FAN',
    'HUMIDIFIER',
    'NUTRIENT_DOSER',
    'PH_DOSER'
)),
    active BOOLEAN NOT NULL,
    running_until TIMESTAMPTZ,
    last_changed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL
    );
CREATE UNIQUE INDEX IF NOT EXISTS actuators_crop_type ON actuators (crop_id, type);

-- Órdenes a los actuadores con su ciclo de vida (PENDING -> SENT -> EXECUTED | FAILED | EXPIRED).
CREATE TABLE IF NOT EXISTS commands
(
    id
    CHAR
(
    24
) PRIMARY KEY,
    crop_id CHAR
(
    24
) NOT NULL,
    actuator_id CHAR
(
    24
) NOT NULL,
    actuator_type TEXT NOT NULL CHECK
(
    actuator_type
    IN
(
    'WATER_PUMP',
    'UV_LIGHT',
    'FAN',
    'HUMIDIFIER',
    'NUTRIENT_DOSER',
    'PH_DOSER'
)),
    action TEXT NOT NULL CHECK
(
    action
    IN
(
    'ACTIVATE',
    'DEACTIVATE'
)),
    duration_seconds INTEGER,
    status TEXT NOT NULL CHECK
(
    status
    IN
(
    'PENDING',
    'SENT',
    'EXECUTED',
    'FAILED',
    'EXPIRED'
)),
    source TEXT NOT NULL CHECK
(
    source
    IN
(
    'USER',
    'AGENT'
)),
    reason TEXT NOT NULL DEFAULT '',
    message TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL,
    sent_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ
    );
CREATE INDEX IF NOT EXISTS commands_crop_created ON commands (crop_id, created_at DESC);
CREATE INDEX IF NOT EXISTS commands_status_sent ON commands (status, sent_at);
CREATE INDEX IF NOT EXISTS commands_actuator_status ON commands (actuator_id, status);

-- Alertas del cultivo, del dispositivo y del asistente de IA que ve la PWA. crop_id es opcional.
CREATE TABLE IF NOT EXISTS notifications
(
    id
    CHAR
(
    24
) PRIMARY KEY,
    user_id CHAR
(
    24
) NOT NULL,
    crop_id CHAR
(
    24
),
    type TEXT NOT NULL CHECK
(
    type
    IN
(
    'INFO',
    'ALERT',
    'COMMAND',
    'DEVICE',
    'AI'
)),
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    read BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
    );
CREATE INDEX IF NOT EXISTS notifications_user_created ON notifications (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_crop_created ON notifications (crop_id, created_at) WHERE crop_id IS NOT NULL;

-- Tokens de recuperación de contraseña: solo el SHA-256 del token. La API los purga al vencer.
CREATE TABLE IF NOT EXISTS password_reset_tokens
(
    id
    CHAR
(
    24
) PRIMARY KEY,
    token_hash TEXT NOT NULL,
    user_id CHAR
(
    24
) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ
    );
CREATE UNIQUE INDEX IF NOT EXISTS password_reset_tokens_hash_key ON password_reset_tokens (token_hash);
CREATE INDEX IF NOT EXISTS password_reset_tokens_user ON password_reset_tokens (user_id);
CREATE INDEX IF NOT EXISTS password_reset_tokens_expires ON password_reset_tokens (expires_at);

-- Vínculo de una cuenta con un canal externo (hoy Telegram); address es el id del chat.
CREATE TABLE IF NOT EXISTS channel_links
(
    id
    CHAR
(
    24
) PRIMARY KEY,
    user_id CHAR
(
    24
) NOT NULL,
    type TEXT NOT NULL CHECK
(
    type
    IN
(
    'TELEGRAM'
)),
    address TEXT NOT NULL,
    display_name TEXT NOT NULL DEFAULT '',
    enabled BOOLEAN NOT NULL,
    events JSONB NOT NULL DEFAULT '[]'::jsonb,
    linked_at TIMESTAMPTZ,
    last_delivered_at TIMESTAMPTZ,
    failures INTEGER NOT NULL DEFAULT 0
    );
CREATE UNIQUE INDEX IF NOT EXISTS channel_links_user_type ON channel_links (user_id, type);
CREATE UNIQUE INDEX IF NOT EXISTS channel_links_type_address ON channel_links (type, address);

-- Avisos de un cultivo por un canal: qué avisa, al instante o en resumen, el resumen diario (HH:mm) y los chats
-- con los que se comparte (hasta 10, en recipients).
CREATE TABLE IF NOT EXISTS crop_channels
(
    id
    CHAR
(
    24
) PRIMARY KEY,
    crop_id CHAR
(
    24
) NOT NULL,
    owner_id CHAR
(
    24
) NOT NULL,
    type TEXT NOT NULL CHECK
(
    type
    IN
(
    'TELEGRAM'
)),
    enabled BOOLEAN NOT NULL,
    events JSONB NOT NULL DEFAULT '[]'::jsonb,
    delivery TEXT CHECK
(
    delivery
    IN
(
    'INSTANT',
    'DIGEST'
)),
    digest_hours INTEGER,
    daily_summary_at TEXT,
    recipients JSONB NOT NULL DEFAULT '[]'::jsonb,
    last_digest_at TIMESTAMPTZ,
    last_summary_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
    );
CREATE UNIQUE INDEX IF NOT EXISTS crop_channels_crop_type ON crop_channels (crop_id, type);
CREATE INDEX IF NOT EXISTS crop_channels_enabled ON crop_channels (enabled) WHERE enabled;

-- Simulación de un cultivo virtual: el simulador la recrea a partir de esta fila; active es false en pausa.
CREATE TABLE IF NOT EXISTS virtual_devices
(
    id
    CHAR
(
    24
) PRIMARY KEY,
    crop_id CHAR
(
    24
) NOT NULL,
    owner_id CHAR
(
    24
) NOT NULL,
    mode TEXT NOT NULL CHECK
(
    mode
    IN
(
    'AUTO',
    'MANUAL',
    'WEATHER'
)),
    manual JSONB,
    location JSONB,
    interval_seconds INTEGER NOT NULL,
    active BOOLEAN,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
    );
CREATE UNIQUE INDEX IF NOT EXISTS virtual_devices_crop ON virtual_devices (crop_id);
CREATE INDEX IF NOT EXISTS virtual_devices_owner ON virtual_devices (owner_id);
