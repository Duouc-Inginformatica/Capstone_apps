package routes

import (
	"database/sql"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/handlers"
)

func Register(app *fiber.App, db *sql.DB) {
	api := app.Group("/api")

	// Existing routes
	api.Get("/health", handlers.Health)
	api.Post("/login", handlers.Login)
	api.Post("/register", handlers.Register)
	api.Post("/gtfs/sync", handlers.SyncGTFS)
	api.Get("/stops", handlers.GetNearbyStops)
	api.Get("/stops/code/:code", handlers.GetStopByCode) // Buscar paradero por código (PC1237, etc.)

	// Initialize new handlers
	incidentHandler := handlers.NewIncidentHandler(db)
	locationShareHandler := handlers.NewLocationShareHandler(db)
	tripHistoryHandler := handlers.NewTripHistoryHandler(db)
	notificationPrefsHandler := handlers.NewNotificationPreferencesHandler(db)
	redBusHandler := handlers.NewRedBusHandler(db) // Ahora recibe db para consultas GTFS

	// Red Bus routes (Moovit scraping)
	red := api.Group("/red")
	red.Get("/routes/common", redBusHandler.ListCommonRedRoutes)
	red.Get("/routes/search", redBusHandler.SearchRedRoutes)
	red.Get("/route/:routeNumber", redBusHandler.GetRedBusRoute)
	red.Get("/route/:routeNumber/stops", redBusHandler.GetRedBusStops)
	red.Get("/route/:routeNumber/geometry", redBusHandler.GetRedBusGeometry)
	red.Post("/itinerary", redBusHandler.GetRedBusItinerary) // Método antiguo (mantener para compatibilidad)
	
	// Nuevos endpoints de dos fases para usuarios ciegos (selección por voz)
	red.Post("/itinerary/options", redBusHandler.GetRedBusItineraryOptions) // FASE 1: Opciones ligeras
	red.Post("/itinerary/detail", redBusHandler.GetRedBusItineraryDetail)   // FASE 2: Geometría completa

	// Incident routes
	incidents := api.Group("/incidents")
	incidents.Post("/", incidentHandler.CreateIncident)
	incidents.Get("/nearby", incidentHandler.GetNearbyIncidents)
	incidents.Get("/route", incidentHandler.GetIncidentsByRoute)
	incidents.Get("/stats", incidentHandler.GetIncidentStats)
	incidents.Get("/:id", incidentHandler.GetIncidentByID)
	incidents.Put("/:id/vote", incidentHandler.VoteIncident)

	// Location sharing routes
	shares := api.Group("/shares")
	shares.Post("/", locationShareHandler.CreateLocationShare)
	shares.Get("/:id", locationShareHandler.GetLocationShare)
	shares.Put("/:id/location", locationShareHandler.UpdateLocationShare)
	shares.Delete("/:id", locationShareHandler.StopLocationShare)
	shares.Get("/", locationShareHandler.GetUserShares)

	// Trip history routes
	trips := api.Group("/trips")
	trips.Post("/", tripHistoryHandler.SaveTrip)
	trips.Get("/", tripHistoryHandler.GetUserTrips)
	trips.Get("/frequent", tripHistoryHandler.GetFrequentLocations)
	trips.Get("/stats", tripHistoryHandler.GetTripStatistics)
	trips.Get("/suggestions", tripHistoryHandler.GetTripSuggestions)

	// Notification preferences routes
	prefs := api.Group("/preferences")
	prefs.Get("/notifications", notificationPrefsHandler.GetNotificationPreferences)
	prefs.Put("/notifications", notificationPrefsHandler.UpdateNotificationPreferences)
}
