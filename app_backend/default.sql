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

-- 3) Usuario de aplicación (opcional)
-- Reemplaza 'app_user' y 'Strong#Pass2025' por tus valores.
-- Descomenta si quieres crear el usuario y darle permisos a esta DB.
-- Para MySQL 8 con plugin moderno:
-- CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED WITH caching_sha2_password BY 'Strong#Pass2025';
-- Para MySQL/MariaDB legacy (o si el driver lo requiere):
-- CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED WITH mysql_native_password BY 'Strong#Pass2025';
-- GRANT ALL PRIVILEGES ON `wayfindcl`.* TO 'app_user'@'%';
-- FLUSH PRIVILEGES;

-- 4) Usuario demo (opcional)
-- Inserta un usuario demo con hash calculado previamente.
-- El hash corresponde a la contraseña "demo1234" usando bcrypt con cost por defecto.
-- Nota: cambia el hash si vas a usar otra contraseña.
INSERT INTO `users` (`username`, `email`, `name`, `password_hash`)
SELECT 'demo', 'demo@example.com', 'Demo', '$2a$10$uRZxQ7E7G6k3oO9dDg2s6u6uT2vQH1C8s7l5B4tXnqk1t4q9m4m8K'
WHERE NOT EXISTS (SELECT 1 FROM `users` WHERE `username` = 'demo');
