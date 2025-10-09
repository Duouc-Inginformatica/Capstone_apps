# WayFindCL Backend

Fiber-based REST API with MariaDB. Provides registration and login with bcrypt and a minimal HS256 token.

## Endpoints
- `GET /api/health` → `{ "status": "ok" }`
- `POST /api/register` → `{ token, user, expires_at }`
- `POST /api/login` → `{ token, user, expires_at }`
- `POST /api/gtfs/sync` → fuerza la descarga del feed GTFS y retorna un resumen (`stops_imported`, `feed_version`).
- `GET /api/stops?lat=-33.45&lon=-70.66&radius=400&limit=20` → lista paradas cercanas al punto solicitado ordenadas por distancia.
- `POST /api/route/transit` → consulta GraphHopper para obtener un itinerario en transporte público.
	- Body JSON:
	```json
	{
	  "origin": { "lat": -33.45, "lon": -70.66 },
	  "destination": { "lat": -33.52, "lon": -70.68 },
	  "departure_time": "2025-09-27T12:00:00Z",
	  "arrive_by": false,
	  "include_geometry": true
	}
	```
	- Respuesta simplificada con `distance_meters`, `duration_seconds`, `instructions[]` y geometría (líneas `[[lon, lat], ...]`) cuando está disponible.

## Run
```powershell
cd app_backend
Copy-Item .env.example .env
# Edit .env with your DB and JWT_SECRET
# (Opcional pero recomendado en producción) inicializa el esquema ejecutando default.sql directamente en tu instancia
# mysql -u root -p < default.sql
# Establece DB_SKIP_SCHEMA=1 si no quieres que el servidor cree tablas automáticamente
go mod tidy
go build ./cmd/server
./server.exe
```

Server logs: `server listening on :8080`

## Env vars
- `PORT` (default `8080`)
- `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_NAME`
- `JWT_SECRET` (HS256 secret for token signing)
- `JWT_TTL` (opcional, duración estilo Go `time.ParseDuration`, por defecto `24h`)
- `GTFS_FEED_URL` (URL del feed GTFS; por defecto se usa el publicado por [DTPM](https://www.dtpm.cl/index.php/noticias/gtfs-vigente)).
- `GTFS_AUTO_SYNC` (`true/false`) para actualizar automáticamente al iniciar el servidor.
- `GTFS_FALLBACK_URL` (URL alternativa a usar si la primaria retorna error, útil cuando DTPM rota el nombre del zip diario).
- `GRAPHHOPPER_BASE_URL` (URL del servidor GraphHopper, ejemplo `http://localhost:8998`).
- `GRAPHHOPPER_API_KEY` (opcional, si usas la nube de GraphHopper).
- `GRAPHHOPPER_PROFILE` (por defecto `pt`).
- `GRAPHHOPPER_LOCALE` (por defecto `es`).
- `GRAPHHOPPER_INCLUDE_GEOMETRY` (`true/false`, por defecto `true`).
- `GRAPHHOPPER_TIMEOUT` (opcional, duración para la petición, ej. `45s`).
- `DB_SKIP_SCHEMA` (`true/false` o `1/0`): cuando es `true/1` el servidor **no** ejecuta `EnsureSchema`. Útil en producción si el esquema se administra externamente.

## Transporte público (GTFS + GraphHopper)

1. **Descarga e ingesta del GTFS:**
	- Ejecuta el CLI: `go run ./cmd/cli` → opción `3) Sync GTFS feed`.
	- O bien realiza `POST /api/gtfs/sync` con el servidor levantado.
	- El proceso limpia `gtfs_stops` y vuelve a importar `stops.txt`, guardando la versión del feed.

2. **Servir paradas cercanas:** `GET /api/stops` acepta parámetros `lat`, `lon`, `radius` (metros, default 400, máximo 2000) y `limit` (máx. 100). Respuesta incluye distancia a cada parada y fecha del último feed.

3. **GraphHopper:**
	- Requiere instanciar un servidor GraphHopper con soporte GTFS. Sigue la guía oficial para construir el grafo con OpenStreetMap + GTFS de DTPM (ver [docs](https://github.com/graphhopper/graphhopper/blob/master/docs/core/transit.md)).
	- Configura `GRAPHHOPPER_BASE_URL` apuntando al servidor en ejecución. Si usas la versión comercial/Nube, añade `GRAPHHOPPER_API_KEY`.
	- El endpoint `/api/route/transit` devolverá instrucciones paso a paso (texto en español) y la geometría de la ruta para integrarla con la app Flutter.
  
### MariaDB/MySQL auth plugin note
If you see errors like `unknown auth plugin: auth_gssapi_client`, it's because the user is configured with an unsupported plugin. The Go MySQL driver can't override this via DSN.

Fix by creating or altering the DB user to a supported plugin:

MariaDB 10.4+ (use mysql_native_password):
```sql
CREATE USER IF NOT EXISTS 'wayfind_app'@'%' IDENTIFIED BY 'Strong#Pass2025';
ALTER USER 'wayfind_app'@'%' IDENTIFIED VIA mysql_native_password;
ALTER USER 'wayfind_app'@'%' IDENTIFIED BY 'Strong#Pass2025';
GRANT ALL PRIVILEGES ON `wayfindcl`.* TO 'wayfind_app'@'%';
FLUSH PRIVILEGES;
```

MySQL 8 (use caching_sha2_password or mysql_native_password):
```sql
CREATE USER IF NOT EXISTS 'wayfind_app'@'%' IDENTIFIED WITH caching_sha2_password BY 'Strong#Pass2025';
-- or: IDENTIFIED WITH mysql_native_password BY 'Strong#Pass2025';
GRANT ALL PRIVILEGES ON `wayfindcl`.* TO 'wayfind_app'@'%';
FLUSH PRIVILEGES;
```

## SQL bootstrap
- A provided `default.sql` contains:
	- `CREATE DATABASE wayfindcl` and `users` table
	- Optional creation of an app user (commented; choose the plugin for your server)
	- Optional demo user `demo/demo1234`
  
To apply it manually (requerido si usas `DB_SKIP_SCHEMA=1`):
```powershell
mysql -u root -p < default.sql
```

## Notes
- La emisión de tokens usa `github.com/golang-jwt/jwt/v5` e incluye `exp`/`iat`. Ajusta `JWT_TTL` según tus necesidades.
- Se crean tablas adicionales `gtfs_feeds` y `gtfs_stops` al ejecutar `EnsureSchema()`.
- El CLI (`go run ./cmd/cli`) ahora incluye opciones para verificar salud, sembrar usuario demo y sincronizar el GTFS.
