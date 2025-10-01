package handlers

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/models"
)

type TripHistoryHandler struct {
	db *sql.DB
}

func NewTripHistoryHandler(db *sql.DB) *TripHistoryHandler {
	return &TripHistoryHandler{db: db}
}

// SaveTrip guarda un viaje completado
func (h *TripHistoryHandler) SaveTrip(c *fiber.Ctx) error {
	var req models.TripHistoryCreateRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	// Obtener ID del usuario
	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	query := `
		INSERT INTO trip_history (
			user_id, origin_lat, origin_lon,
			destination_lat, destination_lon, destination_name,
			distance_meters, duration_seconds, bus_route,
			route_geometry, started_at, completed_at, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
	`

	result, err := h.db.Exec(
		query,
		userID,
		req.OriginLat,
		req.OriginLon,
		req.DestinationLat,
		req.DestinationLon,
		req.DestinationName,
		req.DistanceMeters,
		req.DurationSeconds,
		req.BusRoute,
		req.RouteGeometry,
		req.StartedAt,
		req.CompletedAt,
	)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to save trip",
		})
	}

	tripID, _ := result.LastInsertId()

	return c.Status(fiber.StatusCreated).JSON(fiber.Map{
		"message": "Trip saved successfully",
		"trip_id": tripID,
	})
}

// GetUserTrips obtiene el historial de viajes del usuario
func (h *TripHistoryHandler) GetUserTrips(c *fiber.Ctx) error {
	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	limit := c.QueryInt("limit", 50)
	offset := c.QueryInt("offset", 0)

	query := `
		SELECT 
			id, user_id, origin_lat, origin_lon,
			destination_lat, destination_lon, destination_name,
			distance_meters, duration_seconds, bus_route,
			route_geometry, started_at, completed_at, created_at
		FROM trip_history
		WHERE user_id = ?
		ORDER BY completed_at DESC
		LIMIT ? OFFSET ?
	`

	rows, err := h.db.Query(query, userID, limit, offset)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch trips",
		})
	}
	defer rows.Close()

	trips := []models.TripHistory{}
	for rows.Next() {
		var trip models.TripHistory
		err := rows.Scan(
			&trip.ID,
			&trip.UserID,
			&trip.OriginLat,
			&trip.OriginLon,
			&trip.DestinationLat,
			&trip.DestinationLon,
			&trip.DestinationName,
			&trip.DistanceMeters,
			&trip.DurationSeconds,
			&trip.BusRoute,
			&trip.RouteGeometry,
			&trip.StartedAt,
			&trip.CompletedAt,
			&trip.CreatedAt,
		)
		if err != nil {
			continue
		}
		trips = append(trips, trip)
	}

	return c.JSON(fiber.Map{
		"trips": trips,
		"count": len(trips),
	})
}

// GetFrequentLocations obtiene los lugares más visitados
func (h *TripHistoryHandler) GetFrequentLocations(c *fiber.Ctx) error {
	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	limit := c.QueryInt("limit", 10)

	// Obtener destinos frecuentes
	query := `
		SELECT 
			destination_name,
			AVG(destination_lat) as lat,
			AVG(destination_lon) as lon,
			COUNT(*) as visit_count,
			MIN(completed_at) as first_visit,
			MAX(completed_at) as last_visit
		FROM trip_history
		WHERE user_id = ?
		GROUP BY destination_name
		ORDER BY visit_count DESC
		LIMIT ?
	`

	rows, err := h.db.Query(query, userID, limit)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch frequent locations",
		})
	}
	defer rows.Close()

	locations := []models.FrequentLocation{}
	for rows.Next() {
		var loc models.FrequentLocation
		err := rows.Scan(
			&loc.Name,
			&loc.Latitude,
			&loc.Longitude,
			&loc.VisitCount,
			&loc.FirstVisit,
			&loc.LastVisit,
		)
		if err != nil {
			continue
		}
		locations = append(locations, loc)
	}

	return c.JSON(fiber.Map{
		"frequent_locations": locations,
		"count":              len(locations),
	})
}

// GetTripStatistics obtiene estadísticas de viajes
func (h *TripHistoryHandler) GetTripStatistics(c *fiber.Ctx) error {
	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	var stats models.TripStatistics

	// Total de viajes y totales
	query := `
		SELECT 
			COUNT(*) as total_trips,
			COALESCE(SUM(distance_meters), 0) as total_distance,
			COALESCE(SUM(duration_seconds), 0) as total_duration,
			COALESCE(AVG(distance_meters), 0) as avg_distance,
			COALESCE(AVG(duration_seconds), 0) as avg_duration
		FROM trip_history
		WHERE user_id = ?
	`

	err := h.db.QueryRow(query, userID).Scan(
		&stats.TotalTrips,
		&stats.TotalDistanceMeters,
		&stats.TotalDurationSeconds,
		&stats.AverageDistanceMeters,
		&stats.AverageDurationSeconds,
	)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch statistics",
		})
	}

	// Lugar más visitado (como FrequentLocation completo)
	var mostVisitedName string
	var mostVisitedLat, mostVisitedLon float64
	var mostVisitedCount int
	var mostVisitedFirst, mostVisitedLast time.Time
	
	err = h.db.QueryRow(`
		SELECT destination_name, AVG(destination_lat), AVG(destination_lon), 
		       COUNT(*), MIN(started_at), MAX(started_at)
		FROM trip_history 
		WHERE user_id = ?
		GROUP BY destination_name 
		ORDER BY COUNT(*) DESC 
		LIMIT 1
	`, userID).Scan(&mostVisitedName, &mostVisitedLat, &mostVisitedLon,
		&mostVisitedCount, &mostVisitedFirst, &mostVisitedLast)
	if err == nil {
		stats.MostVisitedLocation = &models.FrequentLocation{
			Name:       mostVisitedName,
			Latitude:   mostVisitedLat,
			Longitude:  mostVisitedLon,
			VisitCount: mostVisitedCount,
			FirstVisit: mostVisitedFirst,
			LastVisit:  mostVisitedLast,
		}
	}

	// Hora favorita (0-23) como string
	var favoriteHour int
	err = h.db.QueryRow(`
		SELECT HOUR(started_at) as hour
		FROM trip_history 
		WHERE user_id = ?
		GROUP BY hour
		ORDER BY COUNT(*) DESC 
		LIMIT 1
	`, userID).Scan(&favoriteHour)
	if err == nil {
		stats.FavoriteTimeOfDay = fmt.Sprintf("%02d:00", favoriteHour)
	}

	return c.JSON(stats)
}

// GetTripSuggestions obtiene sugerencias basadas en patrones
func (h *TripHistoryHandler) GetTripSuggestions(c *fiber.Ctx) error {
	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	currentHour := time.Now().Hour()
	dayOfWeek := int(time.Now().Weekday())

	// Buscar viajes similares en horario similar
	query := `
		SELECT 
			destination_name,
			destination_lat,
			destination_lon,
			COUNT(*) as frequency
		FROM trip_history
		WHERE user_id = ?
		AND HOUR(started_at) BETWEEN ? AND ?
		AND DAYOFWEEK(started_at) = ?
		GROUP BY destination_name, destination_lat, destination_lon
		ORDER BY frequency DESC
		LIMIT 5
	`

	rows, err := h.db.Query(
		query,
		userID,
		currentHour-1,
		currentHour+1,
		dayOfWeek+1, // MySQL usa 1-7, Go usa 0-6
	)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch suggestions",
		})
	}
	defer rows.Close()

	suggestions := []models.TripSuggestion{}
	for rows.Next() {
		var destName string
		var lat, lon float64
		var frequency int

		err := rows.Scan(&destName, &lat, &lon, &frequency)
		if err != nil {
			continue
		}

		// Calcular confianza basada en frecuencia
		confidence := float64(frequency) / 10.0
		if confidence > 1.0 {
			confidence = 1.0
		}

		suggestion := models.TripSuggestion{
			DestinationName: destName,
			Latitude:        lat,
			Longitude:       lon,
			Confidence:      confidence,
			Reason:          "Viajes frecuentes en este horario",
		}

		suggestions = append(suggestions, suggestion)
	}

	return c.JSON(fiber.Map{
		"suggestions": suggestions,
		"count":       len(suggestions),
	})
}
