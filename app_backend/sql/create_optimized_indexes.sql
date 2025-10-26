-- ============================================================================
-- ÍNDICES OPTIMIZADOS - WayFindCL Backend
-- ============================================================================
-- Este script crea índices para mejorar el rendimiento de queries frecuentes
-- Ejecutar después de la importación inicial de datos GTFS
-- ============================================================================

-- ============================================================================
-- TABLA: users
-- ============================================================================
-- Índice para búsquedas por username (login frecuente)
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);

-- Índice para búsquedas por email
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- Índice para autenticación biométrica
CREATE INDEX IF NOT EXISTS idx_users_biometric_id ON users(biometric_id);

-- Índice compuesto para auth_type (distinguir entre password/biometric)
CREATE INDEX IF NOT EXISTS idx_users_auth_type ON users(auth_type);

-- ============================================================================
-- TABLA: gtfs_stops
-- ============================================================================
-- Índice espacial para búsquedas por latitud/longitud (ya existe, verificar)
CREATE INDEX IF NOT EXISTS idx_gtfs_stops_latlon ON gtfs_stops(latitude, longitude);

-- Índice para búsquedas por código de parada
CREATE INDEX IF NOT EXISTS idx_gtfs_stops_code ON gtfs_stops(code);

-- Índice para búsquedas por nombre
CREATE INDEX IF NOT EXISTS idx_gtfs_stops_name ON gtfs_stops(name);

-- Índice para accesibilidad en silla de ruedas
CREATE INDEX IF NOT EXISTS idx_gtfs_stops_wheelchair ON gtfs_stops(wheelchair_boarding);

-- ============================================================================
-- TABLA: gtfs_routes
-- ============================================================================
-- Índice para búsquedas por número de ruta (ej: "506", "426")
CREATE INDEX IF NOT EXISTS idx_gtfs_routes_short_name ON gtfs_routes(short_name);

-- Índice para búsquedas por tipo de transporte (bus, metro, etc.)
CREATE INDEX IF NOT EXISTS idx_gtfs_routes_type ON gtfs_routes(type);

-- Índice compuesto para búsquedas por feed
CREATE INDEX IF NOT EXISTS idx_gtfs_routes_feed_id ON gtfs_routes(feed_id);

-- ============================================================================
-- TABLA: gtfs_trips
-- ============================================================================
-- Índice para búsquedas por route_id (obtener todos los viajes de una ruta)
CREATE INDEX IF NOT EXISTS idx_gtfs_trips_route_id ON gtfs_trips(route_id);

-- Índice para búsquedas por service_id (días de operación)
CREATE INDEX IF NOT EXISTS idx_gtfs_trips_service_id ON gtfs_trips(service_id);

-- Índice compuesto para búsquedas eficientes de viajes por ruta y servicio
CREATE INDEX IF NOT EXISTS idx_gtfs_trips_route_service ON gtfs_trips(route_id, service_id);

-- ============================================================================
-- TABLA: gtfs_stop_times
-- ============================================================================
-- Índice para búsquedas por trip_id (obtener todas las paradas de un viaje)
CREATE INDEX IF NOT EXISTS idx_gtfs_stop_times_trip_id ON gtfs_stop_times(trip_id);

-- Índice para búsquedas por stop_id (obtener todos los horarios de una parada)
CREATE INDEX IF NOT EXISTS idx_gtfs_stop_times_stop_id ON gtfs_stop_times(stop_id);

-- Índice compuesto para búsquedas por parada y hora de salida (MUY IMPORTANTE)
-- Esto acelera queries como "próximos buses en esta parada"
CREATE INDEX IF NOT EXISTS idx_stop_times_stop_departure ON gtfs_stop_times(stop_id, departure_time);

-- Índice para búsquedas por hora de llegada
CREATE INDEX IF NOT EXISTS idx_stop_times_arrival ON gtfs_stop_times(arrival_time);

-- Índice para secuencia de paradas (ordenar paradas de un viaje)
CREATE INDEX IF NOT EXISTS idx_stop_times_sequence ON gtfs_stop_times(stop_sequence);

-- ============================================================================
-- TABLAS OPCIONALES (solo si existen)
-- ============================================================================
-- Estas tablas se crean solo si la aplicación las usa

-- gtfs_calendar (si existe)
SET @table_exists = (SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = DATABASE() AND table_name = 'gtfs_calendar');
SET @sql = IF(@table_exists > 0, 
    'CREATE INDEX IF NOT EXISTS idx_gtfs_calendar_service_id ON gtfs_calendar(service_id)', 
    'SELECT "Tabla gtfs_calendar no existe, índice omitido" AS info');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @sql = IF(@table_exists > 0, 
    'CREATE INDEX IF NOT EXISTS idx_gtfs_calendar_dates ON gtfs_calendar(start_date, end_date)', 
    'SELECT "Tabla gtfs_calendar no existe, índice omitido" AS info');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- incidents (si existe)
SET @table_exists = (SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = DATABASE() AND table_name = 'incidents');

-- Verificar columna created_at
SET @column_exists = (SELECT COUNT(*) FROM information_schema.columns 
    WHERE table_schema = DATABASE() AND table_name = 'incidents' AND column_name = 'created_at');
SET @sql = IF(@table_exists > 0 AND @column_exists > 0, 
    'CREATE INDEX IF NOT EXISTS idx_incidents_created_at ON incidents(created_at)', 
    'SELECT "Tabla incidents o columna created_at no existe, índice omitido" AS info');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- Verificar columna status
SET @column_exists = (SELECT COUNT(*) FROM information_schema.columns 
    WHERE table_schema = DATABASE() AND table_name = 'incidents' AND column_name = 'status');
SET @sql = IF(@table_exists > 0 AND @column_exists > 0, 
    'CREATE INDEX IF NOT EXISTS idx_incidents_status ON incidents(status)', 
    'SELECT "Tabla incidents o columna status no existe, índice omitido" AS info');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- Verificar columna incident_type
SET @column_exists = (SELECT COUNT(*) FROM information_schema.columns 
    WHERE table_schema = DATABASE() AND table_name = 'incidents' AND column_name = 'incident_type');
SET @sql = IF(@table_exists > 0 AND @column_exists > 0, 
    'CREATE INDEX IF NOT EXISTS idx_incidents_type ON incidents(incident_type)', 
    'SELECT "Tabla incidents o columna incident_type no existe, índice omitido" AS info');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- location_shares (si existe)
SET @table_exists = (SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = DATABASE() AND table_name = 'location_shares');

-- Verificar columna created_at
SET @column_exists = (SELECT COUNT(*) FROM information_schema.columns 
    WHERE table_schema = DATABASE() AND table_name = 'location_shares' AND column_name = 'created_at');
SET @sql = IF(@table_exists > 0 AND @column_exists > 0, 
    'CREATE INDEX IF NOT EXISTS idx_location_shares_created_at ON location_shares(created_at)', 
    'SELECT "Tabla location_shares o columna created_at no existe, índice omitido" AS info');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- Verificar columna expires_at
SET @column_exists = (SELECT COUNT(*) FROM information_schema.columns 
    WHERE table_schema = DATABASE() AND table_name = 'location_shares' AND column_name = 'expires_at');
SET @sql = IF(@table_exists > 0 AND @column_exists > 0, 
    'CREATE INDEX IF NOT EXISTS idx_location_shares_expires_at ON location_shares(expires_at)', 
    'SELECT "Tabla location_shares o columna expires_at no existe, índice omitido" AS info');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- trip_history (si existe)
SET @table_exists = (SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = DATABASE() AND table_name = 'trip_history');

-- Verificar columna user_id
SET @column_exists = (SELECT COUNT(*) FROM information_schema.columns 
    WHERE table_schema = DATABASE() AND table_name = 'trip_history' AND column_name = 'user_id');
SET @sql = IF(@table_exists > 0 AND @column_exists > 0, 
    'CREATE INDEX IF NOT EXISTS idx_trip_history_user_id ON trip_history(user_id)', 
    'SELECT "Tabla trip_history o columna user_id no existe, índice omitido" AS info');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- Verificar columna created_at
SET @column_exists = (SELECT COUNT(*) FROM information_schema.columns 
    WHERE table_schema = DATABASE() AND table_name = 'trip_history' AND column_name = 'created_at');
SET @sql = IF(@table_exists > 0 AND @column_exists > 0, 
    'CREATE INDEX IF NOT EXISTS idx_trip_history_created_at ON trip_history(created_at)', 
    'SELECT "Tabla trip_history o columna created_at no existe, índice omitido" AS info');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- ============================================================================
-- VERIFICACIÓN DE ÍNDICES CREADOS
-- ============================================================================
-- Para verificar los índices creados, ejecutar:
-- SHOW INDEX FROM users;
-- SHOW INDEX FROM gtfs_stops;
-- SHOW INDEX FROM gtfs_routes;
-- SHOW INDEX FROM gtfs_trips;
-- SHOW INDEX FROM gtfs_stop_times;
-- ============================================================================

-- ============================================================================
-- ESTADÍSTICAS DE TABLAS
-- ============================================================================
-- Actualizar estadísticas para el optimizador de consultas (solo tablas principales)
ANALYZE TABLE users;
ANALYZE TABLE gtfs_feeds;
ANALYZE TABLE gtfs_stops;
ANALYZE TABLE gtfs_routes;
ANALYZE TABLE gtfs_trips;
ANALYZE TABLE gtfs_stop_times;

-- ============================================================================
-- FIN DEL SCRIPT
-- ============================================================================
SELECT '✅ Índices optimizados creados exitosamente' AS resultado;
SELECT CONCAT('📊 Total de índices en users: ', COUNT(*)) AS info 
FROM information_schema.statistics 
WHERE table_schema = DATABASE() AND table_name = 'users';

SELECT CONCAT('📊 Total de índices en gtfs_stops: ', COUNT(*)) AS info 
FROM information_schema.statistics 
WHERE table_schema = DATABASE() AND table_name = 'gtfs_stops';

SELECT CONCAT('📊 Total de índices en gtfs_stop_times: ', COUNT(*)) AS info 
FROM information_schema.statistics 
WHERE table_schema = DATABASE() AND table_name = 'gtfs_stop_times';
