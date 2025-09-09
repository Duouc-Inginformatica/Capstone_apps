package routes

import (
	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/handlers"
)

func Register(app *fiber.App) {
	api := app.Group("/api")
	api.Get("/health", handlers.Health)
	api.Post("/login", handlers.Login)
}
