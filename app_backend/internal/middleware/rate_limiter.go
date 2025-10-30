package middleware

import (
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/limiter"
)

// ============================================================================
// RATE LIMITING MIDDLEWARE
// ============================================================================
// Protege el backend contra abuso y ataques DDoS
// Implementa diferentes niveles según criticidad del endpoint

// GlobalRateLimiter - Limitador general para todos los endpoints
// 1000 requests por minuto por IP (producción moderada)
func GlobalRateLimiter() fiber.Handler {
	return limiter.New(limiter.Config{
		Max:        1000,
		Expiration: 1 * time.Minute,
		KeyGenerator: func(c *fiber.Ctx) string {
			return c.IP()
		},
		LimitReached: func(c *fiber.Ctx) error {
			return c.Status(fiber.StatusTooManyRequests).JSON(fiber.Map{
				"error":       "Rate limit exceeded",
				"retry_after": 60,
				"message":     "Too many requests. Please try again in 1 minute.",
			})
		},
		SkipFailedRequests:     false,
		SkipSuccessfulRequests: false,
		LimiterMiddleware:      limiter.SlidingWindow{},
	})
}

// AuthRateLimiter - Limitador para endpoints de autenticación
// 10 requests por minuto (protege contra fuerza bruta)
func AuthRateLimiter() fiber.Handler {
	return limiter.New(limiter.Config{
		Max:        10,
		Expiration: 1 * time.Minute,
		KeyGenerator: func(c *fiber.Ctx) string {
			// Rate limit por IP + endpoint para mejor granularidad
			return c.IP() + ":" + c.Path()
		},
		LimitReached: func(c *fiber.Ctx) error {
			return c.Status(fiber.StatusTooManyRequests).JSON(fiber.Map{
				"error":       "Authentication rate limit exceeded",
				"retry_after": 60,
				"message":     "Too many login attempts. Please try again in 1 minute.",
			})
		},
		LimiterMiddleware: limiter.SlidingWindow{},
	})
}

// APIRateLimiter - Limitador para endpoints de API general
// 200 requests por minuto (balance entre usabilidad y protección)
func APIRateLimiter() fiber.Handler {
	return limiter.New(limiter.Config{
		Max:        200,
		Expiration: 1 * time.Minute,
		KeyGenerator: func(c *fiber.Ctx) string {
			return c.IP()
		},
		LimitReached: func(c *fiber.Ctx) error {
			return c.Status(fiber.StatusTooManyRequests).JSON(fiber.Map{
				"error":       "API rate limit exceeded",
				"retry_after": 60,
				"limit":       200,
				"window":      "1 minute",
			})
		},
		LimiterMiddleware: limiter.SlidingWindow{},
	})
}

// ExpensiveOperationLimiter - Para operaciones costosas (scraping, cálculos complejos)
// 5 requests cada 5 minutos
func ExpensiveOperationLimiter() fiber.Handler {
	return limiter.New(limiter.Config{
		Max:        5,
		Expiration: 5 * time.Minute,
		KeyGenerator: func(c *fiber.Ctx) string {
			return c.IP()
		},
		LimitReached: func(c *fiber.Ctx) error {
			return c.Status(fiber.StatusTooManyRequests).JSON(fiber.Map{
				"error":       "Expensive operation rate limit exceeded",
				"retry_after": 300,
				"message":     "This operation is rate-limited to 5 requests per 5 minutes.",
			})
		},
		LimiterMiddleware: limiter.SlidingWindow{},
	})
}

// ============================================================================
// CONFIGURACIÓN AVANZADA DE RATE LIMITING
// ============================================================================

// AdaptiveRateLimiter - Ajusta límites según load del servidor
// En desarrollo - implementación futura
func AdaptiveRateLimiter() fiber.Handler {
	// TODO: Implementar rate limiting adaptativo basado en:
	// - CPU usage
	// - Memory usage
	// - Active connections
	// - Response time
	return func(c *fiber.Ctx) error {
		return c.Next()
	}
}

// UserBasedRateLimiter - Rate limiting por usuario autenticado
// Permite límites más altos para usuarios premium/autenticados
func UserBasedRateLimiter(maxRequests int, window time.Duration) fiber.Handler {
	return limiter.New(limiter.Config{
		Max:        maxRequests,
		Expiration: window,
		KeyGenerator: func(c *fiber.Ctx) string {
			// Intentar obtener user_id del contexto (si está autenticado)
			if userID := c.Locals("user_id"); userID != nil {
				return "user:" + userID.(string)
			}
			// Fallback a IP si no está autenticado
			return "ip:" + c.IP()
		},
		LimitReached: func(c *fiber.Ctx) error {
			return c.Status(fiber.StatusTooManyRequests).JSON(fiber.Map{
				"error":       "User rate limit exceeded",
				"retry_after": int(window.Seconds()),
			})
		},
		LimiterMiddleware: limiter.SlidingWindow{},
	})
}
