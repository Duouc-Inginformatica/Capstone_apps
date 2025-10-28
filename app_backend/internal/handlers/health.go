package handlers

import (
	"context"
	"os"
	"time"

	"github.com/gofiber/fiber/v2"
)

// HealthResponse representa el estado de salud del sistema
type HealthResponse struct {
	Status    string            `json:"status"`
	Timestamp time.Time         `json:"timestamp"`
	Services  map[string]string `json:"services"`
	Version   string            `json:"version,omitempty"`
}

// Health proporciona un health check completo del sistema
func Health(c *fiber.Ctx) error {
	services := make(map[string]string)
	overall := "healthy"

	// ============================================================================
	// CHECK: Base de Datos
	// ============================================================================
	setupMu.RLock()
	db := dbConn
	setupMu.RUnlock()
	
	if db != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		
		if err := db.PingContext(ctx); err != nil {
			services["database"] = "unhealthy: " + err.Error()
			overall = "degraded"
		} else {
			services["database"] = "healthy"
		}
	} else {
		services["database"] = "not_initialized"
		overall = "degraded"
	}

	// ============================================================================
	// CHECK: GraphHopper
	// ============================================================================
	ghClient := getGHClient() // Usar la función del paquete graphhopper_routes
	if ghClient != nil {
		if err := ghClient.HealthCheck(); err != nil {
			services["graphhopper"] = "unhealthy: " + err.Error()
			overall = "degraded"
		} else {
			services["graphhopper"] = "healthy"
		}
	} else {
		services["graphhopper"] = "not_initialized"
		overall = "degraded"
	}

	// ============================================================================
	// CHECK: GTFS Data
	// ============================================================================
	if db != nil {
		var count int
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		
		err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM gtfs_stops").Scan(&count)
		if err != nil {
			services["gtfs_data"] = "unhealthy: " + err.Error()
			overall = "degraded"
		} else if count == 0 {
			services["gtfs_data"] = "empty"
			overall = "degraded"
		} else {
			services["gtfs_data"] = "healthy"
		}
	} else {
		services["gtfs_data"] = "unavailable"
	}

	// ============================================================================
	// Determinar código de estado HTTP
	// ============================================================================
	statusCode := fiber.StatusOK
	if overall == "degraded" {
		statusCode = fiber.StatusServiceUnavailable
	}

	return c.Status(statusCode).JSON(HealthResponse{
		Status:    overall,
		Timestamp: time.Now(),
		Services:  services,
		Version:   os.Getenv("APP_VERSION"),
	})
}
