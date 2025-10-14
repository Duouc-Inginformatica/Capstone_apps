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
	api.Post("/route/transit", handlers.PlanTransit)

	// Initialize handlers with database
	handler := handlers.NewHandler(db)

	// New public transit route using GTFS data
	api.Post("/route/public-transit", handler.PublicTransitRoute)

	// Initialize new handlers
	incidentHandler := handlers.NewIncidentHandler(db)
	locationShareHandler := handlers.NewLocationShareHandler(db)
	tripHistoryHandler := handlers.NewTripHistoryHandler(db)
	notificationPrefsHandler := handlers.NewNotificationPreferencesHandler(db)

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
