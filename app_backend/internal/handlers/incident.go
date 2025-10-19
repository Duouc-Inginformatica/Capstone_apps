package handlers

import (
	"database/sql"
	"math"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/models"
)

type IncidentHandler struct {
	db *sql.DB
}

func NewIncidentHandler(db *sql.DB) *IncidentHandler {
	return &IncidentHandler{db: db}
}

// CreateIncident crea un nuevo incidente
func (h *IncidentHandler) CreateIncident(c *fiber.Ctx) error {
	var req models.IncidentCreateRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	// Obtener ID del usuario desde el contexto (agregado por middleware de auth)
	userID := c.Locals("userID")
	if userID == nil {
		userID = "anonymous"
	}

	// Insertar incidente
	query := `
		INSERT INTO incidents (
			type, latitude, longitude, severity, reporter_id,
			route_name, stop_name, description, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
	`

	result, err := h.db.Exec(
		query,
		req.Type,
		req.Latitude,
		req.Longitude,
		req.Severity,
		userID,
		req.RouteName,
		req.StopName,
		req.Description,
	)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to create incident",
		})
	}

	incidentID, _ := result.LastInsertId()

	return c.Status(fiber.StatusCreated).JSON(fiber.Map{
		"message":     "Incident reported successfully",
		"incident_id": incidentID,
	})
}

// GetNearbyIncidents obtiene incidentes cercanos a una ubicación
func (h *IncidentHandler) GetNearbyIncidents(c *fiber.Ctx) error {
	lat := c.QueryFloat("lat", 0)
	lon := c.QueryFloat("lon", 0)
	radiusKm := c.QueryFloat("radius_km", 2.0)
	onlyRecent := c.QueryBool("only_recent", true)

	if lat == 0 || lon == 0 {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Latitude and longitude are required",
		})
	}

	// Calcular bounding box para optimizar búsqueda
	latDelta := radiusKm / 111.0 // Aproximadamente 111km por grado de latitud
	lonDelta := radiusKm / (111.0 * math.Cos(lat*math.Pi/180.0))

	query := `
		SELECT 
			id, type, latitude, longitude, severity, reporter_id,
			route_name, stop_name, description, is_verified,
			upvotes, downvotes, created_at, updated_at
		FROM incidents
		WHERE 
			latitude BETWEEN ? AND ?
			AND longitude BETWEEN ? AND ?
	`

	args := []interface{}{
		lat - latDelta,
		lat + latDelta,
		lon - lonDelta,
		lon + lonDelta,
	}

	if onlyRecent {
		query += " AND created_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)"
	}

	query += " ORDER BY created_at DESC LIMIT 100"

	rows, err := h.db.Query(query, args...)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch incidents",
		})
	}
	defer rows.Close()

	incidents := []models.Incident{}
	for rows.Next() {
		var incident models.Incident
		err := rows.Scan(
			&incident.ID,
			&incident.Type,
			&incident.Latitude,
			&incident.Longitude,
			&incident.Severity,
			&incident.ReporterID,
			&incident.RouteName,
			&incident.StopName,
			&incident.Description,
			&incident.IsVerified,
			&incident.Upvotes,
			&incident.Downvotes,
			&incident.CreatedAt,
			&incident.UpdatedAt,
		)
		if err != nil {
			continue
		}

		// Calcular distancia exacta
		distance := calculateDistance(lat, lon, incident.Latitude, incident.Longitude)
		if distance <= radiusKm {
			incidents = append(incidents, incident)
		}
	}

	return c.JSON(fiber.Map{
		"incidents": incidents,
		"count":     len(incidents),
	})
}

// GetIncidentByID obtiene un incidente específico
func (h *IncidentHandler) GetIncidentByID(c *fiber.Ctx) error {
	id := c.Params("id")

	query := `
		SELECT 
			id, type, latitude, longitude, severity, reporter_id,
			route_name, stop_name, description, is_verified,
			upvotes, downvotes, created_at, updated_at
		FROM incidents
		WHERE id = ?
	`

	var incident models.Incident
	err := h.db.QueryRow(query, id).Scan(
		&incident.ID,
		&incident.Type,
		&incident.Latitude,
		&incident.Longitude,
		&incident.Severity,
		&incident.ReporterID,
		&incident.RouteName,
		&incident.StopName,
		&incident.Description,
		&incident.IsVerified,
		&incident.Upvotes,
		&incident.Downvotes,
		&incident.CreatedAt,
		&incident.UpdatedAt,
	)

	if err == sql.ErrNoRows {
		return c.Status(fiber.StatusNotFound).JSON(fiber.Map{
			"error": "Incident not found",
		})
	}

	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch incident",
		})
	}

	return c.JSON(incident)
}

// VoteIncident vota por un incidente (upvote/downvote)
func (h *IncidentHandler) VoteIncident(c *fiber.Ctx) error {
	id := c.Params("id")

	var req models.IncidentVoteRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	var query string
	if req.VoteType == "upvote" {
		query = "UPDATE incidents SET upvotes = upvotes + 1, updated_at = NOW() WHERE id = ?"
	} else {
		query = "UPDATE incidents SET downvotes = downvotes + 1, updated_at = NOW() WHERE id = ?"
	}

	result, err := h.db.Exec(query, id)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to vote",
		})
	}

	rowsAffected, _ := result.RowsAffected()
	if rowsAffected == 0 {
		return c.Status(fiber.StatusNotFound).JSON(fiber.Map{
			"error": "Incident not found",
		})
	}

	return c.JSON(fiber.Map{
		"message": "Vote registered successfully",
	})
}

// GetIncidentsByRoute obtiene incidentes de una ruta específica
func (h *IncidentHandler) GetIncidentsByRoute(c *fiber.Ctx) error {
	routeName := c.Query("route_name")
	if routeName == "" {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "route_name is required",
		})
	}

	query := `
		SELECT 
			id, type, latitude, longitude, severity, reporter_id,
			route_name, stop_name, description, is_verified,
			upvotes, downvotes, created_at, updated_at
		FROM incidents
		WHERE route_name = ?
		AND created_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)
		ORDER BY created_at DESC
		LIMIT 50
	`

	rows, err := h.db.Query(query, routeName)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch incidents",
		})
	}
	defer rows.Close()

	incidents := []models.Incident{}
	for rows.Next() {
		var incident models.Incident
		err := rows.Scan(
			&incident.ID,
			&incident.Type,
			&incident.Latitude,
			&incident.Longitude,
			&incident.Severity,
			&incident.ReporterID,
			&incident.RouteName,
			&incident.StopName,
			&incident.Description,
			&incident.IsVerified,
			&incident.Upvotes,
			&incident.Downvotes,
			&incident.CreatedAt,
			&incident.UpdatedAt,
		)
		if err != nil {
			continue
		}
		incidents = append(incidents, incident)
	}

	return c.JSON(fiber.Map{
		"incidents": incidents,
		"count":     len(incidents),
	})
}

// GetIncidentStats obtiene estadísticas de incidentes
func (h *IncidentHandler) GetIncidentStats(c *fiber.Ctx) error {
	stats := models.IncidentStats{
		ByType:     make(map[models.IncidentType]int),
		BySeverity: make(map[models.IncidentSeverity]int),
	}

	// Total de incidentes
	err := h.db.QueryRow("SELECT COUNT(*) FROM incidents").Scan(&stats.TotalIncidents)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch stats",
		})
	}

	// Por tipo
	rows, _ := h.db.Query("SELECT type, COUNT(*) FROM incidents GROUP BY type")
	defer rows.Close()
	for rows.Next() {
		var incType models.IncidentType
		var count int
		rows.Scan(&incType, &count)
		stats.ByType[incType] = count
	}

	// Por severidad
	rows, _ = h.db.Query("SELECT severity, COUNT(*) FROM incidents GROUP BY severity")
	for rows.Next() {
		var severity models.IncidentSeverity
		var count int
		rows.Scan(&severity, &count)
		stats.BySeverity[severity] = count
	}
	rows.Close()

	// Verificados
	h.db.QueryRow("SELECT COUNT(*) FROM incidents WHERE is_verified = true").Scan(&stats.VerifiedCount)

	// Últimas 24 horas
	h.db.QueryRow("SELECT COUNT(*) FROM incidents WHERE created_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)").Scan(&stats.Last24Hours)

	// Ruta más reportada
	var mostReported string
	err = h.db.QueryRow(`
		SELECT route_name FROM incidents 
		WHERE route_name IS NOT NULL 
		GROUP BY route_name 
		ORDER BY COUNT(*) DESC 
		LIMIT 1
	`).Scan(&mostReported)
	if err == nil {
		stats.MostReportedRoute = &mostReported
	}

	return c.JSON(stats)
}

// calculateDistance calcula la distancia en km entre dos coordenadas usando fórmula de Haversine
func calculateDistance(lat1, lon1, lat2, lon2 float64) float64 {
	const earthRadius = 6371.0 // km

	dLat := (lat2 - lat1) * math.Pi / 180.0
	dLon := (lon2 - lon1) * math.Pi / 180.0

	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1*math.Pi/180.0)*math.Cos(lat2*math.Pi/180.0)*
			math.Sin(dLon/2)*math.Sin(dLon/2)

	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))

	return earthRadius * c
}
