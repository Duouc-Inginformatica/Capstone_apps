package middleware

import (
	"runtime"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/debug"
)

// MetricsMiddleware captura métricas de cada request
func MetricsMiddleware() fiber.Handler {
	return func(c *fiber.Ctx) error {
		if !debug.IsEnabled() {
			return c.Next()
		}

		start := time.Now()
		
		// Procesar request
		err := c.Next()
		
		// Calcular duración
		duration := time.Since(start)
		
		// Enviar log al dashboard
		metadata := map[string]interface{}{
			"method":      c.Method(),
			"path":        c.Path(),
			"status":      c.Response().StatusCode(),
			"duration_ms": duration.Milliseconds(),
			"ip":          c.IP(),
		}

		level := "info"
		if c.Response().StatusCode() >= 400 {
			level = "warn"
		}
		if c.Response().StatusCode() >= 500 {
			level = "error"
		}

		message := c.Method() + " " + c.Path()
		
		debug.SendLog("backend", level, message, metadata)
		
		return err
	}
}

// PeriodicMetricsCollector envía métricas periódicamente al dashboard
func PeriodicMetricsCollector(interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for range ticker.C {
		if !debug.IsEnabled() {
			continue
		}

		// Aquí podrías calcular métricas más complejas
		// Por ahora solo enviamos un log de heartbeat
		debug.SendLog("backend", "debug", "System heartbeat", map[string]interface{}{
			"goroutines": runtime.NumGoroutine(),
		})
	}
}
