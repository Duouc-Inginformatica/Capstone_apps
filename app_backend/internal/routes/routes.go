package routes

import (
	"database/sql"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/websocket/v2"
	"github.com/yourorg/wayfindcl/internal/debug"
	"github.com/yourorg/wayfindcl/internal/geometry"
	"github.com/yourorg/wayfindcl/internal/handlers"
	"github.com/yourorg/wayfindcl/internal/middleware"
)

// Variable global para configurar RedBusHandler después de inicializar geometría
var redBusHandlerInstance *handlers.RedBusHandler

func Register(app *fiber.App, db *sql.DB) {
	// ============================================================================
	// API PÚBLICA (Endpoints para el frontend)
	// ============================================================================
	api := app.Group("/api")

	// Health check (sin rate limiting)
	api.Get("/health", handlers.Health)
	
	// ============================================================================
	// AUTENTICACIÓN (con rate limiting estricto)
	// ============================================================================
	authGroup := api.Group("/auth")
	authGroup.Use(middleware.StrictRateLimiter()) // 10 req/min
	
	// Autenticación biométrica (para usuarios con discapacidad visual)
	authGroup.Post("/biometric/register", handlers.BiometricRegister)
	authGroup.Post("/biometric/login", handlers.BiometricLogin)
	
	// Autenticación tradicional (username + password) - con rate limiting
	api.Post("/login", middleware.StrictRateLimiter(), handlers.Login)
	api.Post("/register", middleware.StrictRateLimiter(), handlers.Register)
	
	// Verificar si un token biométrico ya existe
	api.Post("/biometric/check", middleware.StrictRateLimiter(), handlers.CheckBiometricExists)

	// Initialize GraphHopper (inicia como subproceso del backend)
	handlers.InitGraphHopper()

	// Initialize handlers
	incidentHandler := handlers.NewIncidentHandler(db)
	locationShareHandler := handlers.NewLocationShareHandler(db)
	tripHistoryHandler := handlers.NewTripHistoryHandler(db)
	notificationPrefsHandler := handlers.NewNotificationPreferencesHandler(db)
	redBusHandler := handlers.NewRedBusHandler(db)
	busArrivalsHandler := handlers.NewBusArrivalsHandler(db)
	statsHandler := handlers.NewStatsHandler(db)
	gtfsStatsHandler := handlers.NewGTFSStatsHandler(db)
	dbStatsHandler := handlers.NewDatabaseStatsHandler(db)
	statusHandler := handlers.NewStatusHandler(db)
	metricsHandler := handlers.NewMetricsHandler(db)
	
	// Guardar referencia global para configuración posterior
	redBusHandlerInstance = redBusHandler

	// Status endpoint para el dashboard
	api.Get("/status", statusHandler.GetStatus)

	// ============================================================================
	// GEOMETRY ENDPOINTS (CENTRALIZADOS - Reemplazan routing antiguo)
	// ============================================================================
	// NUEVO: Servicio unificado de geometría que integra:
	//   - GraphHopper (routing engine)
	//   - GTFS (base de datos de paradas)
	//   - Cálculos geométricos propios
	// ============================================================================
	geometry := api.Group("/geometry")
	
	// ────────────────────────────────────────────────────────────────────────
	// GEOMETRÍA DE RUTAS
	// ────────────────────────────────────────────────────────────────────────
	geometry.Get("/walking", handlers.GetWalkingGeometry)
	// GET /api/geometry/walking?from_lat=X&from_lon=Y&to_lat=X&to_lon=Y&detailed=true
	// Geometría peatonal completa o solo distancia/tiempo
	
	geometry.Get("/driving", handlers.GetDrivingGeometry)
	// GET /api/geometry/driving?from_lat=X&from_lon=Y&to_lat=X&to_lon=Y
	// Geometría vehicular completa
	
	geometry.Post("/transit", handlers.GetTransitGeometry)
	// POST /api/geometry/transit
	// Body: {from_lat, from_lon, to_lat, to_lon, departure_time}
	// Geometría de transporte público (GTFS + GraphHopper)
	
	// ────────────────────────────────────────────────────────────────────────
	// PARADAS Y BÚSQUEDA ESPACIAL
	// ────────────────────────────────────────────────────────────────────────
	geometry.Get("/stops/nearby", handlers.GetNearbyStopsWithDistance)
	// GET /api/geometry/stops/nearby?lat=X&lon=Y&radius=400&real_distance=true
	// Paradas cercanas con distancia REAL (no euclidiana)
	
	// ────────────────────────────────────────────────────────────────────────
	// GEOMETRÍA DE BUSES - SEGMENTOS ESPECÍFICOS
	// ────────────────────────────────────────────────────────────────────────
	api.Post("/bus/geometry/segment", handlers.GetBusRouteSegment)
	// POST /api/bus/geometry/segment
	// Body: {route_number, from_stop_code, to_stop_code, from_lat, from_lon, to_lat, to_lon}
	// Obtiene geometría EXACTA entre dos paraderos usando GTFS shapes + GraphHopper fallback
	
	// ────────────────────────────────────────────────────────────────────────
	// CÁLCULOS BATCH Y AVANZADOS
	// ────────────────────────────────────────────────────────────────────────
	geometry.Post("/batch/walking-times", handlers.GetBatchWalkingTimes)
	// POST /api/geometry/batch/walking-times
	// Body: {from_lat, from_lon, destinations: [{lat, lon}, ...]}
	// Calcula tiempo de caminata a MÚLTIPLES destinos simultáneamente
	
	geometry.Get("/isochrone", handlers.GetWalkingIsochrone)
	// GET /api/geometry/isochrone?lat=X&lon=Y&minutes=10
	// Calcula área alcanzable en X minutos (isócrona)
	// Útil para: "¿A qué paradas puedo llegar en 10 minutos?"
	
	geometry.Get("/stats", handlers.GetGeometryStats)
	// GET /api/geometry/stats
	// Estadísticas del sistema de geometría

	// ============================================================================
	// ROUTING ENDPOINTS (LEGACY - Mantener compatibilidad)
	// ============================================================================
	// NOTA: Estos endpoints ahora redirigen internamente al servicio de geometría
	// Se mantienen para compatibilidad con frontend existente
	// ============================================================================
	route := api.Group("/route")
	
	// ────────────────────────────────────────────────────────────────────────
	// RUTAS PEATONALES
	// ────────────────────────────────────────────────────────────────────────
	route.Get("/walking", handlers.GetFootRoute) 
	// GET /api/route/walking?origin_lat=X&origin_lon=Y&dest_lat=X&dest_lon=Y
	// Retorna: geometría completa + instrucciones
	
	route.Get("/walking/distance", handlers.GetWalkingDistance)
	// GET /api/route/walking/distance?origin_lat=X&origin_lon=Y&dest_lat=X&dest_lon=Y
	// Ultra rápido - solo distancia y tiempo (sin geometría)
	
	// ────────────────────────────────────────────────────────────────────────
	// RUTAS EN AUTOMÓVIL
	// ────────────────────────────────────────────────────────────────────────
	route.Get("/driving", handlers.GetDrivingRoute)
	// GET /api/route/driving?origin_lat=X&origin_lon=Y&dest_lat=X&dest_lon=Y
	// Retorna: ruta en auto con geometría + instrucciones
	
	// ────────────────────────────────────────────────────────────────────────
	// RUTAS CON TRANSPORTE PÚBLICO (GTFS)
	// ────────────────────────────────────────────────────────────────────────
	route.Post("/transit", handlers.GetPublicTransitRoute)
	// POST /api/route/transit
	// Body: {origin, destination, departure_time, max_walk_distance}
	// Retorna: TODAS las alternativas disponibles (hasta 5)
	
	route.Post("/transit/quick", handlers.GetQuickTransitRoute)
	// POST /api/route/transit/quick
	// Body: {origin, destination, departure_time}
	// Retorna: Solo la ruta MÁS RÁPIDA
	
	route.Post("/transit/optimal", handlers.GetOptimalTransitRoute)
	// POST /api/route/transit/optimal
	// Body: {origin, destination, departure_time, preferences: {minimize_transfers, minimize_walking}}
	// Retorna: Ruta ÓPTIMA según preferencias del usuario
	
	// ────────────────────────────────────────────────────────────────────────
	// OPCIONES DE RUTA (Resumen)
	// ────────────────────────────────────────────────────────────────────────
	route.Post("/options", handlers.GetRouteOptions)
	// POST /api/route/options
	// Body: {origin, destination}
	// Retorna: Resumen de TODAS las opciones (peatonal + transit) sin geometría
	// Ideal para mostrar opciones al usuario antes de cargar geometría completa

	// ============================================================================
	// STOPS (Paradas de transporte público)
	// ============================================================================
	api.Get("/stops", handlers.GetNearbyStops)
	// GET /api/stops?lat=X&lon=Y&radius=400&limit=20
	
	api.Get("/stops/code/:code", handlers.GetStopByCode)
	// GET /api/stops/code/PC1237

	// ============================================================================
	// RED BUS (Moovit - Información específica de rutas Red)
	// RATE LIMITING: ScrapingRateLimiter (5 req/5min) - operación costosa
	// ============================================================================
	red := api.Group("/red")
	red.Use(middleware.ScrapingRateLimiter()) // Aplicar rate limiting estricto
	
	red.Get("/routes/common", redBusHandler.ListCommonRedRoutes)
	red.Get("/routes/search", redBusHandler.SearchRedRoutes)
	red.Get("/route/:routeNumber", redBusHandler.GetRedBusRoute)
	red.Get("/route/:routeNumber/stops", redBusHandler.GetRedBusStops)
	red.Get("/route/:routeNumber/geometry", redBusHandler.GetRedBusGeometry)
	red.Post("/itinerary", redBusHandler.GetRedBusItinerary)
	red.Post("/itinerary/options", redBusHandler.GetRedBusItineraryOptions)
	red.Post("/itinerary/detail", redBusHandler.GetRedBusItineraryDetail)

	// ============================================================================
	// BUS ARRIVALS (Llegadas en tiempo real desde Red.cl)
	// ============================================================================
	arrivals := api.Group("/bus-arrivals")
	arrivals.Get("/:stopCode", busArrivalsHandler.GetBusArrivals)
	// GET /api/bus-arrivals/PC615 - Obtiene buses próximos al paradero
	
	arrivals.Post("/nearby", busArrivalsHandler.GetBusArrivalsByLocation)
	// POST /api/bus-arrivals/nearby - Obtiene llegadas del paradero más cercano

	// ============================================================================
	// INCIDENTS (Reportes de incidentes)
	// ============================================================================
	incidents := api.Group("/incidents")
	incidents.Post("/", incidentHandler.CreateIncident)
	incidents.Get("/nearby", incidentHandler.GetNearbyIncidents)
	incidents.Get("/route", incidentHandler.GetIncidentsByRoute)
	incidents.Get("/stats", incidentHandler.GetIncidentStats)
	incidents.Get("/:id", incidentHandler.GetIncidentByID)
	incidents.Put("/:id/vote", incidentHandler.VoteIncident)

	// ============================================================================
	// LOCATION SHARING (Compartir ubicación en tiempo real)
	// ============================================================================
	shares := api.Group("/shares")
	shares.Post("/", locationShareHandler.CreateLocationShare)
	shares.Get("/:id", locationShareHandler.GetLocationShare)
	shares.Put("/:id/location", locationShareHandler.UpdateLocationShare)
	shares.Delete("/:id", locationShareHandler.StopLocationShare)
	shares.Get("/", locationShareHandler.GetUserShares)

	// ============================================================================
	// TRIP HISTORY (Historial de viajes)
	// ============================================================================
	trips := api.Group("/trips")
	trips.Post("/", tripHistoryHandler.SaveTrip)
	trips.Get("/", tripHistoryHandler.GetUserTrips)
	trips.Get("/frequent", tripHistoryHandler.GetFrequentLocations)
	trips.Get("/stats", tripHistoryHandler.GetTripStatistics)
	trips.Get("/suggestions", tripHistoryHandler.GetTripSuggestions)

	// ============================================================================
	// USER PREFERENCES (Preferencias de notificaciones)
	// ============================================================================
	prefs := api.Group("/preferences")
	prefs.Get("/notifications", notificationPrefsHandler.GetNotificationPreferences)
	prefs.Put("/notifications", notificationPrefsHandler.UpdateNotificationPreferences)

	// ============================================================================
	// STATISTICS (Estadísticas y métricas del sistema)
	// ============================================================================
	stats := api.Group("/stats")
	stats.Get("/system", statsHandler.GetSystemStats)
	// GET /api/stats/system - Estadísticas generales del sistema (CPU, memoria, DB, etc.)
	
	stats.Get("/routes", statsHandler.GetRouteStats)
	// GET /api/stats/routes?days=7 - Estadísticas de rutas solicitadas
	
	stats.Get("/users", statsHandler.GetUserStats)
	// GET /api/stats/users - Estadísticas de usuarios (totales, activos, crecimiento)
	
	stats.Get("/buses", statsHandler.GetBusStats)
	// GET /api/stats/buses?days=7 - Estadísticas de transporte público
	
	stats.Get("/gtfs", gtfsStatsHandler.GetGTFSStats)
	// GET /api/stats/gtfs - Estadísticas completas del sistema GTFS
	
	stats.Get("/gtfs/routes", gtfsStatsHandler.GetTopRoutes)
	// GET /api/stats/gtfs/routes?limit=10 - Top rutas del GTFS
	
	stats.Get("/database", dbStatsHandler.GetDatabaseReport)
	// GET /api/stats/database - Reporte completo de la base de datos
	
	stats.Get("/scraper", dbStatsHandler.GetScraperMetrics)
	// GET /api/stats/scraper - Métricas de scraping de Moovit
	
	stats.Get("/graphhopper", dbStatsHandler.GetGraphHopperMetrics)
	// GET /api/stats/graphhopper - Métricas del motor de routing GraphHopper
	
	stats.Get("/metrics", metricsHandler.GetMetrics)
	// GET /api/stats/metrics - Métricas en tiempo real del sistema (CPU, memoria, usuarios, requests)

	// ============================================================================
	// INTERNAL/ADMIN ENDPOINTS (No expuestos al frontend)
	// ============================================================================
	// NOTA: gtfs/sync se maneja automáticamente en la inicialización del servidor
	// No es necesario exponerlo como endpoint público
	
	// ============================================================================
	// DEBUG DASHBOARD WEBSOCKET
	// ============================================================================
	// Endpoints para recibir logs y eventos desde la app Flutter
	debugApi := api.Group("/debug")
	debugApi.Post("/log", handlers.ReceiveFlutterLog)
	debugApi.Post("/event", handlers.ReceiveFlutterEvent)
	debugApi.Post("/error", handlers.ReceiveFlutterError)
	debugApi.Post("/metrics", handlers.ReceiveFlutterMetrics)
	debugApi.Post("/navigation", handlers.ReceiveNavigationEvent)
	
	// WebSocket para el dashboard web (siempre disponible)
	app.Use("/ws/debug", func(c *fiber.Ctx) error {
		if websocket.IsWebSocketUpgrade(c) {
			return c.Next()
		}
		return fiber.ErrUpgradeRequired
	})
	
	app.Get("/ws/debug", websocket.New(func(c *websocket.Conn) {
		debug.HandleWebSocketFiber(c)
	}))
}

// ConfigureRedBusGeometry configura el servicio de geometría para RedBusHandler
// Debe llamarse DESPUÉS de Register(), cuando geometryService esté inicializado
func ConfigureRedBusGeometry(geometrySvc *geometry.Service) {
	if redBusHandlerInstance != nil {
		redBusHandlerInstance.ConfigureRedBusGeometry(geometrySvc)
	}
}
