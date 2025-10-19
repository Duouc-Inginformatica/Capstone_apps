package handlers

import (
	"database/sql"
	"math"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/models"
)

// Handler contiene las dependencias necesarias para los handlers
type Handler struct {
	db *sql.DB
}

// NewHandler crea una nueva instancia de Handler
func NewHandler(db *sql.DB) *Handler {
	return &Handler{
		db: db,
	}
}

// GTFSNearbyStops proporciona paradas GTFS cercanas como información complementaria
// Esto se usa solo cuando el usuario pide explícitamente ver paradas
func (h *Handler) GTFSNearbyStops(c *fiber.Ctx) error {
	lat := c.QueryFloat("lat", 0)
	lon := c.QueryFloat("lon", 0)
	radiusMeters := c.QueryInt("radius", 500)

	if lat == 0 || lon == 0 {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{
			Error: "Missing lat or lon parameters",
		})
	}

	stops, err := h.findNearbyStops(lat, lon, radiusMeters)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{
			Error: "Error finding nearby stops",
		})
	}

	return c.JSON(stops)
}

// findNearbyStops encuentra paradas cercanas usando la base de datos GTFS
// Optimizado con bounding box para mejor performance
func (h *Handler) findNearbyStops(lat, lon float64, radiusMeters int) ([]models.GTFSStop, error) {
	// Calcular bounding box aproximado (más rápido que calcular distancia exacta)
	// 1 grado de latitud ≈ 111km
	// 1 grado de longitud ≈ 111km * cos(latitude)
	latDelta := float64(radiusMeters) / 111000.0
	lonDelta := float64(radiusMeters) / (111000.0 * math.Cos(lat*math.Pi/180))

	minLat := lat - latDelta
	maxLat := lat + latDelta
	minLon := lon - lonDelta
	maxLon := lon + lonDelta

	// Query optimizada con bounding box primero, luego distancia exacta
	query := `
		SELECT stop_id, name, latitude, longitude, 
		       (6371000 * acos(
		           LEAST(1.0, GREATEST(-1.0,
		               cos(radians(?)) * cos(radians(latitude)) * 
		               cos(radians(longitude) - radians(?)) + 
		               sin(radians(?)) * sin(radians(latitude))
		           ))
		       )) AS distance
		FROM gtfs_stops 
		WHERE latitude BETWEEN ? AND ?
		  AND longitude BETWEEN ? AND ?
		HAVING distance <= ?
		ORDER BY distance 
		LIMIT 20
	`

	rows, err := h.db.Query(query,
		lat, lon, lat, // para el cálculo de distancia
		minLat, maxLat, minLon, maxLon, // bounding box
		radiusMeters, // radio máximo
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var stops []models.GTFSStop
	for rows.Next() {
		var stop models.GTFSStop
		var distance float64
		err := rows.Scan(&stop.StopID, &stop.Name, &stop.Latitude, &stop.Longitude, &distance)
		if err != nil {
			continue
		}
		stop.DistanceMeters = distance // Guardar distancia calculada
		stops = append(stops, stop)
	}

	return stops, nil
}
