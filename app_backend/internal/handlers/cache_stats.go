package handlers

import (
	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/cache"
)

// ============================================================================
// CACHE STATISTICS ENDPOINT
// ============================================================================
// Endpoint para monitorear el estado del caché en producción
// GET /api/cache/stats

// GetCacheStats retorna estadísticas de todos los cachés activos
func GetCacheStats(c *fiber.Ctx) error {
	stats := cache.GetAllCacheStats()
	
	// Calcular totales
	var totalItems, totalValid, totalExpired int
	var totalMemoryMB float64
	
	for _, s := range stats {
		totalItems += s.TotalItems
		totalValid += s.ValidItems
		totalExpired += s.ExpiredItems
		totalMemoryMB += s.MemoryEstMB
	}
	
	return c.JSON(fiber.Map{
		"status": "ok",
		"summary": fiber.Map{
			"total_items":     totalItems,
			"valid_items":     totalValid,
			"expired_items":   totalExpired,
			"memory_est_mb":   totalMemoryMB,
		},
		"caches": stats,
	})
}

// ClearCache limpia un caché específico o todos
// DELETE /api/cache?type=stops
// DELETE /api/cache?type=all
func ClearCache(c *fiber.Ctx) error {
	cacheType := c.Query("type", "all")
	
	var cleared int
	
	switch cacheType {
	case "stops":
		if cache.StopsCache != nil {
			cache.StopsCache.Clear()
			cleared = 1
		}
	case "routes":
		if cache.RoutesCache != nil {
			cache.RoutesCache.Clear()
			cleared = 1
		}
	case "trips":
		if cache.TripsCache != nil {
			cache.TripsCache.Clear()
			cleared = 1
		}
	case "geometry":
		if cache.GeometryCache != nil {
			cache.GeometryCache.Clear()
			cleared = 1
		}
	case "arrivals":
		if cache.ArrivalsCache != nil {
			cache.ArrivalsCache.Clear()
			cleared = 1
		}
	case "all":
		cache.ClearAllCaches()
		cleared = 5
	default:
		return c.Status(400).JSON(fiber.Map{
			"error": "Invalid cache type. Use: stops, routes, trips, geometry, arrivals, or all",
		})
	}
	
	return c.JSON(fiber.Map{
		"status":  "ok",
		"message": "Cache cleared",
		"type":    cacheType,
		"cleared": cleared,
	})
}
