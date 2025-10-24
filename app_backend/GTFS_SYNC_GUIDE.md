# 📊 Guía de Sincronización GTFS Automática

## 🎯 Descripción

El sistema de sincronización GTFS mantiene actualizada la información de transporte público (paradas, rutas, horarios) descargando automáticamente los datos desde el DTPM (Directorio de Transporte Público Metropolitano) de Santiago.

## ⚙️ Configuración

### Variables de Entorno

```env
# Habilitar sincronización automática al iniciar el servidor
GTFS_AUTO_SYNC=true

# URL principal del feed GTFS
GTFS_FEED_URL=https://www.dtpm.cl/descarga.php?file=gtfs/gtfs.zip

# URL de respaldo si la principal falla
GTFS_FALLBACK_URL=https://www.dtpm.cl/descargas/gtfs/GTFS_20250927_v3.zip
```

## 🔄 Funcionamiento Automático

### Primera Sincronización
Al iniciar el backend con `GTFS_AUTO_SYNC=true`:

1. **Verifica si hay datos existentes**
   - Consulta la tabla `gtfs_feeds` para obtener última sincronización
   - Si los datos tienen **menos de 30 días**, los usa directamente
   - Si tienen **más de 30 días** o no existen, descarga nuevos datos

2. **Descarga y procesa el feed GTFS**
   ```
   📥 Descargando ZIP desde DTPM
   📦 Extrayendo archivos (stops.txt, routes.txt, trips.txt, stop_times.txt)
   🗑️  Limpiando datos antiguos
   📍 Importando paradas (~12,682 stops)
   🚌 Importando rutas (~424 routes)
   🚐 Importando viajes (~14,061 trips)
   ⏰ Importando horarios (~809,281 stop times)
   ✅ Completado en ~3-5 minutos
   ```

3. **Programa verificaciones mensuales**
   - Cada 30 días, el sistema verifica automáticamente
   - Si detecta que los datos están desactualizados, los actualiza
   - No requiere intervención manual

### Verificación Mensual

El sistema ejecuta automáticamente cada 30 días:

```
🔍 [GTFS-SYNC] Verificación mensual automática...
📊 [GTFS-SYNC] Días desde última sincronización: 32.5
🔄 [GTFS-SYNC] Los datos tienen más de 30 días, actualizando...
```

## 📡 Endpoints de Consulta

### 1. Consultar Estado de Sincronización

```http
GET /api/gtfs/status
```

**Respuesta exitosa (datos sincronizados):**
```json
{
  "status": "synced",
  "last_sync": "2025-10-24 03:36:55",
  "days_since_sync": 5,
  "needs_update": false,
  "feed_version": "20250927_v3",
  "source_url": "https://www.dtpm.cl/descarga.php?file=gtfs/gtfs.zip",
  "stops_imported": 12682,
  "routes_imported": 424,
  "trips_imported": 14061,
  "stop_times_imported": 809281,
  "sync_duration_seconds": 287.3
}
```

**Respuesta (sin datos):**
```json
{
  "status": "no_data",
  "message": "No hay datos GTFS sincronizados",
  "auto_sync": true
}
```

### 2. Forzar Sincronización Manual

```http
POST /api/gtfs/sync
```

**Respuesta:**
```json
{
  "message": "Sincronización GTFS iniciada. Puede tomar varios minutos.",
  "status": "in_progress"
}
```

**Respuesta (ya hay sincronización en curso):**
```json
{
  "error": "Ya hay una sincronización GTFS en curso"
}
```

## 📊 Logs del Sistema

### Inicio con Datos Actualizados
```
✅ [GTFS-SYNC] Datos GTFS actualizados (última sincronización: 2025-10-24 03:36:55)
📅 [GTFS-SYNC] Próxima verificación en 30 días
```

### Inicio con Datos Desactualizados
```
🔄 [GTFS-SYNC] Iniciando sincronización automática...
📅 [GTFS-SYNC] Última sincronización: 2025-09-15 10:22:33
🚀 [GTFS-SYNC] Iniciando sincronización (puede tomar varios minutos)...
📍 Importing stops...
✅ [GTFS-SYNC] Sincronización completada en 4.8 minutos
╔══════════════════════════════════════════════════════════════╗
║              📊 RESUMEN DE SINCRONIZACIÓN GTFS              ║
╠══════════════════════════════════════════════════════════════╣
║ 🚏 Paradas:        12682                                    ║
║ 🚌 Rutas:           424                                     ║
║ 🚐 Viajes:        14061                                     ║
║ ⏰ Stop Times:   809281                                     ║
║ ⏱️  Duración:       287.3 segundos                          ║
║ 📅 Fecha:          2025-10-24 03:36:55                     ║
║ 🔗 Fuente:         https://www.dtpm.cl/descarga.php?fi...  ║
║ 📦 Versión:        20250927_v3                             ║
╚══════════════════════════════════════════════════════════════╝
📅 [GTFS-SYNC] Próxima verificación programada en 30 días
```

## 🗄️ Estructura de Base de Datos

### Tabla `gtfs_feeds`
```sql
CREATE TABLE gtfs_feeds (
  id bigint PRIMARY KEY AUTO_INCREMENT,
  source_url varchar(500) NOT NULL,
  feed_version varchar(100),
  downloaded_at timestamp DEFAULT CURRENT_TIMESTAMP
);
```

### Tablas GTFS Relacionadas
- `gtfs_stops` - Paradas de transporte público (~12,682 registros)
- `gtfs_routes` - Rutas de buses (~424 rutas)
- `gtfs_trips` - Viajes programados (~14,061 viajes)
- `gtfs_stop_times` - Horarios de llegada/salida (~809,281 registros)

## 🔧 Troubleshooting

### Problema: Sincronización Falla
```
❌ [GTFS-SYNC] Error en sincronización: connection timeout
```

**Soluciones:**
1. Verificar conexión a internet
2. Probar URL de fallback manualmente
3. Aumentar timeout en `loader.go` (actualmente 120s)
4. Verificar que el DTPM no haya cambiado la URL

### Problema: Importación Incompleta
```
gtfs loader: line 11970 - invalid latitude '' for stop LH-Boleteria-L1-ZNP
```

**Explicación:**
- El GTFS del DTPM contiene ~314 paradas con coordenadas inválidas
- Estas paradas se **omiten automáticamente** (no causan error)
- El sistema importa las ~12,682 paradas válidas correctamente

### Problema: Base de Datos Llena
Si la tabla `gtfs_stop_times` crece demasiado (>800k registros):

1. **Verificar espacio en disco:**
   ```sql
   SELECT 
     table_name, 
     ROUND((data_length + index_length) / 1024 / 1024, 2) AS size_mb
   FROM information_schema.tables 
   WHERE table_schema = 'wayfindcl'
   ORDER BY (data_length + index_length) DESC;
   ```

2. **Limpiar datos antiguos manualmente:**
   ```sql
   DELETE FROM gtfs_feeds WHERE downloaded_at < DATE_SUB(NOW(), INTERVAL 60 DAY);
   ```

## 📈 Métricas de Performance

### Tiempos Típicos de Sincronización
- **Descarga ZIP**: ~10-30 segundos (depende de conexión)
- **Importación Stops**: ~30 segundos (12,682 paradas)
- **Importación Routes**: ~5 segundos (424 rutas)
- **Importación Trips**: ~15 segundos (14,061 viajes)
- **Importación Stop Times**: ~3-4 minutos (809,281 registros)
- **Total**: ~4-5 minutos promedio

### Uso de Memoria
- **Descarga ZIP**: ~50-100 MB en RAM
- **Procesamiento CSV**: ~200-300 MB pico
- **Base de datos**: ~500 MB en disco

## 🚀 Mejoras Futuras

1. **Notificaciones**: 
   - Enviar email/webhook cuando se complete sincronización
   - Alertar si la sincronización falla repetidamente

2. **Versionado**:
   - Mantener historial de versiones GTFS
   - Permitir rollback a versión anterior

3. **Optimización**:
   - Sincronización incremental (solo cambios)
   - Compresión de tablas históricas

4. **Monitoreo**:
   - Dashboard web para visualizar estado
   - Gráficos de tendencias de sincronización

## 📞 Soporte

Para problemas con la sincronización GTFS:
1. Revisar logs del backend: `.\start-backend.ps1`
2. Consultar estado: `GET /api/gtfs/status`
3. Verificar conectividad con DTPM
4. Contactar equipo de desarrollo

---

**Última actualización**: 24 de octubre de 2025
**Versión del sistema**: 1.0.0
