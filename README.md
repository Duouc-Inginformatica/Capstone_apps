# Capstone Apps

Monorepo con una app Flutter (`app/`) y un backend REST en Go (`app_backend/`).

## Componentes

- **Flutter (app/)**: interfaz WayFindCL con login/registro, lectura de token al iniciar, cierre de sesión desde ajustes y navegación por comandos de voz.
- **Go Backend (app_backend/)**: API con Fiber y MariaDB/MySQL. Emite tokens JWT con expiración configurable, sincroniza el feed GTFS oficial del transporte público de Santiago y consulta GraphHopper para entregar rutas accesibles.

## Puesta en marcha rápida

1. Sigue las instrucciones específicas de cada carpeta (`app/README.md` y `app_backend/README.md`).
2. Define las variables de entorno necesarias (`JWT_SECRET`, `JWT_TTL`, `GTFS_FEED_URL`, `GRAPHHOPPER_BASE_URL`, credenciales de base de datos, etc.).
3. Ejecuta backend y app de manera independiente.

> Consulta los README específicos para detalles de configuración, semillas y opciones adicionales.
