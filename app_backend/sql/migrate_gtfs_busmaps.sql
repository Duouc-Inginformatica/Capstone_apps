-- ============================================================================
-- MIGRACIÓN A GTFS MEJORADO DE BUSMAPS
-- ============================================================================
-- Propósito: Actualizar schema de BD para soportar GTFS mejorado
-- Fuente: https://s3.transitpdf.com/files/uran/improved-gtfs-transantiago-metrodesantiago.zip
-- Fecha: 30 Oct 2025
-- ============================================================================

USE wayfindcl;

-- ============================================================================
-- 1. ACTUALIZAR TABLA gtfs_feeds (agregar nuevos campos)
-- ============================================================================
ALTER TABLE `gtfs_feeds`
  ADD COLUMN `feed_publisher_name` varchar(255) DEFAULT NULL COMMENT 'Nombre del publicador' AFTER `feed_version`,
  ADD COLUMN `feed_publisher_url` varchar(500) DEFAULT NULL COMMENT 'URL del publicador' AFTER `feed_publisher_name`,
  ADD COLUMN `feed_lang` varchar(10) DEFAULT NULL COMMENT 'Idioma del feed (ISO 639-1)' AFTER `feed_publisher_url`,
  ADD COLUMN `feed_start_date` date DEFAULT NULL COMMENT 'Fecha inicio de vigencia' AFTER `feed_lang`,
  ADD COLUMN `feed_end_date` date DEFAULT NULL COMMENT 'Fecha fin de vigencia' AFTER `feed_start_date`,
  ADD COLUMN `import_status` varchar(20) DEFAULT 'pending' COMMENT 'pending, importing, completed, failed' AFTER `downloaded_at`,
  ADD COLUMN `stops_imported` int(11) DEFAULT 0 COMMENT 'Contador de paradas importadas' AFTER `import_status`,
  ADD COLUMN `routes_imported` int(11) DEFAULT 0 COMMENT 'Contador de rutas importadas' AFTER `stops_imported`,
  ADD COLUMN `trips_imported` int(11) DEFAULT 0 COMMENT 'Contador de viajes importados' AFTER `routes_imported`,
  ADD COLUMN `shapes_imported` int(11) DEFAULT 0 COMMENT 'Contador de shapes importados' AFTER `trips_imported`;

ALTER TABLE `gtfs_feeds`
  ADD KEY `idx_gtfs_feeds_version` (`feed_version`),
  ADD KEY `idx_gtfs_feeds_status` (`import_status`),
  ADD KEY `idx_gtfs_feeds_dates` (`feed_start_date`, `feed_end_date`);

-- ============================================================================
-- 2. ACTUALIZAR TABLA gtfs_routes (agregar campos adicionales)
-- ============================================================================
ALTER TABLE `gtfs_routes`
  ADD COLUMN `agency_id` varchar(64) DEFAULT NULL COMMENT 'ID de la agencia operadora' AFTER `feed_id`,
  ADD COLUMN `description` text DEFAULT NULL COMMENT 'Descripción de la ruta' AFTER `long_name`,
  ADD COLUMN `url` varchar(500) DEFAULT NULL COMMENT 'URL con info de la ruta' AFTER `type`;

ALTER TABLE `gtfs_routes`
  ADD KEY `idx_gtfs_routes_agency` (`agency_id`);

-- ============================================================================
-- 3. ACTUALIZAR TABLA gtfs_stops (agregar campos GTFS completos)
-- ============================================================================
ALTER TABLE `gtfs_stops`
  MODIFY COLUMN `description` varchar(500) DEFAULT NULL COMMENT 'Descripción adicional',
  ADD COLUMN `url` varchar(500) DEFAULT NULL COMMENT 'URL con info de la parada' AFTER `zone_id`,
  ADD COLUMN `location_type` tinyint(4) DEFAULT 0 COMMENT '0=Stop, 1=Station, 2=Entrance/Exit' AFTER `url`,
  ADD COLUMN `parent_station` varchar(64) DEFAULT NULL COMMENT 'ID de estación padre' AFTER `location_type`,
  ADD COLUMN `platform_code` varchar(50) DEFAULT NULL COMMENT 'Código de andén' AFTER `wheelchair_boarding`;

ALTER TABLE `gtfs_stops`
  ADD KEY `idx_gtfs_stops_location_type` (`location_type`),
  ADD KEY `idx_gtfs_stops_parent` (`parent_station`);

-- ============================================================================
-- 4. ACTUALIZAR TABLA gtfs_trips (agregar campos adicionales)
-- ============================================================================
ALTER TABLE `gtfs_trips`
  ADD COLUMN `short_name` varchar(100) DEFAULT NULL COMMENT 'Nombre corto del viaje' AFTER `headsign`,
  ADD COLUMN `block_id` varchar(64) DEFAULT NULL COMMENT 'ID del bloque de viajes' AFTER `direction_id`,
  ADD COLUMN `wheelchair_accessible` tinyint(4) DEFAULT 0 COMMENT '0=Sin info, 1=Accesible, 2=No accesible' AFTER `shape_id`,
  ADD COLUMN `bikes_allowed` tinyint(4) DEFAULT 0 COMMENT '0=Sin info, 1=Permitido, 2=No permitido' AFTER `wheelchair_accessible`;

ALTER TABLE `gtfs_trips`
  ADD KEY `idx_gtfs_trips_shape` (`shape_id`),
  ADD KEY `idx_gtfs_trips_direction` (`direction_id`);

-- ============================================================================
-- 5. ACTUALIZAR TABLA gtfs_stop_times (agregar campos adicionales)
-- ============================================================================
ALTER TABLE `gtfs_stop_times`
  ADD COLUMN `stop_headsign` varchar(255) DEFAULT NULL COMMENT 'Destino mostrado en la parada' AFTER `stop_sequence`,
  ADD COLUMN `pickup_type` tinyint(4) DEFAULT 0 COMMENT '0=Regular, 1=No disponible, 2=Llamar, 3=Coordinar' AFTER `stop_headsign`,
  ADD COLUMN `drop_off_type` tinyint(4) DEFAULT 0 COMMENT '0=Regular, 1=No disponible, 2=Llamar, 3=Coordinar' AFTER `pickup_type`,
  ADD COLUMN `shape_dist_traveled` float DEFAULT NULL COMMENT 'Distancia desde inicio de shape' AFTER `drop_off_type`,
  ADD COLUMN `timepoint` tinyint(4) DEFAULT 1 COMMENT '0=Aproximado, 1=Exacto' AFTER `shape_dist_traveled`;

ALTER TABLE `gtfs_stop_times`
  ADD KEY `idx_stop_times_trip_sequence` (`trip_id`, `stop_sequence`);

-- ============================================================================
-- 6. CREAR NUEVA TABLA gtfs_agencies
-- ============================================================================
CREATE TABLE IF NOT EXISTS `gtfs_agencies` (
  `agency_id` varchar(64) NOT NULL,
  `feed_id` bigint(20) DEFAULT NULL,
  `agency_name` varchar(255) NOT NULL COMMENT 'Nombre de la agencia',
  `agency_url` varchar(500) NOT NULL COMMENT 'URL de la agencia',
  `agency_timezone` varchar(50) NOT NULL COMMENT 'Zona horaria (America/Santiago)',
  `agency_lang` varchar(10) DEFAULT NULL COMMENT 'Idioma principal',
  `agency_phone` varchar(50) DEFAULT NULL COMMENT 'Teléfono de contacto',
  `agency_fare_url` varchar(500) DEFAULT NULL COMMENT 'URL de información tarifaria',
  `agency_email` varchar(255) DEFAULT NULL COMMENT 'Email de contacto',
  PRIMARY KEY (`agency_id`),
  KEY `idx_gtfs_agencies_feed` (`feed_id`),
  KEY `idx_gtfs_agencies_name` (`agency_name`),
  CONSTRAINT `fk_gtfs_agencies_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Agencias operadoras (4 con BusMaps)';

-- ============================================================================
-- 7. CREAR NUEVA TABLA gtfs_shapes (CRÍTICO PARA BUSMAPS)
-- ============================================================================
CREATE TABLE IF NOT EXISTS `gtfs_shapes` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `feed_id` bigint(20) DEFAULT NULL,
  `shape_id` varchar(64) NOT NULL COMMENT 'ID del shape (geometría)',
  `shape_pt_lat` double NOT NULL COMMENT 'Latitud del punto',
  `shape_pt_lon` double NOT NULL COMMENT 'Longitud del punto',
  `shape_pt_sequence` int(11) NOT NULL COMMENT 'Orden del punto en el shape',
  `shape_dist_traveled` float DEFAULT NULL COMMENT 'Distancia acumulada desde inicio',
  PRIMARY KEY (`id`),
  KEY `idx_gtfs_shapes_feed` (`feed_id`),
  KEY `idx_gtfs_shapes_id` (`shape_id`),
  KEY `idx_gtfs_shapes_sequence` (`shape_id`, `shape_pt_sequence`),
  KEY `idx_gtfs_shapes_latlon` (`shape_pt_lat`, `shape_pt_lon`),
  CONSTRAINT `fk_gtfs_shapes_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Geometrías de rutas (MEJORADO en BusMaps: >90% cobertura)';

-- ============================================================================
-- 8. CREAR NUEVA TABLA gtfs_calendar
-- ============================================================================
CREATE TABLE IF NOT EXISTS `gtfs_calendar` (
  `service_id` varchar(64) NOT NULL,
  `feed_id` bigint(20) DEFAULT NULL,
  `monday` tinyint(1) NOT NULL DEFAULT 0 COMMENT '1=Servicio opera los lunes',
  `tuesday` tinyint(1) NOT NULL DEFAULT 0,
  `wednesday` tinyint(1) NOT NULL DEFAULT 0,
  `thursday` tinyint(1) NOT NULL DEFAULT 0,
  `friday` tinyint(1) NOT NULL DEFAULT 0,
  `saturday` tinyint(1) NOT NULL DEFAULT 0,
  `sunday` tinyint(1) NOT NULL DEFAULT 0,
  `start_date` date NOT NULL COMMENT 'Fecha inicio del servicio',
  `end_date` date NOT NULL COMMENT 'Fecha fin del servicio',
  PRIMARY KEY (`service_id`),
  KEY `idx_gtfs_calendar_feed` (`feed_id`),
  KEY `idx_gtfs_calendar_dates` (`start_date`, `end_date`),
  CONSTRAINT `fk_gtfs_calendar_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Calendario regular de servicios';

-- ============================================================================
-- 9. CREAR NUEVA TABLA gtfs_calendar_dates
-- ============================================================================
CREATE TABLE IF NOT EXISTS `gtfs_calendar_dates` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `service_id` varchar(64) NOT NULL,
  `feed_id` bigint(20) DEFAULT NULL,
  `date` date NOT NULL COMMENT 'Fecha de la excepción',
  `exception_type` tinyint(4) NOT NULL COMMENT '1=Servicio agregado, 2=Servicio removido',
  PRIMARY KEY (`id`),
  KEY `idx_gtfs_calendar_dates_feed` (`feed_id`),
  KEY `idx_gtfs_calendar_dates_service` (`service_id`),
  KEY `idx_gtfs_calendar_dates_date` (`date`),
  UNIQUE KEY `unique_service_date` (`service_id`, `date`),
  CONSTRAINT `fk_gtfs_calendar_dates_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Excepciones al calendario (feriados, eventos especiales)';

-- ============================================================================
-- 10. CREAR NUEVA TABLA gtfs_frequencies
-- ============================================================================
CREATE TABLE IF NOT EXISTS `gtfs_frequencies` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `trip_id` varchar(64) NOT NULL,
  `feed_id` bigint(20) DEFAULT NULL,
  `start_time` varchar(10) NOT NULL COMMENT 'Hora de inicio del periodo',
  `end_time` varchar(10) NOT NULL COMMENT 'Hora de fin del periodo',
  `headway_secs` int(11) NOT NULL COMMENT 'Frecuencia en segundos',
  `exact_times` tinyint(4) DEFAULT 0 COMMENT '0=Frecuencia, 1=Horarios exactos',
  PRIMARY KEY (`id`),
  KEY `idx_gtfs_frequencies_feed` (`feed_id`),
  KEY `idx_gtfs_frequencies_trip` (`trip_id`),
  KEY `idx_gtfs_frequencies_times` (`start_time`, `end_time`),
  CONSTRAINT `fk_gtfs_frequencies_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_gtfs_frequencies_trip` FOREIGN KEY (`trip_id`) REFERENCES `gtfs_trips` (`trip_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Frecuencias de servicio (headway-based trips)';

-- ============================================================================
-- 11. CREAR NUEVA TABLA gtfs_transfers
-- ============================================================================
CREATE TABLE IF NOT EXISTS `gtfs_transfers` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `feed_id` bigint(20) DEFAULT NULL,
  `from_stop_id` varchar(64) NOT NULL COMMENT 'Parada origen del transbordo',
  `to_stop_id` varchar(64) NOT NULL COMMENT 'Parada destino del transbordo',
  `transfer_type` tinyint(4) NOT NULL DEFAULT 0 COMMENT '0=Recomendado, 1=Tiempo, 2=Mínimo, 3=No posible',
  `min_transfer_time` int(11) DEFAULT NULL COMMENT 'Tiempo mínimo en segundos',
  PRIMARY KEY (`id`),
  KEY `idx_gtfs_transfers_feed` (`feed_id`),
  KEY `idx_gtfs_transfers_from` (`from_stop_id`),
  KEY `idx_gtfs_transfers_to` (`to_stop_id`),
  CONSTRAINT `fk_gtfs_transfers_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_gtfs_transfers_from` FOREIGN KEY (`from_stop_id`) REFERENCES `gtfs_stops` (`stop_id`) ON DELETE CASCADE,
  CONSTRAINT `fk_gtfs_transfers_to` FOREIGN KEY (`to_stop_id`) REFERENCES `gtfs_stops` (`stop_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Transbordos entre paradas';

-- ============================================================================
-- 12. VERIFICAR MIGRACIÓN
-- ============================================================================
SELECT 
    'Migración completada' as status,
    (SELECT COUNT(*) FROM information_schema.TABLES 
     WHERE TABLE_SCHEMA = 'wayfindcl' 
     AND TABLE_NAME LIKE 'gtfs_%') as total_tablas_gtfs,
    (SELECT COUNT(*) FROM information_schema.COLUMNS 
     WHERE TABLE_SCHEMA = 'wayfindcl' 
     AND TABLE_NAME = 'gtfs_feeds') as columnas_gtfs_feeds,
    (SELECT COUNT(*) FROM information_schema.COLUMNS 
     WHERE TABLE_SCHEMA = 'wayfindcl' 
     AND TABLE_NAME = 'gtfs_shapes') as columnas_gtfs_shapes;

-- Mostrar nuevas tablas
SHOW TABLES LIKE 'gtfs_%';

SELECT '✅ Schema actualizado para GTFS mejorado de BusMaps' as mensaje;
SELECT '📝 Siguiente paso: Reiniciar backend para importar datos nuevos' as siguiente_paso;
