package routes

import (
	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/handlers"
)

func Register(app *fiber.App) {
	api := app.Group("/api")
	api.Get("/health", handlers.Health)
	api.Post("/login", handlers.Login)
	api.Post("/register", handlers.Register)
	api.Post("/gtfs/sync", handlers.SyncGTFS)
	api.Get("/stops", handlers.GetNearbyStops)
	api.Post("/route/transit", handlers.PlanTransit)
}
