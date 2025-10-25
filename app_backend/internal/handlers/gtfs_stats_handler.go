package handlers

import (
	"database/sql"
	"sync"
	"time"

	"github.com/gofiber/fiber/v2"
)

// GTFSStatsHandler maneja estadísticas del sistema GTFS
type GTFSStatsHandler struct {
	db         *sql.DB
	cache      *GTFSStats
	cacheMutex sync.RWMutex
	cacheTime  time.Time
	cacheTTL   time.Duration
}

// NewGTFSStatsHandler crea un nuevo handler de estadísticas GTFS
func NewGTFSStatsHandler(db *sql.DB) *GTFSStatsHandler {
	return &GTFSStatsHandler{
		db:       db,
		cacheTTL: 5 * time.Minute, // Cache por 5 minutos
	}
}

// GTFSStats representa las estadísticas completas del sistema GTFS
type GTFSStats struct {
	LastSync      *GTFSFeedInfo `json:"lastSync"`
	Stops         int           `json:"stops"`
	Routes        int           `json:"routes"`
	Trips         int           `json:"trips"`
	StopTimes     int           `json:"stopTimes"`
	ActiveRoutes  int           `json:"activeRoutes"`
	TotalDistance float64       `json:"totalDistance"` // km (estimado)
	Coverage      *Coverage     `json:"coverage"`
	CachedAt      time.Time     `json:"cachedAt"`      // Cuándo se consultó la DB
}

// GTFSFeedInfo representa información del último feed sincronizado
type GTFSFeedInfo struct {
	ID           int64     `json:"id"`
	SourceURL    string    `json:"sourceUrl"`
	FeedVersion  string    `json:"feedVersion"`
	ImportedAt   time.Time `json:"importedAt"`
	StopsCount   int       `json:"stopsCount"`
	RoutesCount  int       `json:"routesCount"`
	TripsCount   int       `json:"tripsCount"`
	TimesCount   int       `json:"timesCount"`
}

// Coverage representa la cobertura geográfica del GTFS
type Coverage struct {
	MinLat float64 `json:"minLat"`
	MaxLat float64 `json:"maxLat"`
	MinLon float64 `json:"minLon"`
	MaxLon float64 `json:"maxLon"`
	Center struct {
		Lat float64 `json:"lat"`
		Lon float64 `json:"lon"`
	} `json:"center"`
}

// GetGTFSStats obtiene estadísticas completas del sistema GTFS (con caché)
func (h *GTFSStatsHandler) GetGTFSStats(c *fiber.Ctx) error {
	// Verificar si tenemos cache válido
	h.cacheMutex.RLock()
	if h.cache != nil && time.Since(h.cacheTime) < h.cacheTTL {
		cachedStats := *h.cache
		h.cacheMutex.RUnlock()
		return c.JSON(cachedStats)
	}
	h.cacheMutex.RUnlock()

	// Si no hay cache o expiró, consultar DB
	stats := h.fetchStatsFromDB()
	
	// Actualizar cache
	h.cacheMutex.Lock()
	h.cache = &stats
	h.cacheTime = time.Now()
	h.cacheMutex.Unlock()

	return c.JSON(stats)
}

// fetchStatsFromDB consulta las estadísticas directamente de la base de datos
func (h *GTFSStatsHandler) fetchStatsFromDB() GTFSStats {
	stats := GTFSStats{
		CachedAt: time.Now(),
	}

	// Obtener información del último feed
	var feedInfo GTFSFeedInfo
	err := h.db.QueryRow(`
		SELECT id, source_url, feed_version, imported_at
		FROM gtfs_feeds
		ORDER BY imported_at DESC
		LIMIT 1
	`).Scan(&feedInfo.ID, &feedInfo.SourceURL, &feedInfo.FeedVersion, &feedInfo.ImportedAt)

	if err != nil && err != sql.ErrNoRows {
		// Error de BD, pero continuamos con valores vacíos
		stats.LastSync = nil
	} else if err == nil {
		stats.LastSync = &feedInfo
		
		// Contar registros por tabla (ignorar errores)
		h.db.QueryRow("SELECT COUNT(*) FROM gtfs_stops WHERE feed_id = ?", feedInfo.ID).Scan(&feedInfo.StopsCount)
		h.db.QueryRow("SELECT COUNT(*) FROM gtfs_routes WHERE feed_id = ?", feedInfo.ID).Scan(&feedInfo.RoutesCount)
		h.db.QueryRow("SELECT COUNT(*) FROM gtfs_trips WHERE feed_id = ?", feedInfo.ID).Scan(&feedInfo.TripsCount)
		h.db.QueryRow("SELECT COUNT(*) FROM gtfs_stop_times WHERE feed_id = ?", feedInfo.ID).Scan(&feedInfo.TimesCount)
	}

	// Totales generales (todas las versiones) - ignorar errores si las tablas no existen
	h.db.QueryRow("SELECT COUNT(*) FROM gtfs_stops").Scan(&stats.Stops)
	h.db.QueryRow("SELECT COUNT(*) FROM gtfs_routes").Scan(&stats.Routes)
	h.db.QueryRow("SELECT COUNT(*) FROM gtfs_trips").Scan(&stats.Trips)
	h.db.QueryRow("SELECT COUNT(*) FROM gtfs_stop_times").Scan(&stats.StopTimes)

	// Rutas activas (con al menos un trip)
	h.db.QueryRow(`
		SELECT COUNT(DISTINCT route_id) 
		FROM gtfs_trips
	`).Scan(&stats.ActiveRoutes)

	// Cobertura geográfica
	coverage := Coverage{}
	err = h.db.QueryRow(`
		SELECT 
			MIN(stop_lat) as min_lat,
			MAX(stop_lat) as max_lat,
			MIN(stop_lon) as min_lon,
			MAX(stop_lon) as max_lon,
			AVG(stop_lat) as center_lat,
			AVG(stop_lon) as center_lon
		FROM gtfs_stops
	`).Scan(
		&coverage.MinLat,
		&coverage.MaxLat,
		&coverage.MinLon,
		&coverage.MaxLon,
		&coverage.Center.Lat,
		&coverage.Center.Lon,
	)

	if err == nil && coverage.MinLat != 0 && coverage.MaxLat != 0 {
		stats.Coverage = &coverage
		
		// Estimar distancia total (ancho + alto del bbox en km)
		latDiff := coverage.MaxLat - coverage.MinLat
		lonDiff := coverage.MaxLon - coverage.MinLon
		stats.TotalDistance = (latDiff * 111.0) + (lonDiff * 111.0 * 0.7) // Aproximado para Chile
	}

	return stats
}

// GetTopRoutes obtiene las rutas más populares del GTFS
func (h *GTFSStatsHandler) GetTopRoutes(c *fiber.Ctx) error {
	limit := c.QueryInt("limit", 10)

	rows, err := h.db.Query(`
		SELECT 
			r.route_id,
			r.route_short_name,
			r.route_long_name,
			r.route_type,
			COUNT(DISTINCT t.trip_id) as trip_count,
			COUNT(DISTINCT st.stop_id) as stop_count
		FROM gtfs_routes r
		LEFT JOIN gtfs_trips t ON r.route_id = t.route_id
		LEFT JOIN gtfs_stop_times st ON t.trip_id = st.trip_id
		GROUP BY r.route_id, r.route_short_name, r.route_long_name, r.route_type
		ORDER BY trip_count DESC
		LIMIT ?
	`, limit)

	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "Error fetching top routes",
		})
	}
	defer rows.Close()

	type RouteInfo struct {
		RouteID        string `json:"routeId"`
		ShortName      string `json:"shortName"`
		LongName       string `json:"longName"`
		RouteType      int    `json:"routeType"`
		TripCount      int    `json:"tripCount"`
		StopCount      int    `json:"stopCount"`
	}

	routes := []RouteInfo{}
	for rows.Next() {
		var r RouteInfo
		err := rows.Scan(&r.RouteID, &r.ShortName, &r.LongName, &r.RouteType, &r.TripCount, &r.StopCount)
		if err != nil {
			continue
		}
		routes = append(routes, r)
	}

	return c.JSON(fiber.Map{
		"routes": routes,
		"total":  len(routes),
	})
}
