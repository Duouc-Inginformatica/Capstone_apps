-- ============================================================================
-- MIGRACIÓN: Soporte de Autenticación Biométrica
-- ============================================================================
-- Esta migración actualiza la tabla users para soportar autenticación biométrica
-- además de la autenticación tradicional por password.
--
-- IMPORTANTE: El campo password_hash ahora es opcional (NULL para usuarios biométricos)
-- ============================================================================

USE `wayfindcl`;

-- Agregar columna biometric_id si no existe
ALTER TABLE `users` 
ADD COLUMN IF NOT EXISTS `biometric_id` VARCHAR(64) DEFAULT NULL 
COMMENT 'SHA-256 hash del dispositivo para autenticación biométrica' AFTER `password_hash`;

-- Agregar columna auth_type si no existe
ALTER TABLE `users` 
ADD COLUMN IF NOT EXISTS `auth_type` VARCHAR(20) NOT NULL DEFAULT 'password' 
COMMENT 'Tipo de autenticación: password o biometric' AFTER `biometric_id`;

-- Agregar columna device_info si no existe (opcional, para debugging)
ALTER TABLE `users` 
ADD COLUMN IF NOT EXISTS `device_info` VARCHAR(255) DEFAULT NULL 
COMMENT 'Información del dispositivo para usuarios biométricos' AFTER `auth_type`;

-- Permitir email opcional (NULL) para usuarios biométricos
ALTER TABLE `users`
MODIFY COLUMN `email` VARCHAR(255) NULL DEFAULT NULL;

-- Agregar columna last_login si no existe
ALTER TABLE `users`
ADD COLUMN IF NOT EXISTS `last_login` TIMESTAMP NULL DEFAULT NULL
COMMENT 'Último inicio de sesión del usuario' AFTER `created_at`;

-- Hacer password_hash opcional (NULL permitido)
ALTER TABLE `users` 
MODIFY COLUMN `password_hash` VARCHAR(255) DEFAULT NULL 
COMMENT 'Hash bcrypt del password - NULL para usuarios biométricos';

-- Crear índice único en biometric_id para evitar duplicados
ALTER TABLE `users` 
ADD UNIQUE INDEX IF NOT EXISTS `idx_biometric_id` (`biometric_id`);

-- Crear índice en auth_type para búsquedas rápidas
ALTER TABLE `users` 
ADD INDEX IF NOT EXISTS `idx_auth_type` (`auth_type`);

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================
-- Verificar la estructura de la tabla
DESCRIBE `users`;

-- Mostrar usuarios existentes y su tipo de autenticación
SELECT 
    id,
    username,
    email,
    auth_type,
    CASE 
        WHEN password_hash IS NOT NULL THEN 'Tiene password'
        ELSE 'Sin password'
    END AS password_status,
    CASE 
        WHEN biometric_id IS NOT NULL THEN 'Tiene huella'
        ELSE 'Sin huella'
    END AS biometric_status,
    created_at
FROM `users`
ORDER BY id DESC
LIMIT 10;

-- ============================================================================
-- NOTAS DE USO
-- ============================================================================
-- 
-- REGISTRO CON PASSWORD:
--   INSERT INTO users (username, email, name, password_hash, auth_type) 
--   VALUES ('usuario1', 'email@ejemplo.com', 'Nombre', 'hash_bcrypt', 'password')
--
-- REGISTRO BIOMÉTRICO:
--   INSERT INTO users (username, email, name, biometric_id, auth_type) 
--   VALUES ('usuario2', 'email2@ejemplo.com', 'Nombre', 'sha256_token', 'biometric')
--
-- VERIFICAR HUELLA EXISTENTE:
--   SELECT id FROM users WHERE biometric_id = 'sha256_token'
--   (Si retorna resultado, la huella ya está registrada)
--
-- ============================================================================
