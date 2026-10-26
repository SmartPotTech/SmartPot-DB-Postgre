-- Datos de demostración: solo con SMARTPOT_SEED_DEMO=true. Nunca en una base productiva.
-- Cuenta demo@smartpot.app / SmartPot2026 con dos cultivos reales en Medellín y 48 h de lecturas (cada 10 min).
-- Los ids son fijos para que el simulador (SIMULATOR_DEVICES) publique por MQTT como el dispositivo de cada cultivo.

-- Cuenta demo (contraseña SmartPot2026, BCrypt coste 12).
INSERT INTO users (id, name, last_name, email, password_hash, role, created_at, updated_at)
VALUES ('66f5a1000000000000000001', 'Ana', 'Demo', 'demo@smartpot.app',
        '$2a$12$/ndyKLiS20yVdLYjL3bEF.wGnZWIpD6ehw3AAsZw4aBRGTnPh5/UC', 'USER',
        now() - interval '72 hours', now() - interval '72 hours') ON CONFLICT (id) DO NOTHING;

-- Dos cultivos al aire libre en Medellín: la lechuga (NFT) en media sombra y automática, el tomate (maceta) a
-- pleno sol. Las claves de dispositivo están cifradas con la clave AES de demostración (SMARTPOT_AES_KEY del
-- entorno demo): descifran a demo-lettuce-device-key-2026 y demo-tomato-device-key-2026.
INSERT INTO crops (id, owner_id, name, type, kind, form, placement, automation_enabled, device, created_at, updated_at)
VALUES ('66f5a1000000000000000101', '66f5a1000000000000000001', 'Lechugas del balcón', 'LETTUCE', 'REAL', 'NFT',
        jsonb_build_object('setting', 'OUTDOOR', 'exposure', 'PARTIAL_SUN',
                           'location',
                           jsonb_build_object('name', 'Medellín', 'latitude', 6.2442, 'longitude', -75.5812)),
        true,
        jsonb_build_object('keyCiphertext',
                           'dZoM-zwvWcnt7AeNAc525CnuHS_1gO24GfT1ueMeUsotqk5UG6ZdKeD8vaZFpL3RMbLAJ_FIREg',
                           'keyRotatedAt',
                           to_char((now() - interval '72 hours') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                           'online', false,
                           'lastSeenAt',
                           to_char((now() - interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
        now() - interval '72 hours', now() - interval '72 hours'),
       ('66f5a1000000000000000102', '66f5a1000000000000000001', 'Tomates cherry', 'TOMATO', 'REAL', 'POT',
        jsonb_build_object('setting', 'OUTDOOR', 'exposure', 'FULL_SUN',
                           'location',
                           jsonb_build_object('name', 'Medellín', 'latitude', 6.2442, 'longitude', -75.5812)),
        false,
        jsonb_build_object('keyCiphertext',
                           '_NGpODcRRCGaJBGeHGquaU0Zpkup3YI-P-v4Ux9eRFPMs6kSiDNCx5Q4uWTWQ0Uds5rqGDnaxA',
                           'keyRotatedAt',
                           to_char((now() - interval '72 hours') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                           'online', false,
                           'lastSeenAt',
                           to_char((now() - interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
        now() - interval '72 hours', now() - interval '72 hours') ON CONFLICT (id) DO NOTHING;

-- Tres actuadores por cultivo (bomba, luz UV, ventilador), apagados.
INSERT INTO actuators (id, crop_id, type, active, created_at)
VALUES ('66f5a1000000000000001001', '66f5a1000000000000000101', 'WATER_PUMP', false, now() - interval '72 hours'),
       ('66f5a1000000000000001002', '66f5a1000000000000000101', 'UV_LIGHT', false, now() - interval '72 hours'),
       ('66f5a1000000000000001003', '66f5a1000000000000000101', 'FAN', false, now() - interval '72 hours'),
       ('66f5a1000000000000002001', '66f5a1000000000000000102', 'WATER_PUMP', false, now() - interval '72 hours'),
       ('66f5a1000000000000002002', '66f5a1000000000000000102', 'UV_LIGHT', false, now() - interval '72 hours'),
       ('66f5a1000000000000002003', '66f5a1000000000000000102', 'FAN', false,
        now() - interval '72 hours') ON CONFLICT (id) DO NOTHING;

-- 48 horas de lecturas cada 10 minutos (288 por cultivo) con ciclo día/noche y ruido suave. El ciclo alcanza su
-- máximo a las 17:00 UTC, mediodía en Colombia (UTC-5).
WITH base(crop_id, t, h, b, p, tds, soil) AS (VALUES (CAST('66f5a1000000000000000101' AS CHAR(24)), 19.0, 62.0, 850.0,
                                                      6.0, 700.0, 70.0),
                                                     (CAST('66f5a1000000000000000102' AS CHAR(24)), 25.0, 68.0, 1300.0,
                                                      6.2, 2000.0, 64.0)),
     calc AS (SELECT base.crop_id,
                     s.step,
                     now() - (s.step * interval '10 minutes') AS measured_at,
                     sin(((extract(hour FROM (now() - (s.step * interval '10 minutes')) AT TIME ZONE 'UTC') - 11) /
                          24.0) * 2 * pi()) AS day, base.t, base.h, base.b, base.p, base.tds, base.soil
FROM base, generate_series(1, 288) AS s(step)
    )
INSERT
INTO readings (id, crop_id, measured_at, source, temperature, humidity, brightness, ph, tds, atmosphere, soil_moisture)
SELECT substr(md5(random()::text || measured_at::text || step::text), 1, 24),
       crop_id,
       measured_at,
       'MQTT',
       round((t + day * 3 + (random() - 0.5)):: numeric, 1),
       round((h - day * 6 + (random() - 0.5) * 2):: numeric, 1),
       greatest(0, round(b * greatest(0.05, day + 0.3) + (random() - 0.5) * 40)),
       round((p + (random() - 0.5) * 0.15 + step / 2880.0):: numeric, 2),
       round((tds - step * 0.4 + (random() - 0.5) * 20):: numeric, 0),
       round((1012 + (random() - 0.5) * 3):: numeric, 1),
       round((soil - (step % 72) / 6.0 + (random() - 0.5)):: numeric, 1)
FROM calc;

-- Dos órdenes ya ejecutadas sobre la bomba de la lechuga (una del agente, otra del usuario).
INSERT INTO commands (id, crop_id, actuator_id, actuator_type, action, duration_seconds, status, source, reason,
                      message, created_at, sent_at, completed_at)
VALUES ('66f5a1000000000000003001', '66f5a1000000000000000101', '66f5a1000000000000001001', 'WATER_PUMP', 'ACTIVATE',
        15,
        'EXECUTED', 'AGENT', 'El sustrato está seco: riego automático.', 'Bomba encendida 15 s',
        now() - interval '5 hours', now() - interval '5 hours', now() - interval '5 hours'),
       ('66f5a1000000000000003002', '66f5a1000000000000000101', '66f5a1000000000000001001', 'WATER_PUMP', 'ACTIVATE',
        30,
        'EXECUTED', 'USER', '', 'Bomba encendida 30 s',
        now() - interval '20 hours', now() - interval '20 hours',
        now() - interval '20 hours') ON CONFLICT (id) DO NOTHING;

-- Dos notificaciones (bienvenida y una acción del asistente de IA).
INSERT INTO notifications (id, user_id, crop_id, type, title, message, read, created_at)
VALUES ('66f5a1000000000000004001', '66f5a1000000000000000001', NULL, 'INFO', '¡Bienvenido a SmartPot!',
        'Crea tu primer cultivo, real o virtual, para empezar a monitorearlo.', true, now() - interval '72 hours'),
       ('66f5a1000000000000004002', '66f5a1000000000000000001', '66f5a1000000000000000101', 'AI',
        'El asistente actuó en Lechugas del balcón', 'El sustrato está seco: riego automático.', false,
        now() - interval '5 hours') ON CONFLICT (id) DO NOTHING;
