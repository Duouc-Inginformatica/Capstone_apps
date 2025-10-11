package main

import (
	"log"
	"os"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/logger"
	"github.com/joho/godotenv"

	appdb "github.com/yourorg/wayfindcl/internal/db"
	"github.com/yourorg/wayfindcl/internal/handlers"
	"github.com/yourorg/wayfindcl/internal/routes"
)

func main() {
	_ = godotenv.Load()

	// Debug: verificar variables de entorno
	log.Printf("DEBUG: GRAPHHOPPER_BASE_URL = '%s'", os.Getenv("GRAPHHOPPER_BASE_URL"))
	log.Printf("DEBUG: GRAPHHOPPER_API_KEY = '%s'", os.Getenv("GRAPHHOPPER_API_KEY"))

	app := fiber.New()
	app.Use(logger.New())

	// DB connection with background retries; do not exit if unavailable
	var dbReady bool
	go func() {
		for {
			db, err := appdb.Connect()
			if err != nil {
				log.Printf("db connect error: %v (retrying in 5s)", err)
				time.Sleep(5 * time.Second)
				continue
			}
			if err := appdb.EnsureSchema(db); err != nil {
				log.Printf("ensure schema error: %v (retrying in 5s)", err)
				time.Sleep(5 * time.Second)
				continue
			}
			handlers.Setup(db)
			routes.Register(app, db)
			dbReady = true
			log.Printf("database ready and routes registered")
			return
		}
	}()

	// Wait briefly for DB to be ready
	for i := 0; i < 10 && !dbReady; i++ {
		time.Sleep(500 * time.Millisecond)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("server listening on :%s", port)
	if err := app.Listen(":" + port); err != nil {
		log.Fatal(err)
	}
}
