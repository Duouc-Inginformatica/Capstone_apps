package handlers

import (
	"database/sql"
	"fmt"
	"log"
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

// PublicTransitRoute maneja rutas de transporte público usando datos GTFS
func (h *Handler) PublicTransitRoute(c *fiber.Ctx) error {
	var req models.TransitRouteRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{
			Error: "Invalid request format",
		})
	}

	// Validar coordenadas
	if req.Origin.Lat < -90 || req.Origin.Lat > 90 || req.Origin.Lon < -180 || req.Origin.Lon > 180 {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{
			Error: "Invalid origin coordinates",
		})
	}
	if req.Destination.Lat < -90 || req.Destination.Lat > 90 || req.Destination.Lon < -180 || req.Destination.Lon > 180 {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{
			Error: "Invalid destination coordinates",
		})
	}

	// Buscar paradas de bus cercanas al origen y destino
	originStops, err := h.findNearbyStops(req.Origin.Lat, req.Origin.Lon, 500) // 500m radius
	if err != nil {
		log.Printf("Error finding origin stops: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{
			Error: "Error finding nearby stops",
		})
	}

	destStops, err := h.findNearbyStops(req.Destination.Lat, req.Destination.Lon, 500)
	if err != nil {
		log.Printf("Error finding destination stops: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{
			Error: "Error finding nearby stops",
		})
	}

	if len(originStops) == 0 || len(destStops) == 0 {
		// Si no hay paradas GTFS cercanas, intentar con Moovit como fallback
		log.Printf("⚠️ No se encontraron paradas GTFS cercanas, intentando con Moovit...")
		return h.calculateRouteWithMoovitFallback(c, req)
	}

	// Encontrar la mejor ruta de transporte público
	route, err := h.calculatePublicTransitRoute(req, originStops, destStops)
	if err != nil {
		log.Printf("⚠️ Error calculando ruta GTFS: %v, intentando con Moovit...", err)
		// Si falla GTFS, intentar con Moovit como fallback
		return h.calculateRouteWithMoovitFallback(c, req)
	}

	return c.JSON(route)
}

// calculateRouteWithMoovitFallback usa datos de Moovit cuando GTFS no tiene rutas
func (h *Handler) calculateRouteWithMoovitFallback(c *fiber.Ctx, req models.TransitRouteRequest) error {
	log.Printf("🚌 Usando Moovit como fuente de datos alternativa")

	// Retornar respuesta indicando que use el endpoint de Red directamente
	return c.JSON(fiber.Map{
		"message":  "Use /api/red/itinerary endpoint for routes",
		"fallback": "moovit",
		"suggestion": fiber.Map{
			"endpoint": "/api/red/itinerary",
			"method":   "POST",
			"body": fiber.Map{
				"origin_lat": req.Origin.Lat,
				"origin_lon": req.Origin.Lon,
				"dest_lat":   req.Destination.Lat,
				"dest_lon":   req.Destination.Lon,
			},
		},
	})
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

// calculatePublicTransitRoute calcula la mejor ruta usando GTFS + GraphHopper
func (h *Handler) calculatePublicTransitRoute(req models.TransitRouteRequest, originStops, destStops []models.GTFSStop) (*models.TransitRouteResponse, error) {
	// Buscar rutas directas entre las paradas
	bestRoute, err := h.findDirectBusRoute(originStops, destStops)
	if err != nil {
		return nil, err
	}

	if bestRoute != nil {
		// Agregar segmentos de caminata al inicio y final
		return h.buildCompleteRoute(req, bestRoute)
	}

	// Si no hay ruta directa, buscar rutas con transferencias
	return h.findRouteWithTransfers(req, originStops, destStops)
}

// findDirectBusRoute busca rutas directas entre paradas
func (h *Handler) findDirectBusRoute(originStops, destStops []models.GTFSStop) (*models.BusRoute, error) {
	query := `
		SELECT DISTINCT r.route_id, r.short_name, r.long_name
		FROM gtfs_routes r
		JOIN gtfs_trips t ON r.route_id = t.route_id
		JOIN gtfs_stop_times st1 ON t.trip_id = st1.trip_id
		JOIN gtfs_stop_times st2 ON t.trip_id = st2.trip_id
		WHERE st1.stop_id IN (` + h.buildInClause(len(originStops)) + `)
		  AND st2.stop_id IN (` + h.buildInClause(len(destStops)) + `)
		  AND st1.stop_sequence < st2.stop_sequence
		ORDER BY r.short_name
		LIMIT 1
	`

	args := make([]interface{}, 0, len(originStops)+len(destStops))
	for _, stop := range originStops {
		args = append(args, stop.StopID)
	}
	for _, stop := range destStops {
		args = append(args, stop.StopID)
	}

	var route models.BusRoute
	err := h.db.QueryRow(query, args...).Scan(&route.RouteID, &route.RouteShortName, &route.RouteLongName)
	if err != nil {
		// Si no hay resultados, retornar nil sin error (permite fallback a Moovit)
		if err == sql.ErrNoRows {
			log.Printf("ℹ️ No se encontró ruta directa en GTFS")
			return nil, nil
		}
		return nil, err
	}

	return &route, nil
}

// buildInClause construye la parte IN de la consulta SQL
func (h *Handler) buildInClause(count int) string {
	if count == 0 {
		return ""
	}
	result := "?"
	for i := 1; i < count; i++ {
		result += ",?"
	}
	return result
}

// buildCompleteRoute construye la ruta completa con segmentos de caminata
func (h *Handler) buildCompleteRoute(req models.TransitRouteRequest, busRoute *models.BusRoute) (*models.TransitRouteResponse, error) {
	response := &models.TransitRouteResponse{
		Paths: []models.TransitPath{
			{
				Time:     30 * 60 * 1000, // 30 minutos estimado
				Distance: 5000,           // 5km estimado
				Legs: []models.TransitLeg{
					{
						Type:        "walk",
						Distance:    200,
						Time:        3 * 60 * 1000, // 3 minutos
						Instruction: "Camina hasta la parada de bus",
					},
					{
						Type:        "pt",
						Distance:    4500,
						Time:        20 * 60 * 1000, // 20 minutos
						Instruction: fmt.Sprintf("Toma el bus %s", busRoute.RouteShortName),
						RouteDesc:   busRoute.RouteLongName,
					},
					{
						Type:        "walk",
						Distance:    300,
						Time:        4 * 60 * 1000, // 4 minutos
						Instruction: "Camina desde la parada hasta el destino",
					},
				},
			},
		},
	}

	return response, nil
}

// findRouteWithTransfers busca rutas con transferencias
func (h *Handler) findRouteWithTransfers(req models.TransitRouteRequest, originStops, destStops []models.GTFSStop) (*models.TransitRouteResponse, error) {
	// Implementación simplificada - retorna una ruta de caminata
	walkTime := int(math.Max(float64(h.calculateWalkTime(req.Origin.Lat, req.Origin.Lon, req.Destination.Lat, req.Destination.Lon)), 300))
	walkDistance := int(h.calculateDistance(req.Origin.Lat, req.Origin.Lon, req.Destination.Lat, req.Destination.Lon))

	response := &models.TransitRouteResponse{
		Paths: []models.TransitPath{
			{
				Time:     walkTime,
				Distance: walkDistance,
				Legs: []models.TransitLeg{
					{
						Type:        "walk",
						Distance:    walkDistance,
						Time:        walkTime,
						Instruction: "Camina hasta el destino (no se encontró ruta de bus disponible)",
					},
				},
			},
		},
	}

	return response, nil
}

// calculateWalkTime calcula el tiempo de caminata en milisegundos
func (h *Handler) calculateWalkTime(lat1, lon1, lat2, lon2 float64) int {
	distance := h.calculateDistance(lat1, lon1, lat2, lon2)
	// Velocidad promedio de caminata: 1.4 m/s
	timeSeconds := distance / 1.4
	return int(timeSeconds * 1000) // convertir a milisegundos
}

// calculateDistance calcula la distancia en metros usando la fórmula de Haversine
func (h *Handler) calculateDistance(lat1, lon1, lat2, lon2 float64) float64 {
	const R = 6371000 // Radio de la Tierra en metros

	lat1Rad := lat1 * math.Pi / 180
	lat2Rad := lat2 * math.Pi / 180
	deltaLat := (lat2 - lat1) * math.Pi / 180
	deltaLon := (lon2 - lon1) * math.Pi / 180

	a := math.Sin(deltaLat/2)*math.Sin(deltaLat/2) +
		math.Cos(lat1Rad)*math.Cos(lat2Rad)*
			math.Sin(deltaLon/2)*math.Sin(deltaLon/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))

	return R * c
}
