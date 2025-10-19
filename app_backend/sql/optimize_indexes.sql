-- ============================================================================
-- OPTIMIZACIÓN DE ÍNDICES PARA GTFS
-- ============================================================================
-- Este script crea índices optimizados para mejorar el rendimiento
-- de las consultas de transporte público
-- ============================================================================

-- 1. Índice compuesto para búsquedas geográficas (MÁS IMPORTANTE)
-- Permite filtrar rápidamente por bounding box antes de calcular distancias
CREATE INDEX IF NOT EXISTS idx_gtfs_stops_location 
ON gtfs_stops(latitude, longitude);

-- 2. Índice para búsquedas por nombre de parada
CREATE INDEX IF NOT EXISTS idx_gtfs_stops_name 
ON gtfs_stops(name);

-- 3. Índice para búsquedas por código de parada
CREATE INDEX IF NOT EXISTS idx_gtfs_stops_code 
ON gtfs_stops(code);

-- 4. Índice para wheelchair_boarding (accesibilidad)
CREATE INDEX IF NOT EXISTS idx_gtfs_stops_wheelchair 
ON gtfs_stops(wheelchair_boarding);

-- 5. Índice para relación de paradas con trips
CREATE INDEX IF NOT EXISTS idx_gtfs_stop_times_stop_id 
ON gtfs_stop_times(stop_id);

CREATE INDEX IF NOT EXISTS idx_gtfs_stop_times_trip_id 
ON gtfs_stop_times(trip_id);

-- 6. Índice compuesto para búsquedas de secuencia de paradas
CREATE INDEX IF NOT EXISTS idx_gtfs_stop_times_trip_sequence 
ON gtfs_stop_times(trip_id, stop_sequence);

-- 7. Índice para rutas por route_id
CREATE INDEX IF NOT EXISTS idx_gtfs_trips_route_id 
ON gtfs_trips(route_id);

-- 8. Índice para rutas por route_short_name (búsquedas por número)
CREATE INDEX IF NOT EXISTS idx_gtfs_routes_short_name 
ON gtfs_routes(route_short_name);

-- 9. Índice para rutas por route_long_name (búsquedas por nombre completo)
CREATE INDEX IF NOT EXISTS idx_gtfs_routes_long_name 
ON gtfs_routes(route_long_name);

-- ============================================================================
-- ESTADÍSTICAS DE LA BASE DE DATOS
-- ============================================================================

-- Ver cuántas paradas hay en total
SELECT COUNT(*) as total_stops FROM gtfs_stops;

-- Ver distribución de paradas por zona
SELECT zone_id, COUNT(*) as count 
FROM gtfs_stops 
WHERE zone_id IS NOT NULL 
GROUP BY zone_id 
ORDER BY count DESC 
LIMIT 10;

-- Ver paradas con accesibilidad para sillas de ruedas
SELECT wheelchair_boarding, COUNT(*) as count 
FROM gtfs_stops 
GROUP BY wheelchair_boarding;

-- Ver rutas más comunes
SELECT route_short_name, route_long_name, COUNT(*) as trip_count
FROM gtfs_routes r
JOIN gtfs_trips t ON r.route_id = t.route_id
GROUP BY route_short_name, route_long_name
ORDER BY trip_count DESC
LIMIT 20;

-- ============================================================================
-- CONSULTA DE PRUEBA: Paradas cercanas
-- ============================================================================
-- Ejemplo: Buscar paradas cerca de Plaza de Armas (-33.4372, -70.6506)

SELECT 
    stop_id, 
    name, 
    latitude, 
    longitude,
    (6371000 * acos(
        LEAST(1.0, GREATEST(-1.0,
            cos(radians(-33.4372)) * cos(radians(latitude)) * 
            cos(radians(longitude) - radians(-70.6506)) + 
            sin(radians(-33.4372)) * sin(radians(latitude))
        ))
    )) AS distance_meters
FROM gtfs_stops
WHERE latitude BETWEEN -33.4472 AND -33.4272
  AND longitude BETWEEN -70.6606 AND -70.6406
HAVING distance_meters <= 500
ORDER BY distance_meters
LIMIT 20;

-- ============================================================================
-- MANTENIMIENTO
-- ============================================================================

-- Analizar tablas para actualizar estadísticas (mejora el query planner)
ANALYZE TABLE gtfs_stops;
ANALYZE TABLE gtfs_routes;
ANALYZE TABLE gtfs_trips;
ANALYZE TABLE gtfs_stop_times;

-- Ver tamaño de las tablas
SELECT 
    table_name,
    ROUND(((data_length + index_length) / 1024 / 1024), 2) AS 'Size (MB)'
FROM information_schema.TABLES
WHERE table_schema = DATABASE()
AND table_name LIKE 'gtfs_%'
ORDER BY (data_length + index_length) DESC;

-- Ver índices creados
SELECT 
    TABLE_NAME,
    INDEX_NAME,
    SEQ_IN_INDEX,
    COLUMN_NAME
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE()
AND TABLE_NAME LIKE 'gtfs_%'
ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX;
