-- WayFindCL default schema
-- Compatible con MySQL 5.7+/8.0 y MariaDB 10.3+

-- 1) Crear base de datos (ajusta collation/charset si necesitas)
CREATE DATABASE IF NOT EXISTS `wayfindcl`
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_unicode_ci;

USE `wayfindcl`;

-- 2) Tabla de usuarios
CREATE TABLE IF NOT EXISTS `users` (
  `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
  `username` VARCHAR(50) NOT NULL UNIQUE,
  `email` VARCHAR(255) NOT NULL UNIQUE,
  `name` VARCHAR(100) NOT NULL,
  `password_hash` VARCHAR(255) NOT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 3) GTFS: Feeds importados y paradas.
CREATE TABLE IF NOT EXISTS `gtfs_feeds` (
  `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
  `source_url` VARCHAR(500) NOT NULL,
  `feed_version` VARCHAR(100) NULL,
  `downloaded_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `gtfs_stops` (
  `stop_id` VARCHAR(64) PRIMARY KEY,
  `feed_id` BIGINT NULL,
  `code` VARCHAR(64) NULL,
  `name` VARCHAR(255) NOT NULL,
  `description` VARCHAR(255) NULL,
  `latitude` DOUBLE NOT NULL,
  `longitude` DOUBLE NOT NULL,
  `zone_id` VARCHAR(64) NULL,
  `wheelchair_boarding` TINYINT NOT NULL DEFAULT 0,
  CONSTRAINT `fk_gtfs_stops_feed` FOREIGN KEY (`feed_id`) REFERENCES `gtfs_feeds`(`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Crear índice geoespacial por separado (opcional, se puede omitir si hay problemas de permisos)
-- CREATE INDEX IF NOT EXISTS `idx_gtfs_stops_latlon` ON `gtfs_stops`(`latitude`, `longitude`);

-- 4) Usuario de aplicación (opcional)
-- Reemplaza 'app_user' y 'Strong#Pass2025' por tus valores.
-- Descomenta si quieres crear el usuario y darle permisos a esta DB.
-- Para MySQL 8 con plugin moderno:
-- CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED WITH caching_sha2_password BY 'Strong#Pass2025';
-- Para MySQL/MariaDB legacy (o si el driver lo requiere):
-- CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED WITH mysql_native_password BY 'Strong#Pass2025';
-- GRANT ALL PRIVILEGES ON `wayfindcl`.* TO 'app_user'@'%';
-- FLUSH PRIVILEGES;

-- 5) Usuario demo (opcional)
-- Inserta un usuario demo con hash calculado previamente.
-- El hash corresponde a la contraseña "demo1234" usando bcrypt con cost por defecto.
-- Nota: cambia el hash si vas a usar otra contraseña.
INSERT INTO `users` (`username`, `email`, `name`, `password_hash`)
SELECT 'demo', 'demo@example.com', 'Demo', '$2a$10$uRZxQ7E7G6k3oO9dDg2s6u6uT2vQH1C8s7l5B4tXnqk1t4q9m4m8K'
WHERE NOT EXISTS (SELECT 1 FROM `users` WHERE `username` = 'demo');

-- 6) Datos GTFS iniciales
-- Ejecuta el comando del backend `go run ./cmd/cli --gtfs-sync` (o el job programado) para descargar
-- el feed público DTPM, llenar `gtfs_feeds` y `gtfs_stops`, y mantener los índices actualizados.

-- 7) Tabla de incidentes reportados por la comunidad
CREATE TABLE IF NOT EXISTS `incidents` (
  `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
  `type` VARCHAR(50) NOT NULL COMMENT 'bus_full, bus_delayed, bus_not_running, stop_out_of_service, stop_damaged, unsafe_area, accessibility, other',
  `latitude` DOUBLE NOT NULL,
  `longitude` DOUBLE NOT NULL,
  `severity` VARCHAR(20) NOT NULL DEFAULT 'medium' COMMENT 'low, medium, high, critical',
  `reporter_id` VARCHAR(100) NULL COMMENT 'User ID or "anonymous"',
  `route_name` VARCHAR(100) NULL COMMENT 'Nombre de ruta afectada',
  `stop_name` VARCHAR(255) NULL COMMENT 'Nombre de parada afectada',
  `description` TEXT NULL,
  `is_verified` BOOLEAN NOT NULL DEFAULT FALSE,
  `upvotes` INT NOT NULL DEFAULT 0,
  `downvotes` INT NOT NULL DEFAULT 0,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX `idx_incidents_type` (`type`),
  INDEX `idx_incidents_severity` (`severity`),
  INDEX `idx_incidents_location` (`latitude`, `longitude`),
  INDEX `idx_incidents_route` (`route_name`),
  INDEX `idx_incidents_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 8) Tabla para compartir ubicación en tiempo real
CREATE TABLE IF NOT EXISTS `location_shares` (
  `id` VARCHAR(64) PRIMARY KEY COMMENT 'UUID',
  `user_id` BIGINT NOT NULL,
  `latitude` DOUBLE NOT NULL,
  `longitude` DOUBLE NOT NULL,
  `recipient_name` VARCHAR(100) NULL,
  `message` TEXT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `expires_at` TIMESTAMP NOT NULL,
  `is_active` BOOLEAN NOT NULL DEFAULT TRUE,
  `last_updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX `idx_location_shares_user` (`user_id`),
  INDEX `idx_location_shares_expires` (`expires_at`),
  INDEX `idx_location_shares_active` (`is_active`, `expires_at`),
  CONSTRAINT `fk_location_shares_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 9) Historial de viajes del usuario
CREATE TABLE IF NOT EXISTS `trip_history` (
  `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NOT NULL,
  `origin_lat` DOUBLE NOT NULL,
  `origin_lon` DOUBLE NOT NULL,
  `destination_lat` DOUBLE NOT NULL,
  `destination_lon` DOUBLE NOT NULL,
  `destination_name` VARCHAR(255) NOT NULL,
  `distance_meters` DOUBLE NOT NULL,
  `duration_seconds` INT NOT NULL,
  `bus_route` VARCHAR(100) NULL,
  `route_geometry` TEXT NULL COMMENT 'JSON encoded geometry',
  `started_at` TIMESTAMP NOT NULL,
  `completed_at` TIMESTAMP NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX `idx_trip_history_user` (`user_id`),
  INDEX `idx_trip_history_destination` (`destination_name`),
  INDEX `idx_trip_history_completed` (`completed_at`),
  INDEX `idx_trip_history_started` (`started_at`),
  CONSTRAINT `fk_trip_history_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 10) Preferencias de notificaciones del usuario
CREATE TABLE IF NOT EXISTS `notification_preferences` (
  `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NOT NULL UNIQUE,
  `approaching_distance` DOUBLE NOT NULL DEFAULT 300 COMMENT 'Metros para "acercándose"',
  `near_distance` DOUBLE NOT NULL DEFAULT 100 COMMENT 'Metros para "cerca"',
  `very_near_distance` DOUBLE NOT NULL DEFAULT 30 COMMENT 'Metros para "muy cerca"',
  `enable_audio` BOOLEAN NOT NULL DEFAULT TRUE,
  `enable_vibration` BOOLEAN NOT NULL DEFAULT TRUE,
  `enable_visual` BOOLEAN NOT NULL DEFAULT TRUE,
  `audio_volume` DOUBLE NOT NULL DEFAULT 0.8 COMMENT '0.0 a 1.0',
  `vibration_intensity` DOUBLE NOT NULL DEFAULT 0.7 COMMENT '0.0 a 1.0',
  `minimum_priority` VARCHAR(20) NOT NULL DEFAULT 'medium' COMMENT 'low, medium, high, critical',
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT `fk_notification_prefs_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 11) Tabla de contribuciones de la comunidad
CREATE TABLE IF NOT EXISTS `contributions` (
  `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
  `user_id` BIGINT NULL COMMENT 'Usuario que reporta (NULL para anónimo)',
  `type` VARCHAR(50) NOT NULL COMMENT 'bus_status, route_issues, stop_info, general_suggestion',
  `category` VARCHAR(50) NULL COMMENT 'delayed, crowded, broken, detour, suspension, new_stop, accessibility, etc.',
  `title` VARCHAR(255) NOT NULL COMMENT 'Título del reporte',
  `description` TEXT NOT NULL COMMENT 'Descripción detallada del problema',
  `latitude` DOUBLE NULL COMMENT 'Ubicación del reporte',
  `longitude` DOUBLE NULL COMMENT 'Ubicación del reporte',
  `bus_route` VARCHAR(100) NULL COMMENT 'Ruta de bus afectada',
  `stop_name` VARCHAR(255) NULL COMMENT 'Parada afectada',
  `delay_minutes` INT NULL COMMENT 'Minutos de retraso reportados',
  `severity` VARCHAR(20) NOT NULL DEFAULT 'medium' COMMENT 'low, medium, high, critical',
  `status` VARCHAR(20) NOT NULL DEFAULT 'pending' COMMENT 'pending, verified, rejected, resolved',
  `upvotes` INT NOT NULL DEFAULT 0,
  `downvotes` INT NOT NULL DEFAULT 0,
  `contact_email` VARCHAR(255) NULL COMMENT 'Email de contacto (opcional)',
  `device_info` JSON NULL COMMENT 'Información del dispositivo',
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX `idx_contributions_type` (`type`),
  INDEX `idx_contributions_category` (`category`),
  INDEX `idx_contributions_status` (`status`),
  INDEX `idx_contributions_location` (`latitude`, `longitude`),
  INDEX `idx_contributions_route` (`bus_route`),
  INDEX `idx_contributions_created` (`created_at`),
  INDEX `idx_contributions_user` (`user_id`),
  CONSTRAINT `fk_contributions_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
