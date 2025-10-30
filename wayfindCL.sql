-- --------------------------------------------------------
-- Host:                         127.0.0.1
-- Versión del servidor:         12.0.2-MariaDB - mariadb.org binary distribution
-- SO del servidor:              Win64
-- HeidiSQL Versión:             12.12.0.7122
-- --------------------------------------------------------

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET NAMES utf8 */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;


-- Volcando estructura de base de datos para wayfindcl
CREATE DATABASE IF NOT EXISTS `wayfindcl` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci */;
USE `wayfindcl`;

-- Volcando estructura para tabla wayfindcl.contributions
CREATE TABLE IF NOT EXISTS `contributions` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `user_id` bigint(20) DEFAULT NULL COMMENT 'Usuario que reporta (NULL para anónimo)',
  `type` varchar(50) NOT NULL COMMENT 'bus_status, route_issues, stop_info, general_suggestion',
  `category` varchar(50) DEFAULT NULL COMMENT 'delayed, crowded, broken, detour, suspension, new_stop, accessibility, etc.',
  `title` varchar(255) NOT NULL COMMENT 'Título del reporte',
  `description` text NOT NULL COMMENT 'Descripción detallada del problema',
  `latitude` double DEFAULT NULL COMMENT 'Ubicación del reporte',
  `longitude` double DEFAULT NULL COMMENT 'Ubicación del reporte',
  `bus_route` varchar(100) DEFAULT NULL COMMENT 'Ruta de bus afectada',
  `stop_name` varchar(255) DEFAULT NULL COMMENT 'Parada afectada',
  `delay_minutes` int(11) DEFAULT NULL COMMENT 'Minutos de retraso reportados',
  `severity` varchar(20) NOT NULL DEFAULT 'medium' COMMENT 'low, medium, high, critical',
  `status` varchar(20) NOT NULL DEFAULT 'pending' COMMENT 'pending, verified, rejected, resolved',
  `upvotes` int(11) NOT NULL DEFAULT 0,
  `downvotes` int(11) NOT NULL DEFAULT 0,
  `contact_email` varchar(255) DEFAULT NULL COMMENT 'Email de contacto (opcional)',
  `device_info` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL COMMENT 'Información del dispositivo' CHECK (json_valid(`device_info`)),
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_contributions_type` (`type`),
  KEY `idx_contributions_category` (`category`),
  KEY `idx_contributions_status` (`status`),
  KEY `idx_contributions_location` (`latitude`,`longitude`),
  KEY `idx_contributions_route` (`bus_route`),
  KEY `idx_contributions_created` (`created_at`),
  KEY `idx_contributions_user` (`user_id`),
  CONSTRAINT `fk_contributions_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.gtfs_feeds
-- ============================================================================
-- GTFS MEJORADO: BusMaps (12,107 paradas, 418 rutas, validado MobilityData)
-- Fuente: https://s3.transitpdf.com/files/uran/improved-gtfs-transantiago-metrodesantiago.zip
-- Vigencia: 2 Ago 2025 - 31 Dic 2025
-- ============================================================================
CREATE TABLE IF NOT EXISTS `gtfs_feeds` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `source_url` varchar(500) NOT NULL COMMENT 'URL del feed GTFS',
  `feed_version` varchar(100) DEFAULT NULL COMMENT 'Versión del feed (de feed_info.txt)',
  `feed_publisher_name` varchar(255) DEFAULT NULL COMMENT 'Nombre del publicador',
  `feed_publisher_url` varchar(500) DEFAULT NULL COMMENT 'URL del publicador',
  `feed_lang` varchar(10) DEFAULT NULL COMMENT 'Idioma del feed (ISO 639-1)',
  `feed_start_date` date DEFAULT NULL COMMENT 'Fecha inicio de vigencia',
  `feed_end_date` date DEFAULT NULL COMMENT 'Fecha fin de vigencia',
  `downloaded_at` timestamp NOT NULL DEFAULT current_timestamp() COMMENT 'Fecha de descarga',
  `import_status` varchar(20) DEFAULT 'pending' COMMENT 'pending, importing, completed, failed',
  `stops_imported` int(11) DEFAULT 0 COMMENT 'Contador de paradas importadas',
  `routes_imported` int(11) DEFAULT 0 COMMENT 'Contador de rutas importadas',
  `trips_imported` int(11) DEFAULT 0 COMMENT 'Contador de viajes importados',
  `shapes_imported` int(11) DEFAULT 0 COMMENT 'Contador de shapes importados',
  PRIMARY KEY (`id`),
  KEY `idx_gtfs_feeds_version` (`feed_version`),
  KEY `idx_gtfs_feeds_status` (`import_status`),
  KEY `idx_gtfs_feeds_dates` (`feed_start_date`, `feed_end_date`)
) ENGINE=InnoDB AUTO_INCREMENT=147 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Metadatos de feeds GTFS importados';

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.gtfs_routes
CREATE TABLE IF NOT EXISTS `gtfs_routes` (
  `route_id` varchar(64) NOT NULL,
  `feed_id` bigint(20) DEFAULT NULL,
  `agency_id` varchar(64) DEFAULT NULL COMMENT 'ID de la agencia operadora',
  `short_name` varchar(64) DEFAULT NULL COMMENT 'Nombre corto (ej: 506, D05)',
  `long_name` varchar(255) DEFAULT NULL COMMENT 'Nombre completo de la ruta',
  `description` text DEFAULT NULL COMMENT 'Descripción de la ruta',
  `type` int(11) DEFAULT NULL COMMENT '0=Tranvía, 1=Metro, 2=Tren, 3=Bus, 4=Ferry',
  `url` varchar(500) DEFAULT NULL COMMENT 'URL con info de la ruta',
  `color` varchar(10) DEFAULT NULL COMMENT 'Color hexadecimal (sin #)',
  `text_color` varchar(10) DEFAULT NULL COMMENT 'Color del texto hexadecimal',
  PRIMARY KEY (`route_id`),
  KEY `feed_id` (`feed_id`),
  KEY `idx_gtfs_routes_short_name` (`short_name`),
  KEY `idx_gtfs_routes_type` (`type`),
  KEY `idx_gtfs_routes_feed_id` (`feed_id`),
  KEY `idx_gtfs_routes_agency` (`agency_id`),
  CONSTRAINT `gtfs_routes_ibfk_1` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Rutas de transporte público (418 rutas con BusMaps)';

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.gtfs_stops
CREATE TABLE IF NOT EXISTS `gtfs_stops` (
  `stop_id` varchar(64) NOT NULL,
  `feed_id` bigint(20) DEFAULT NULL,
  `code` varchar(64) DEFAULT NULL COMMENT 'Código de parada (ej: PA1234)',
  `name` varchar(255) NOT NULL COMMENT 'Nombre de la parada',
  `description` varchar(500) DEFAULT NULL COMMENT 'Descripción adicional',
  `latitude` double NOT NULL COMMENT 'Latitud WGS84',
  `longitude` double NOT NULL COMMENT 'Longitud WGS84',
  `zone_id` varchar(64) DEFAULT NULL COMMENT 'Zona tarifaria',
  `url` varchar(500) DEFAULT NULL COMMENT 'URL con info de la parada',
  `location_type` tinyint(4) DEFAULT 0 COMMENT '0=Stop, 1=Station, 2=Entrance/Exit',
  `parent_station` varchar(64) DEFAULT NULL COMMENT 'ID de estación padre',
  `wheelchair_boarding` tinyint(4) NOT NULL DEFAULT 0 COMMENT '0=Sin info, 1=Accesible, 2=No accesible',
  `platform_code` varchar(50) DEFAULT NULL COMMENT 'Código de andén',
  PRIMARY KEY (`stop_id`),
  KEY `fk_gtfs_stops_feed` (`feed_id`),
  KEY `idx_gtfs_stops_latlon` (`latitude`,`longitude`),
  KEY `idx_gtfs_stops_code` (`code`),
  KEY `idx_gtfs_stops_name` (`name`),
  KEY `idx_gtfs_stops_wheelchair` (`wheelchair_boarding`),
  KEY `idx_gtfs_stops_location_type` (`location_type`),
  KEY `idx_gtfs_stops_parent` (`parent_station`),
  CONSTRAINT `fk_gtfs_stops_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Paradas de transporte (12,107 paradas con BusMaps)';

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.gtfs_stop_times
CREATE TABLE IF NOT EXISTS `gtfs_stop_times` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `feed_id` bigint(20) DEFAULT NULL,
  `trip_id` varchar(64) NOT NULL COMMENT 'Referencia a gtfs_trips',
  `arrival_time` varchar(10) DEFAULT NULL COMMENT 'Hora de llegada (HH:MM:SS)',
  `departure_time` varchar(10) DEFAULT NULL COMMENT 'Hora de salida (HH:MM:SS)',
  `stop_id` varchar(64) NOT NULL COMMENT 'Referencia a gtfs_stops',
  `stop_sequence` int(11) NOT NULL COMMENT 'Orden de la parada en el viaje',
  `stop_headsign` varchar(255) DEFAULT NULL COMMENT 'Destino mostrado en la parada',
  `pickup_type` tinyint(4) DEFAULT 0 COMMENT '0=Regular, 1=No disponible, 2=Llamar, 3=Coordinar',
  `drop_off_type` tinyint(4) DEFAULT 0 COMMENT '0=Regular, 1=No disponible, 2=Llamar, 3=Coordinar',
  `shape_dist_traveled` float DEFAULT NULL COMMENT 'Distancia desde inicio de shape',
  `timepoint` tinyint(4) DEFAULT 1 COMMENT '0=Aproximado, 1=Exacto',
  PRIMARY KEY (`id`),
  KEY `idx_gtfs_stop_times_feed` (`feed_id`),
  KEY `idx_gtfs_stop_times_trip` (`trip_id`),
  KEY `idx_gtfs_stop_times_stop` (`stop_id`),
  KEY `idx_gtfs_stop_times_departure` (`departure_time`),
  KEY `idx_gtfs_stop_times_trip_id` (`trip_id`),
  KEY `idx_gtfs_stop_times_stop_id` (`stop_id`),
  KEY `idx_stop_times_stop_departure` (`stop_id`,`departure_time`),
  KEY `idx_stop_times_arrival` (`arrival_time`),
  KEY `idx_stop_times_sequence` (`stop_sequence`),
  KEY `idx_stop_times_trip_sequence` (`trip_id`, `stop_sequence`),
  CONSTRAINT `fk_gtfs_stop_times_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_gtfs_stop_times_stop` FOREIGN KEY (`stop_id`) REFERENCES `gtfs_stops` (`stop_id`) ON DELETE CASCADE,
  CONSTRAINT `fk_gtfs_stop_times_trip` FOREIGN KEY (`trip_id`) REFERENCES `gtfs_trips` (`trip_id`) ON DELETE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=5664968 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Horarios de paradas (~1M+ registros con BusMaps)';

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.gtfs_trips
CREATE TABLE IF NOT EXISTS `gtfs_trips` (
  `trip_id` varchar(64) NOT NULL,
  `feed_id` bigint(20) DEFAULT NULL,
  `route_id` varchar(64) NOT NULL COMMENT 'Referencia a gtfs_routes',
  `service_id` varchar(64) DEFAULT NULL COMMENT 'ID del servicio (calendario)',
  `headsign` varchar(255) DEFAULT NULL COMMENT 'Destino mostrado en el bus',
  `short_name` varchar(100) DEFAULT NULL COMMENT 'Nombre corto del viaje',
  `direction_id` tinyint(4) DEFAULT NULL COMMENT '0=Ida, 1=Vuelta',
  `block_id` varchar(64) DEFAULT NULL COMMENT 'ID del bloque de viajes',
  `shape_id` varchar(64) DEFAULT NULL COMMENT 'Referencia a gtfs_shapes (geometría)',
  `wheelchair_accessible` tinyint(4) DEFAULT 0 COMMENT '0=Sin info, 1=Accesible, 2=No accesible',
  `bikes_allowed` tinyint(4) DEFAULT 0 COMMENT '0=Sin info, 1=Permitido, 2=No permitido',
  PRIMARY KEY (`trip_id`),
  KEY `idx_gtfs_trips_feed` (`feed_id`),
  KEY `idx_gtfs_trips_route` (`route_id`),
  KEY `idx_gtfs_trips_service` (`service_id`),
  KEY `idx_gtfs_trips_route_id` (`route_id`),
  KEY `idx_gtfs_trips_service_id` (`service_id`),
  KEY `idx_gtfs_trips_route_service` (`route_id`,`service_id`),
  KEY `idx_gtfs_trips_shape` (`shape_id`),
  KEY `idx_gtfs_trips_direction` (`direction_id`),
  CONSTRAINT `fk_gtfs_trips_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_gtfs_trips_route` FOREIGN KEY (`route_id`) REFERENCES `gtfs_routes` (`route_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci COMMENT='Viajes de transporte (BusMaps: >90% con shape_id)';

-- La exportación de datos fue deseleccionada.

-- ============================================================================
-- NUEVAS TABLAS PARA GTFS MEJORADO (BusMaps)
-- ============================================================================

-- Volcando estructura para tabla wayfindcl.gtfs_agencies
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

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.gtfs_shapes
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

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.gtfs_calendar
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

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.gtfs_calendar_dates
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

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.gtfs_frequencies
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

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.gtfs_transfers
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

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.incidents
CREATE TABLE IF NOT EXISTS `incidents` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `type` varchar(50) NOT NULL COMMENT 'bus_full, bus_delayed, bus_not_running, stop_out_of_service, stop_damaged, unsafe_area, accessibility, other',
  `latitude` double NOT NULL,
  `longitude` double NOT NULL,
  `severity` varchar(20) NOT NULL DEFAULT 'medium' COMMENT 'low, medium, high, critical',
  `reporter_id` varchar(100) DEFAULT NULL COMMENT 'User ID or "anonymous"',
  `route_name` varchar(100) DEFAULT NULL COMMENT 'Nombre de ruta afectada',
  `stop_name` varchar(255) DEFAULT NULL COMMENT 'Nombre de parada afectada',
  `description` text DEFAULT NULL,
  `is_verified` tinyint(1) NOT NULL DEFAULT 0,
  `upvotes` int(11) NOT NULL DEFAULT 0,
  `downvotes` int(11) NOT NULL DEFAULT 0,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_incidents_type` (`type`),
  KEY `idx_incidents_severity` (`severity`),
  KEY `idx_incidents_location` (`latitude`,`longitude`),
  KEY `idx_incidents_route` (`route_name`),
  KEY `idx_incidents_created` (`created_at`),
  KEY `idx_incidents_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.location_shares
CREATE TABLE IF NOT EXISTS `location_shares` (
  `id` varchar(64) NOT NULL COMMENT 'UUID',
  `user_id` bigint(20) NOT NULL,
  `latitude` double NOT NULL,
  `longitude` double NOT NULL,
  `recipient_name` varchar(100) DEFAULT NULL,
  `message` text DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `expires_at` timestamp NOT NULL,
  `is_active` tinyint(1) NOT NULL DEFAULT 1,
  `last_updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_location_shares_user` (`user_id`),
  KEY `idx_location_shares_expires` (`expires_at`),
  KEY `idx_location_shares_active` (`is_active`,`expires_at`),
  KEY `idx_location_shares_created_at` (`created_at`),
  KEY `idx_location_shares_expires_at` (`expires_at`),
  CONSTRAINT `fk_location_shares_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.notification_preferences
CREATE TABLE IF NOT EXISTS `notification_preferences` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `user_id` bigint(20) NOT NULL,
  `approaching_distance` double NOT NULL DEFAULT 300 COMMENT 'Metros para "acercándose"',
  `near_distance` double NOT NULL DEFAULT 100 COMMENT 'Metros para "cerca"',
  `very_near_distance` double NOT NULL DEFAULT 30 COMMENT 'Metros para "muy cerca"',
  `enable_audio` tinyint(1) NOT NULL DEFAULT 1,
  `enable_vibration` tinyint(1) NOT NULL DEFAULT 1,
  `enable_visual` tinyint(1) NOT NULL DEFAULT 1,
  `audio_volume` double NOT NULL DEFAULT 0.8 COMMENT '0.0 a 1.0',
  `vibration_intensity` double NOT NULL DEFAULT 0.7 COMMENT '0.0 a 1.0',
  `minimum_priority` varchar(20) NOT NULL DEFAULT 'medium' COMMENT 'low, medium, high, critical',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `user_id` (`user_id`),
  CONSTRAINT `fk_notification_prefs_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.trip_history
CREATE TABLE IF NOT EXISTS `trip_history` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `user_id` bigint(20) NOT NULL,
  `origin_lat` double NOT NULL,
  `origin_lon` double NOT NULL,
  `destination_lat` double NOT NULL,
  `destination_lon` double NOT NULL,
  `destination_name` varchar(255) NOT NULL,
  `distance_meters` double NOT NULL,
  `duration_seconds` int(11) NOT NULL,
  `bus_route` varchar(100) DEFAULT NULL,
  `route_geometry` text DEFAULT NULL COMMENT 'JSON encoded geometry',
  `started_at` timestamp NOT NULL,
  `completed_at` timestamp NULL DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_trip_history_user` (`user_id`),
  KEY `idx_trip_history_destination` (`destination_name`),
  KEY `idx_trip_history_completed` (`completed_at`),
  KEY `idx_trip_history_started` (`started_at`),
  KEY `idx_trip_history_user_id` (`user_id`),
  KEY `idx_trip_history_created_at` (`created_at`),
  CONSTRAINT `fk_trip_history_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- La exportación de datos fue deseleccionada.

-- Volcando estructura para tabla wayfindcl.users
CREATE TABLE IF NOT EXISTS `users` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `username` varchar(50) NOT NULL,
  `email` varchar(255) DEFAULT NULL,
  `name` varchar(100) NOT NULL,
  `password_hash` varchar(255) DEFAULT NULL COMMENT 'Hash bcrypt del password - NULL para usuarios biométricos',
  `biometric_id` varchar(64) DEFAULT NULL COMMENT 'SHA-256 hash del dispositivo para autenticación biométrica',
  `auth_type` varchar(20) NOT NULL DEFAULT 'password' COMMENT 'Tipo de autenticación: password o biometric',
  `device_info` varchar(255) DEFAULT NULL COMMENT 'Información del dispositivo para usuarios biométricos',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `last_login` timestamp NULL DEFAULT NULL COMMENT 'Último inicio de sesión del usuario',
  PRIMARY KEY (`id`),
  UNIQUE KEY `username` (`username`),
  UNIQUE KEY `email` (`email`),
  UNIQUE KEY `idx_biometric_id` (`biometric_id`),
  KEY `idx_auth_type` (`auth_type`),
  KEY `idx_users_username` (`username`),
  KEY `idx_users_email` (`email`),
  KEY `idx_users_biometric_id` (`biometric_id`),
  KEY `idx_users_auth_type` (`auth_type`)
) ENGINE=InnoDB AUTO_INCREMENT=4 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- La exportación de datos fue deseleccionada.

/*!40103 SET TIME_ZONE=IFNULL(@OLD_TIME_ZONE, 'system') */;
/*!40101 SET SQL_MODE=IFNULL(@OLD_SQL_MODE, '') */;
/*!40014 SET FOREIGN_KEY_CHECKS=IFNULL(@OLD_FOREIGN_KEY_CHECKS, 1) */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40111 SET SQL_NOTES=IFNULL(@OLD_SQL_NOTES, 1) */;
