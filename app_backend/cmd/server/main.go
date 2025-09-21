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

	app := fiber.New()
	app.Use(logger.New())

	// DB connection with background retries; do not exit if unavailable
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
			log.Printf("database ready")
			return
		}
	}()

	routes.Register(app)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("server listening on :%s", port)
	if err := app.Listen(":" + port); err != nil {
		log.Fatal(err)
	}
}
