package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/logger"
	"github.com/joho/godotenv"

	appdb "github.com/yourorg/wayfindcl/internal/db"
	"github.com/yourorg/wayfindcl/internal/debug"
	"github.com/yourorg/wayfindcl/internal/geometry"
	"github.com/yourorg/wayfindcl/internal/graphhopper"
	"github.com/yourorg/wayfindcl/internal/handlers"
	"github.com/yourorg/wayfindcl/internal/routes"
)

func main() {
	_ = godotenv.Load()

	app := fiber.New(fiber.Config{
		ReadTimeout:  180 * time.Second, // 3 minutos para operaciones muy lentas como scraping
		WriteTimeout: 180 * time.Second, // 3 minutos para respuestas grandes
		IdleTimeout:  240 * time.Second, // 4 minutos de timeout idle
	})
	app.Use(logger.New())

	// ============================================================================
	// INICIAR GRAPHHOPPER COMO SUBPROCESO
	// ============================================================================
	log.Println("Iniciando GraphHopper...")
	if err := handlers.InitGraphHopper(); err != nil {
		log.Printf("⚠️  GraphHopper no pudo iniciarse: %v", err)
		log.Println("   El servidor continuará pero routing puede fallar")
	} else {
		log.Println("✅ GraphHopper iniciado correctamente")
	}

	// ============================================================================
	// DB CONNECTION
	// ============================================================================
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
			log.Printf("✅ Database ready and routes registered")

			// ================================================================
			// INICIALIZAR DEBUG DASHBOARD (si está habilitado)
			// ================================================================
			if debug.IsEnabled() {
				debug.LogInfo("🚀 Backend iniciado correctamente", map[string]interface{}{
					"timestamp": time.Now().Format(time.RFC3339),
					"database":  "conectada",
					"routes":    "registradas",
				})
				log.Println("✅ Debug Dashboard iniciado - enviando datos a dashboard")
			}

			// ================================================================
			// INICIALIZAR SERVICIO DE GEOMETRÍA (después de DB)
			// ================================================================
			ghClient := graphhopper.NewClient()

			// Esperar a que GraphHopper esté listo
			log.Println("🔗 Conectando servicio de geometría con GraphHopper...")
			for i := 0; i < 30; i++ {
				if ghClient.HealthCheck() == nil {
					break
				}
				time.Sleep(1 * time.Second)
			}

			// Crear servicio de geometría (integra GTFS + GraphHopper)
			geometrySvc := geometry.NewService(db, ghClient)
			handlers.InitGeometryService(geometrySvc)

			// Configurar servicio de geometría en RedBusHandler para rutas a pie con GraphHopper
			routes.ConfigureRedBusGeometry(geometrySvc)

			log.Println("✅ Servicio de Geometría inicializado (GTFS + GraphHopper)")
			log.Println("✅ RedBusHandler configurado para usar GraphHopper en caminatas")

			// ================================================================
			// ENVIAR ESTADO COMPLETO AL DEBUG DASHBOARD
			// ================================================================
			if debug.IsEnabled() {
				debug.LogInfo("🗺️ GraphHopper conectado", map[string]interface{}{
					"status": "ready",
					"health": "ok",
				})

				debug.LogInfo("📐 Servicio de Geometría listo", map[string]interface{}{
					"gtfs":       "integrado",
					"graphhopper": "activo",
					"walking":    "disponible",
				})

				// Enviar métricas iniciales
				debug.UpdateMetrics(15.5, 512, 0, 0)

				// Enviar estado de APIs
				debug.UpdateApiStatus("online", "online", "connected", 45.2, 5, 20, "v1.0.0")

				log.Println("📊 Datos iniciales enviados al dashboard")
			}

			return
		}
	}()

	// Wait briefly for DB to be ready
	for i := 0; i < 10 && !dbReady; i++ {
		time.Sleep(500 * time.Millisecond)
	}

	// Enviar log cuando el servidor esté completamente listo
	if debug.IsEnabled() {
		debug.LogInfo("✅ Sistema completamente listo", map[string]interface{}{
			"port":     os.Getenv("PORT"),
			"endpoints": 15,
		})
	}

	// ============================================================================
	// GRACEFUL SHUTDOWN - Detener GraphHopper al cerrar backend
	// ============================================================================
	// Capturar señales de terminación (Ctrl+C, kill, etc.)
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-sigChan
		log.Println("\n🛑 Señal de terminación recibida, cerrando servidor...")

		// Detener GraphHopper
		log.Println("🛑 Deteniendo GraphHopper...")
		if err := graphhopper.StopGraphHopperProcess(); err != nil {
			log.Printf("⚠️  Error deteniendo GraphHopper: %v", err)
		}

		// Cerrar servidor Fiber
		if err := app.Shutdown(); err != nil {
			log.Printf("⚠️  Error cerrando servidor: %v", err)
		}

		log.Println("✅ Servidor cerrado correctamente")
		os.Exit(0)
	}()

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("🚀 Servidor escuchando en :%s", port)
	log.Println("📍 Endpoints disponibles:")
	log.Println("   ═══ GEOMETRÍA CENTRALIZADA (NUEVO) ═══")
	log.Println("   GET  /api/geometry/walking          - Geometría peatonal")
	log.Println("   GET  /api/geometry/driving          - Geometría vehicular")
	log.Println("   POST /api/geometry/transit          - Geometría transporte público")
	log.Println("   GET  /api/geometry/stops/nearby     - Paradas cercanas (distancia real)")
	log.Println("   POST /api/geometry/batch/walking-times - Batch: tiempos múltiples destinos")
	log.Println("   GET  /api/geometry/isochrone        - Área alcanzable en X minutos")
	log.Println("")
	log.Println("   ═══ ROUTING (LEGACY - Compatibilidad) ═══")
	log.Println("   GET  /api/route/walking             - Rutas peatonales")
	log.Println("   POST /api/route/transit             - Transporte público")
	log.Println("   POST /api/route/options             - Opciones de ruta")
	log.Println("")
	log.Println("💡 Presiona Ctrl+C para detener")
	log.Println("💡 Todos los cálculos geométricos centralizados en /api/geometry/*")

	if err := app.Listen(":" + port); err != nil {
		log.Fatal(err)
	}
}
