package middleware

import (
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/limiter"
)

// RateLimiter crea un middleware de rate limiting
func RateLimiter() fiber.Handler {
	return limiter.New(limiter.Config{
		Max:        100,                 // 100 requests
		Expiration: 1 * time.Minute,     // por minuto
		KeyGenerator: func(c *fiber.Ctx) string {
			return c.IP() // Limitar por IP
		},
		LimitReached: func(c *fiber.Ctx) error {
			return c.Status(fiber.StatusTooManyRequests).JSON(fiber.Map{
				"error":       "rate limit exceeded",
				"message":     "demasiadas solicitudes, intenta de nuevo en un minuto",
				"retry_after": 60,
			})
		},
		SkipFailedRequests:     false, // Contar requests fallidos
		SkipSuccessfulRequests: false, // Contar requests exitosos
		Storage:                nil,   // Usar almacenamiento en memoria (default)
	})
}

// StrictRateLimiter crea un rate limiter más estricto para endpoints sensibles
func StrictRateLimiter() fiber.Handler {
	return limiter.New(limiter.Config{
		Max:        10,              // Solo 10 requests
		Expiration: 1 * time.Minute, // por minuto
		KeyGenerator: func(c *fiber.Ctx) string {
			return c.IP()
		},
		LimitReached: func(c *fiber.Ctx) error {
			return c.Status(fiber.StatusTooManyRequests).JSON(fiber.Map{
				"error":       "rate limit exceeded",
				"message":     "demasiadas solicitudes de autenticación, intenta de nuevo en un minuto",
				"retry_after": 60,
			})
		},
	})
}

// ScrapingRateLimiter para endpoints de scraping (muy limitado)
func ScrapingRateLimiter() fiber.Handler {
	return limiter.New(limiter.Config{
		Max:        5,                // Solo 5 requests
		Expiration: 5 * time.Minute,  // cada 5 minutos
		KeyGenerator: func(c *fiber.Ctx) string {
			return c.IP()
		},
		LimitReached: func(c *fiber.Ctx) error {
			return c.Status(fiber.StatusTooManyRequests).JSON(fiber.Map{
				"error":       "rate limit exceeded",
				"message":     "demasiadas solicitudes de scraping, intenta de nuevo en 5 minutos",
				"retry_after": 300,
			})
		},
	})
}
