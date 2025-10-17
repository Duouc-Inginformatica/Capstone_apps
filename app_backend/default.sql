-- --------------------------------------------------------
-- Host:                         127.0.0.1
-- Server version:               12.0.2-MariaDB - mariadb.org binary distribution
-- Server OS:                    Win64
-- HeidiSQL Version:             12.11.0.7065
-- --------------------------------------------------------

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET NAMES utf8 */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;


-- Dumping database structure for wayfindcl
CREATE DATABASE IF NOT EXISTS `wayfindcl` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci */;
USE `wayfindcl`;

-- Dumping structure for table wayfindcl.gtfs_feeds
CREATE TABLE IF NOT EXISTS `gtfs_feeds` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `source_url` varchar(500) NOT NULL,
  `feed_version` varchar(100) DEFAULT NULL,
  `downloaded_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=179 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- Data exporting was unselected.

-- Dumping structure for table wayfindcl.gtfs_routes
CREATE TABLE IF NOT EXISTS `gtfs_routes` (
  `route_id` varchar(64) NOT NULL,
  `feed_id` bigint(20) DEFAULT NULL,
  `short_name` varchar(64) DEFAULT NULL,
  `long_name` varchar(255) DEFAULT NULL,
  `type` int(11) DEFAULT NULL,
  `color` varchar(10) DEFAULT NULL,
  `text_color` varchar(10) DEFAULT NULL,
  PRIMARY KEY (`route_id`),
  KEY `feed_id` (`feed_id`),
  CONSTRAINT `gtfs_routes_ibfk_1` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- Data exporting was unselected.

-- Dumping structure for table wayfindcl.gtfs_stops
CREATE TABLE IF NOT EXISTS `gtfs_stops` (
  `stop_id` varchar(64) NOT NULL,
  `feed_id` bigint(20) DEFAULT NULL,
  `code` varchar(64) DEFAULT NULL,
  `name` varchar(255) NOT NULL,
  `description` varchar(255) DEFAULT NULL,
  `latitude` double NOT NULL,
  `longitude` double NOT NULL,
  `zone_id` varchar(64) DEFAULT NULL,
  `wheelchair_boarding` tinyint(4) NOT NULL DEFAULT 0,
  PRIMARY KEY (`stop_id`),
  KEY `fk_gtfs_stops_feed` (`feed_id`),
  KEY `idx_gtfs_stops_latlon` (`latitude`,`longitude`),
  CONSTRAINT `fk_gtfs_stops_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- Data exporting was unselected.

-- Dumping structure for table wayfindcl.gtfs_stop_times
CREATE TABLE IF NOT EXISTS `gtfs_stop_times` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `feed_id` bigint(20) DEFAULT NULL,
  `trip_id` varchar(64) NOT NULL,
  `arrival_time` varchar(10) DEFAULT NULL,
  `departure_time` varchar(10) DEFAULT NULL,
  `stop_id` varchar(64) NOT NULL,
  `stop_sequence` int(11) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `feed_id` (`feed_id`),
  KEY `idx_stop_times_stop` (`stop_id`),
  KEY `idx_stop_times_trip` (`trip_id`),
  KEY `idx_gtfs_stop_times_trip_id` (`trip_id`),
  KEY `idx_gtfs_stop_times_stop_id` (`stop_id`),
  KEY `idx_gtfs_stop_times_departure` (`departure_time`),
  CONSTRAINT `gtfs_stop_times_ibfk_1` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL,
  CONSTRAINT `gtfs_stop_times_ibfk_2` FOREIGN KEY (`trip_id`) REFERENCES `gtfs_trips` (`trip_id`) ON DELETE CASCADE,
  CONSTRAINT `gtfs_stop_times_ibfk_3` FOREIGN KEY (`stop_id`) REFERENCES `gtfs_stops` (`stop_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- Data exporting was unselected.

-- Dumping structure for table wayfindcl.gtfs_trips
CREATE TABLE IF NOT EXISTS `gtfs_trips` (
  `trip_id` varchar(64) NOT NULL,
  `feed_id` bigint(20) DEFAULT NULL,
  `route_id` varchar(64) NOT NULL,
  `service_id` varchar(64) DEFAULT NULL,
  `headsign` varchar(255) DEFAULT NULL,
  `direction_id` tinyint(4) DEFAULT NULL,
  `shape_id` varchar(64) DEFAULT NULL,
  PRIMARY KEY (`trip_id`),
  KEY `feed_id` (`feed_id`),
  KEY `idx_gtfs_trips_route_id` (`route_id`),
  KEY `idx_gtfs_trips_service_id` (`service_id`),
  CONSTRAINT `gtfs_trips_ibfk_1` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds` (`id`) ON DELETE SET NULL,
  CONSTRAINT `gtfs_trips_ibfk_2` FOREIGN KEY (`route_id`) REFERENCES `gtfs_routes` (`route_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- Data exporting was unselected.

-- Dumping structure for table wayfindcl.incidents
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
  KEY `idx_incidents_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- Data exporting was unselected.

-- Dumping structure for table wayfindcl.location_shares
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
  CONSTRAINT `fk_location_shares_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- Data exporting was unselected.

-- Dumping structure for table wayfindcl.notification_preferences
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

-- Data exporting was unselected.

-- Dumping structure for table wayfindcl.trip_history
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
  CONSTRAINT `fk_trip_history_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- Data exporting was unselected.

-- Dumping structure for table wayfindcl.users
CREATE TABLE IF NOT EXISTS `users` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `username` varchar(50) NOT NULL,
  `email` varchar(255) NOT NULL,
  `name` varchar(100) NOT NULL,
  `password_hash` varchar(255) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `username` (`username`),
  UNIQUE KEY `email` (`email`)
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

-- Data exporting was unselected.

/*!40103 SET TIME_ZONE=IFNULL(@OLD_TIME_ZONE, 'system') */;
/*!40101 SET SQL_MODE=IFNULL(@OLD_SQL_MODE, '') */;
/*!40014 SET FOREIGN_KEY_CHECKS=IFNULL(@OLD_FOREIGN_KEY_CHECKS, 1) */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40111 SET SQL_NOTES=IFNULL(@OLD_SQL_NOTES, 1) */;
