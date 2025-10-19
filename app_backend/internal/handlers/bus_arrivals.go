package handlers

import (
	"database/sql"
	"log"
	"strings"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/redcl"
)

// BusArrivalsHandler maneja solicitudes de llegadas de buses
type BusArrivalsHandler struct {
	scraper *redcl.Scraper
}

// NewBusArrivalsHandler crea una nueva instancia del handler
func NewBusArrivalsHandler(db *sql.DB) *BusArrivalsHandler {
	return &BusArrivalsHandler{
		scraper: redcl.NewScraper(db),
	}
}

// GetBusArrivals maneja GET /api/bus-arrivals/:stopCode
// Obtiene los buses próximos a llegar a un paradero específico
func (h *BusArrivalsHandler) GetBusArrivals(c *fiber.Ctx) error {
	stopCode := c.Params("stopCode")

	if stopCode == "" {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "stop code is required",
		})
	}

	// Limpiar código del paradero
	stopCode = strings.ToUpper(strings.TrimSpace(stopCode))

	log.Printf("🚌 Obteniendo llegadas para paradero: %s", stopCode)

	arrivals, err := h.scraper.GetBusArrivals(stopCode)
	if err != nil {
		log.Printf("❌ Error obteniendo llegadas: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error":   "Failed to get bus arrivals",
			"details": err.Error(),
		})
	}

	// Verificar si se encontraron llegadas
	if len(arrivals.Arrivals) == 0 {
		return c.Status(fiber.StatusNotFound).JSON(fiber.Map{
			"error":     "No arrivals found",
			"stop_code": stopCode,
			"message":   "No hay buses próximos para este paradero o el código es inválido",
		})
	}

	return c.JSON(arrivals)
}

// GetBusArrivalsByLocation maneja POST /api/bus-arrivals/nearby
// Obtiene llegadas para el paradero más cercano a una ubicación
func (h *BusArrivalsHandler) GetBusArrivalsByLocation(c *fiber.Ctx) error {
	type LocationRequest struct {
		Latitude  float64 `json:"latitude"`
		Longitude float64 `json:"longitude"`
		Radius    int     `json:"radius"` // metros, opcional (default: 200)
	}

	var req LocationRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "invalid request format",
		})
	}

	// Validar coordenadas
	if req.Latitude < -90 || req.Latitude > 90 ||
		req.Longitude < -180 || req.Longitude > 180 {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "invalid coordinates",
		})
	}

	// TODO: Implementar búsqueda de paradero más cercano desde GTFS
	// Por ahora, retornar error indicando que falta implementación
	return c.Status(fiber.StatusNotImplemented).JSON(fiber.Map{
		"error":   "Not implemented",
		"message": "Use /api/bus-arrivals/:stopCode with a specific stop code",
	})
}
