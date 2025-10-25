package middleware

import (
	"fmt"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/debug"
)

// DashboardLogger middleware para enviar logs al dashboard en tiempo real
func DashboardLogger() fiber.Handler {
	return func(c *fiber.Ctx) error {
		start := time.Now()
		
		// Procesar request
		err := c.Next()
		
		// Calcular duración
		duration := time.Since(start)
		
		// Determinar nivel de log basado en el status code
		level := "info"
		status := c.Response().StatusCode()
		
		if status >= 500 {
			level = "error"
		} else if status >= 400 {
			level = "warn"
		} else if status >= 200 && status < 300 {
			level = "info"
		}

		// Determinar fuente basada en la ruta
		source := "backend"
		path := c.Path()
		if len(path) > 15 && path[:15] == "/api/graphhopper" {
			source = "graphhopper"
		} else if len(path) > 11 && path[:11] == "/api/geometry" {
			source = "graphhopper"
		}

		// Crear mensaje de log
		message := fmt.Sprintf("%s %s", c.Method(), path)
		
		// Agregar metadata
		metadata := map[string]interface{}{
			"method":      c.Method(),
			"path":        path,
			"status":      status,
			"duration_ms": duration.Milliseconds(),
			"ip":          c.IP(),
		}

		// Enviar al dashboard (siempre, el hub decidirá si hay clientes)
		debug.SendLog(source, level, message, metadata)

		return err
	}
}
