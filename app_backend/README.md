# WayFindCL Backend

Backend Go con Fiber para navegación accesible en Santiago, Chile.

## Arquitectura de Routing

**Sistema Híbrido:**
- **GraphHopper + GTFS**: Routing principal (INTEGRADO en backend como subproceso)
- **Moovit Scraper**: Información complementaria específica de rutas Red

### ¿Por qué híbrido?

1. **GraphHopper (Routing General)**
   - ✅ TODAS las 400+ líneas de buses de Santiago
   - ✅ Metro + Metrotrén
   - ✅ Horarios en tiempo real (GTFS oficial de DTPM)
   - ✅ Múltiples alternativas optimizadas
   - ✅ Rutas peatonales precisas
   - ✅ **Ejecuta como subproceso del backend** (auto-start)

2. **Moovit Scraper (Info Específica)**
   - ✅ URLs de Moovit para rutas Red
   - ✅ Geometrías específicas del proveedor
   - ✅ Información adicional no disponible en GTFS
   - ✅ Se mantiene como complemento

## Setup Rápido

### 1. Configurar GraphHopper (Primera vez)

```powershell
cd app_backend

# Script automatizado (recomendado)
.\setup-graphhopper.ps1

# O manual:
# 1. Descargar GraphHopper JAR 11.0 (última versión - Oct 2025)
curl -L https://repo1.maven.org/maven2/com/graphhopper/graphhopper-web/11.0/graphhopper-web-11.0.jar -o graphhopper-web-11.0.jar

# 2. Descargar mapa OSM de Santiago (~50 MB - solo región)
mkdir data
curl -L https://download.geofabrik.de/south-america/chile/region-metropolitana-latest.osm.pbf -o data/santiago.osm.pbf

# 3. Descargar GTFS de DTPM
curl -L https://www.dtpm.cl/descargas/gtfs/google_transit.zip -o data/santiago_gtfs.zip

# 4. Importar datos (10-30 minutos)
java -Xmx8g -Xms2g -jar graphhopper-web-11.0.jar import graphhopper-config.yml
```

### 2. Iniciar Backend

**Opción 1: Inicio Automático con Verificación (Recomendado)**
```powershell
.\start-backend.ps1
```
Este script:
- ✅ Verifica configuración de perfiles
- ✅ Detecta incompatibilidades en caché
- ✅ Limpia automáticamente si es necesario
- ✅ Valida archivos de datos
- ✅ Inicia el servidor

**Opción 2: Limpieza Forzada + Inicio**
```powershell
.\clean-start.ps1
```
Útil cuando cambias perfiles en `graphhopper-config.yml`

**Opción 3: Manual**
```powershell
# Si cambias perfiles, primero limpia el caché:
rm -r -fo graph-cache

# Iniciar servidor
go run .\cmd\server\
```

**Nota:** Solo necesitas ejecutar esto UNA VEZ. El backend gestionará GraphHopper automáticamente.

### 2. Iniciar Backend (GraphHopper incluido)

```powershell
# Una sola terminal - backend inicia GraphHopper automáticamente
Copy-Item .env.example .env
# Editar .env con tus credenciales de BD

go mod tidy
go build ./cmd/server
.\server.exe
```

**Logs esperados:**
```
Iniciando GraphHopper...
✅ GraphHopper iniciado correctamente
server listening on :8080
```

Si ves error de GraphHopper:
- Verifica que `graph-cache/` existe (ejecuta setup-graphhopper.ps1)
- Verifica que el JAR está en `graphhopper-web-11.0.jar`
- Revisa `graphhopper.log` para detalles

## Endpoints

### Autenticación
- `GET /api/health` → `{ "status": "ok" }`
- `POST /api/register` → `{ token, user, expires_at }`
- `POST /api/login` → `{ token, user, expires_at }`

### Routing (GraphHopper - Modularizado)

#### 1. Ruta Peatonal
```bash
GET /api/route/walking?origin_lat=-33.45&origin_lon=-70.66&dest_lat=-33.52&dest_lon=-70.68
```

Respuesta:
```json
{
  "distance_meters": 8500,
  "duration_seconds": 6120,
  "geometry": [[lon, lat], ...],
  "instructions": [
    {"text": "Camina por Avenida Providencia", "distance": 450, "time": 324}
  ],
  "source": "graphhopper"
}
```

#### 2. Ruta con Transporte Público (GTFS Completo)
```bash
POST /api/route/transit
Content-Type: application/json

{
  "origin": {"lat": -33.45, "lon": -70.66},
  "destination": {"lat": -33.52, "lon": -70.68},
  "departure_time": "2025-10-18T14:30:00Z",  // opcional
  "max_walk_distance": 1000  // metros, opcional
}
```

Respuesta:
```json
{
  "alternatives": [
    {
      "distance_meters": 12000,
      "duration_seconds": 1800,
      "transfers": 1,
      "legs": [
        {
          "type": "walk",
          "distance": 200,
          "geometry": [[lon, lat], ...],
          "instructions": [...]
        },
        {
          "type": "pt",
          "route_short_name": "506",
          "route_long_name": "Maipú - Las Condes",
          "headsign": "Las Condes",
          "departure_time": "2025-10-18T14:35:00Z",
          "arrival_time": "2025-10-18T14:55:00Z",
          "num_stops": 12,
          "stops": [
            {"name": "Los Leones", "lat": -33.45, "lon": -70.66, "sequence": 1},
            ...
          ],
          "geometry": [[lon, lat], ...]
        }
      ]
    }
  ],
  "source": "graphhopper_gtfs"
}
```

#### 3. Opciones de Ruta (LIGERO - Sin geometría)
```bash
POST /api/route/options
Content-Type: application/json

{
  "origin": {"lat": -33.45, "lon": -70.66},
  "destination": {"lat": -33.52, "lon": -70.68}
}
```

**Uso:** Presenta opciones al usuario por voz ANTES de cargar geometría completa.

Respuesta:
```json
{
  "options": [
    {
      "type": "walking",
      "distance_meters": 1500,
      "duration_seconds": 1080,
      "description": "Caminar 1.5 km"
    },
    {
      "type": "transit",
      "distance_meters": 12000,
      "duration_seconds": 1800,
      "transfers": 1,
      "routes": ["506", "L1"],
      "description": "Bus 506 + L1 - 30 min"
    },
    {
      "type": "transit",
      "distance_meters": 11500,
      "duration_seconds": 2100,
      "transfers": 0,
      "routes": ["D03"],
      "description": "Bus D03 - 35 min"
    }
  ],
  "origin": {"lat": -33.45, "lon": -70.66},
  "destination": {"lat": -33.52, "lon": -70.68}
}
```

### GTFS (Paradas)
- `GET /api/stops?lat=-33.45&lon=-70.66&radius=400&limit=20` → Paradas cercanas
- `GET /api/stops/code/:code` → Buscar parada por código

### Endpoints de Buses Red (Moovit - COMPLEMENTARIO)
- `GET /api/red/routes/common` → lista rutas Red comunes
- `GET /api/red/routes/search?q=query` → busca rutas Red
- `GET /api/red/route/:routeNumber` → info detallada ruta Red
- `GET /api/red/route/:routeNumber/stops` → paradas de ruta Red
- `GET /api/red/route/:routeNumber/geometry` → geometría para mapa
- `POST /api/red/itinerary` → itinerario completo buses Red

### Otros Endpoints
- `POST /api/incidents` → Reportar incidencias
- `GET /api/incidents?route_id=X&lat=Y&lon=Z&radius=500` → Ver incidencias
- `POST /api/shares` → Compartir viaje
- `POST /api/trips` → Guardar viaje
- `GET /api/trips` → Listar viajes guardados
- `PUT /api/preferences` → Actualizar preferencias de navegación

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

Server logs: 
```
Iniciando GraphHopper...
✅ GraphHopper iniciado correctamente
server listening on :8080
```

## Env vars
- `PORT` (default `8080`)
- `GRAPHHOPPER_URL` (default `http://localhost:8989`)
- `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_NAME`
- `JWT_SECRET` (HS256 secret for token signing)
- `JWT_TTL` (opcional, duración estilo Go `time.ParseDuration`, por defecto `24h`)
- `GTFS_FEED_URL` (URL del feed GTFS; por defecto se usa el publicado por [DTPM](https://www.dtpm.cl/index.php/noticias/gtfs-vigente)).
- `GTFS_AUTO_SYNC` (`true/false`) para actualizar automáticamente al iniciar el servidor.
- `GTFS_FALLBACK_URL` (URL alternativa a usar si la primaria retorna error, útil cuando DTPM rota el nombre del zip diario).
- `DB_SKIP_SCHEMA` (`true/false` o `1/0`): cuando es `true/1` el servidor **no** ejecuta `EnsureSchema`. Útil en producción si el esquema se administra externamente.

## Arquitectura GraphHopper

### Gestión como Subproceso

GraphHopper se ejecuta como un **proceso hijo del backend Go**:

```go
// En startup (cmd/server/main.go)
handlers.InitGraphHopper()  // Lanza: java -jar graphhopper-web-11.0.jar
```

**Beneficios:**
- ✅ Un solo punto de inicio
- ✅ Logs centralizados en `graphhopper.log`
- ✅ Auto-reinicio si falla
- ✅ Limpieza automática al cerrar backend

**Health Check:**
El backend espera hasta 60s a que GraphHopper responda en `http://localhost:8989/health`.

### Configuración (`graphhopper-config.yml`)

```yaml
datareader.file: ./data/santiago.osm.pbf  # Solo región metropolitana (~50 MB)
graph.location: ./graph-cache
gtfs.feed: ./data/santiago_gtfs.zip
pt.max_walk_distance_per_leg: 1000
pt.boarding_penalty_seconds: 300  # Favorece menos trasbordos
profiles:
  - name: foot
    custom_model:
      speed: [{if: "true", multiply_by: 0.85}]  # Ajuste para usuario ciego
  - name: car
  - name: pt  # Public transit
```

## Transporte público (GTFS + Moovit Scraping)

1. **Sincronización GTFS (INTERNA):**
	- Endpoint `/api/gtfs/sync` ELIMINADO de API pública
	- Sincronización se hace en inicialización del servidor
	- Datos de DTPM guardados en `gtfs_stops`, `gtfs_feeds`

2. **Servir paradas cercanas:** 
   - `GET /api/stops` → lat, lon, radius (metros, default 400, máx 2000), limit (máx 100)

3. **Rutas de transporte público:** 
   - `POST /api/route/transit` → Usa GTFS completo (todas las líneas)
   - `POST /api/route/options` → Resumen ligero para selección por voz

4. **Buses Red (Moovit Scraping - COMPLEMENTARIO):** 
   - Endpoints bajo `/api/red/*` utilizan web scraping de Moovit
   - Información específica de Red no disponible en GTFS oficial
   - Se mantiene como fuente complementaria
  
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
- GraphHopper se ejecuta como subproceso del backend - no necesitas terminal separada
- El CLI (`go run ./cmd/cli`) incluye opciones para verificar salud, sembrar usuario demo y sincronizar el GTFS.
- Logs de GraphHopper se guardan en `graphhopper.log` en el directorio del backend

