package handlers

import (
	"database/sql"
	"runtime"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/debug"
)

// StatsHandler maneja endpoints de estadísticas del sistema
type StatsHandler struct {
	db        *sql.DB
	startTime time.Time
}

// NewStatsHandler crea un nuevo handler de estadísticas
func NewStatsHandler(db *sql.DB) *StatsHandler {
	return &StatsHandler{
		db:        db,
		startTime: time.Now(),
	}
}

// SystemStats representa estadísticas generales del sistema
type SystemStats struct {
	Uptime         int64              `json:"uptime"`         // segundos
	Version        string             `json:"version"`
	Memory         MemoryStats        `json:"memory"`
	Database       DatabaseStats      `json:"database"`
	Requests       RequestStats       `json:"requests"`
	ActiveUsers    int                `json:"activeUsers"`
	CacheStats     CacheStats         `json:"cache"`
}

type MemoryStats struct {
	Allocated uint64 `json:"allocated"` // MB
	Total     uint64 `json:"total"`     // MB
	System    uint64 `json:"system"`    // MB
	GCPauses  uint64 `json:"gcPauses"`  // microsegundos
}

type DatabaseStats struct {
	Status         string `json:"status"`
	Connections    int    `json:"connections"`
	MaxConnections int    `json:"maxConnections"`
	IdleConns      int    `json:"idleConns"`
}

type RequestStats struct {
	Total          int64   `json:"total"`
	Last24Hours    int     `json:"last24Hours"`
	PerMinute      float64 `json:"perMinute"`
	AverageLatency float64 `json:"averageLatency"` // ms
}

type CacheStats struct {
	Hits   int64 `json:"hits"`
	Misses int64 `json:"misses"`
	Size   int   `json:"size"`
}

// GetSystemStats obtiene estadísticas generales del sistema
func (h *StatsHandler) GetSystemStats(c *fiber.Ctx) error {
	// Memory stats
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	
	memStats := MemoryStats{
		Allocated: m.Alloc / 1024 / 1024,
		Total:     m.TotalAlloc / 1024 / 1024,
		System:    m.Sys / 1024 / 1024,
		GCPauses:  m.PauseTotalNs / 1000,
	}

	// Database stats
	dbStats := h.db.Stats()
	databaseStats := DatabaseStats{
		Status:         "online",
		Connections:    dbStats.OpenConnections,
		MaxConnections: dbStats.MaxOpenConnections,
		IdleConns:      dbStats.Idle,
	}

	// Request stats desde la base de datos
	requestStats, err := h.getRequestStats()
	if err != nil {
		requestStats = RequestStats{Total: 0, Last24Hours: 0, PerMinute: 0}
	}

	// Active users
	activeUsers, _ := h.getActiveUsers()

	stats := SystemStats{
		Uptime:      int64(time.Since(h.startTime).Seconds()),
		Version:     "1.0.0",
		Memory:      memStats,
		Database:    databaseStats,
		Requests:    requestStats,
		ActiveUsers: activeUsers,
		CacheStats: CacheStats{
			Hits:   0, // TODO: Implementar cache
			Misses: 0,
			Size:   0,
		},
	}

	// Enviar métricas al dashboard siempre (si hay clientes conectados)
	h.sendMetricsToDashboard(stats)

	return c.JSON(stats)
}

// RouteStats representa estadísticas de rutas
type RouteStats struct {
	TotalRequests      int                    `json:"totalRequests"`
	ByType             map[string]int         `json:"byType"`             // walking, driving, transit
	ByTimeOfDay        map[string]int         `json:"byTimeOfDay"`        // morning, afternoon, evening, night
	AverageDistance    float64                `json:"averageDistance"`    // km
	PopularOrigins     []PopularLocation      `json:"popularOrigins"`
	PopularDestinations []PopularLocation     `json:"popularDestinations"`
	BusiestRoutes      []BusiestRoute         `json:"busiestRoutes"`
}

type PopularLocation struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	Count     int     `json:"count"`
	Address   string  `json:"address,omitempty"`
}

type BusiestRoute struct {
	OriginLat  float64 `json:"originLat"`
	OriginLon  float64 `json:"originLon"`
	DestLat    float64 `json:"destLat"`
	DestLon    float64 `json:"destLon"`
	Count      int     `json:"count"`
}

// GetRouteStats obtiene estadísticas de rutas
func (h *StatsHandler) GetRouteStats(c *fiber.Ctx) error {
	// Obtener período (default: last 7 days)
	days := c.QueryInt("days", 7)
	
	stats := RouteStats{
		ByType:      make(map[string]int),
		ByTimeOfDay: make(map[string]int),
	}

	// Total de solicitudes de rutas
	query := `
		SELECT COUNT(*) 
		FROM trip_history 
		WHERE created_at > NOW() - INTERVAL '%d days'
	`
	h.db.QueryRow(query, days).Scan(&stats.TotalRequests)

	// Por tipo de transporte
	query = `
		SELECT transport_mode, COUNT(*) 
		FROM trip_history 
		WHERE created_at > NOW() - INTERVAL '%d days'
		GROUP BY transport_mode
	`
	rows, err := h.db.Query(query, days)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var mode string
			var count int
			rows.Scan(&mode, &count)
			stats.ByType[mode] = count
		}
	}

	// Por hora del día
	query = `
		SELECT 
			CASE 
				WHEN EXTRACT(HOUR FROM created_at) BETWEEN 6 AND 11 THEN 'morning'
				WHEN EXTRACT(HOUR FROM created_at) BETWEEN 12 AND 17 THEN 'afternoon'
				WHEN EXTRACT(HOUR FROM created_at) BETWEEN 18 AND 21 THEN 'evening'
				ELSE 'night'
			END as time_of_day,
			COUNT(*)
		FROM trip_history 
		WHERE created_at > NOW() - INTERVAL '%d days'
		GROUP BY time_of_day
	`
	rows, err = h.db.Query(query, days)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var timeOfDay string
			var count int
			rows.Scan(&timeOfDay, &count)
			stats.ByTimeOfDay[timeOfDay] = count
		}
	}

	// Distancia promedio
	query = `
		SELECT AVG(distance_km) 
		FROM trip_history 
		WHERE created_at > NOW() - INTERVAL '%d days'
		AND distance_km > 0
	`
	h.db.QueryRow(query, days).Scan(&stats.AverageDistance)

	// Orígenes populares
	stats.PopularOrigins = h.getPopularLocations("origin", days)
	
	// Destinos populares
	stats.PopularDestinations = h.getPopularLocations("destination", days)

	return c.JSON(stats)
}

// UserStats representa estadísticas de usuarios
type UserStats struct {
	TotalUsers       int              `json:"totalUsers"`
	ActiveUsers      int              `json:"activeUsers"`      // últimas 24h
	NewUsersToday    int              `json:"newUsersToday"`
	NewUsersThisWeek int              `json:"newUsersThisWeek"`
	ByAccessibility  map[string]int   `json:"byAccessibility"`
	UserGrowth       []UserGrowthData `json:"userGrowth"`
}

type UserGrowthData struct {
	Date  string `json:"date"`
	Count int    `json:"count"`
}

// GetUserStats obtiene estadísticas de usuarios
func (h *StatsHandler) GetUserStats(c *fiber.Ctx) error {
	stats := UserStats{
		ByAccessibility: make(map[string]int),
	}

	// Total de usuarios
	h.db.QueryRow("SELECT COUNT(*) FROM users").Scan(&stats.TotalUsers)

	// Usuarios activos (últimas 24 horas)
	query := `
		SELECT COUNT(DISTINCT user_id) 
		FROM trip_history 
		WHERE created_at > NOW() - INTERVAL '24 hours'
	`
	h.db.QueryRow(query).Scan(&stats.ActiveUsers)

	// Nuevos usuarios hoy
	query = `
		SELECT COUNT(*) 
		FROM users 
		WHERE created_at::date = CURRENT_DATE
	`
	h.db.QueryRow(query).Scan(&stats.NewUsersToday)

	// Nuevos usuarios esta semana
	query = `
		SELECT COUNT(*) 
		FROM users 
		WHERE created_at > NOW() - INTERVAL '7 days'
	`
	h.db.QueryRow(query).Scan(&stats.NewUsersThisWeek)

	// Por tipo de accesibilidad (si existe columna)
	query = `
		SELECT 
			CASE WHEN has_biometric THEN 'biometric' ELSE 'standard' END as type,
			COUNT(*)
		FROM users
		GROUP BY has_biometric
	`
	rows, err := h.db.Query(query)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var userType string
			var count int
			rows.Scan(&userType, &count)
			stats.ByAccessibility[userType] = count
		}
	}

	// Crecimiento de usuarios (últimos 30 días)
	query = `
		SELECT 
			created_at::date as date,
			COUNT(*) as count
		FROM users
		WHERE created_at > NOW() - INTERVAL '30 days'
		GROUP BY created_at::date
		ORDER BY date DESC
		LIMIT 30
	`
	rows, err = h.db.Query(query)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var data UserGrowthData
			rows.Scan(&data.Date, &data.Count)
			stats.UserGrowth = append(stats.UserGrowth, data)
		}
	}

	return c.JSON(stats)
}

// BusStats representa estadísticas de transporte público
type BusStats struct {
	TotalRequests     int                 `json:"totalRequests"`
	PopularRoutes     []PopularBusRoute   `json:"popularRoutes"`
	PopularStops      []PopularStop       `json:"popularStops"`
	AverageWaitTime   float64             `json:"averageWaitTime"` // minutos
	PeakHours         []PeakHour          `json:"peakHours"`
}

type PopularBusRoute struct {
	RouteNumber string `json:"routeNumber"`
	RouteName   string `json:"routeName"`
	Count       int    `json:"count"`
}

type PopularStop struct {
	StopCode  string  `json:"stopCode"`
	StopName  string  `json:"stopName"`
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	Count     int     `json:"count"`
}

type PeakHour struct {
	Hour  int `json:"hour"`
	Count int `json:"count"`
}

// GetBusStats obtiene estadísticas de buses
func (h *StatsHandler) GetBusStats(c *fiber.Ctx) error {
	days := c.QueryInt("days", 7)
	
	stats := BusStats{}

	// Total de solicitudes de rutas en bus
	query := `
		SELECT COUNT(*) 
		FROM trip_history 
		WHERE transport_mode IN ('bus', 'transit')
		AND created_at > NOW() - INTERVAL '%d days'
	`
	h.db.QueryRow(query, days).Scan(&stats.TotalRequests)

	// Rutas más populares (desde trip_history si guardamos esa info)
	// Por ahora retornamos array vacío
	stats.PopularRoutes = []PopularBusRoute{}

	// Paradas más consultadas desde stops_queries si existe
	stats.PopularStops = h.getPopularStops(days)

	// Horas pico
	query = `
		SELECT 
			EXTRACT(HOUR FROM created_at)::int as hour,
			COUNT(*) as count
		FROM trip_history
		WHERE transport_mode IN ('bus', 'transit')
		AND created_at > NOW() - INTERVAL '%d days'
		GROUP BY hour
		ORDER BY count DESC
		LIMIT 10
	`
	rows, err := h.db.Query(query, days)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var peak PeakHour
			rows.Scan(&peak.Hour, &peak.Count)
			stats.PeakHours = append(stats.PeakHours, peak)
		}
	}

	return c.JSON(stats)
}

// Helper functions

func (h *StatsHandler) getRequestStats() (RequestStats, error) {
	stats := RequestStats{}
	
	// Total histórico
	query := "SELECT COUNT(*) FROM trip_history"
	h.db.QueryRow(query).Scan(&stats.Total)

	// Últimas 24 horas
	query = "SELECT COUNT(*) FROM trip_history WHERE created_at > NOW() - INTERVAL '24 hours'"
	h.db.QueryRow(query).Scan(&stats.Last24Hours)

	// Requests por minuto (promedio última hora)
	if stats.Last24Hours > 0 {
		stats.PerMinute = float64(stats.Last24Hours) / (24.0 * 60.0)
	}

	return stats, nil
}

func (h *StatsHandler) getActiveUsers() (int, error) {
	var count int
	query := `
		SELECT COUNT(DISTINCT user_id) 
		FROM trip_history 
		WHERE created_at > NOW() - INTERVAL '24 hours'
	`
	err := h.db.QueryRow(query).Scan(&count)
	return count, err
}

func (h *StatsHandler) getPopularLocations(locationType string, days int) []PopularLocation {
	locations := []PopularLocation{}
	
	latCol := "origin_lat"
	lonCol := "origin_lon"
	if locationType == "destination" {
		latCol = "dest_lat"
		lonCol = "dest_lon"
	}

	query := `
		SELECT 
			` + latCol + `,
			` + lonCol + `,
			COUNT(*) as count
		FROM trip_history
		WHERE created_at > NOW() - INTERVAL '%d days'
		AND ` + latCol + ` IS NOT NULL
		GROUP BY ` + latCol + `, ` + lonCol + `
		ORDER BY count DESC
		LIMIT 10
	`
	
	rows, err := h.db.Query(query, days)
	if err != nil {
		return locations
	}
	defer rows.Close()

	for rows.Next() {
		var loc PopularLocation
		rows.Scan(&loc.Latitude, &loc.Longitude, &loc.Count)
		locations = append(locations, loc)
	}

	return locations
}

func (h *StatsHandler) getPopularStops(days int) []PopularStop {
	stops := []PopularStop{}
	// Implementar según tu esquema de base de datos
	// Si tienes una tabla de consultas de paradas
	return stops
}

func (h *StatsHandler) sendMetricsToDashboard(stats SystemStats) {
	metrics := []debug.Metric{
		{
			Name:  "CPU Usage",
			Value: h.calculateCPUUsage(),
			Unit:  "%",
			Trend: "stable",
		},
		{
			Name:  "Memory",
			Value: stats.Memory.Allocated,
			Unit:  "MB",
			Trend: "stable",
		},
		{
			Name:  "Active Users",
			Value: stats.ActiveUsers,
			Trend: "stable",
		},
		{
			Name:  "API Requests/min",
			Value: stats.Requests.PerMinute,
			Trend: "stable",
		},
	}

	debug.SendMetrics(metrics)

	// También enviar estado de APIs
	apiStatus := debug.ApiStatus{}
	apiStatus.Backend.Status = "online"
	apiStatus.Backend.ResponseTime = stats.Requests.AverageLatency
	apiStatus.Backend.Version = stats.Version
	
	apiStatus.Database.Status = stats.Database.Status
	apiStatus.Database.Connections = stats.Database.Connections
	apiStatus.Database.MaxConnections = stats.Database.MaxConnections

	// TODO: Verificar estado de GraphHopper
	apiStatus.GraphHopper.Status = "online"
	apiStatus.GraphHopper.ResponseTime = 0

	debug.SendApiStatus(apiStatus)
}

func (h *StatsHandler) calculateCPUUsage() float64 {
	// Implementación simplificada
	// En producción usar syscall o librerías especializadas
	return float64(runtime.NumGoroutine()) / 100.0 * 10.0 // Aproximación
}
