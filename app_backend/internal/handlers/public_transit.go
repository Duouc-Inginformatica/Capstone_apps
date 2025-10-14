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
	return &Handler{db: db}
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
		return c.Status(fiber.StatusNotFound).JSON(models.ErrorResponse{
			Error: "No se encontraron paradas de bus cercanas",
		})
	}

	// Encontrar la mejor ruta de transporte público
	route, err := h.calculatePublicTransitRoute(req, originStops, destStops)
	if err != nil {
		log.Printf("Error calculating transit route: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{
			Error: "Error calculating route",
		})
	}

	return c.JSON(route)
}

// findNearbyStops encuentra paradas cercanas usando la base de datos GTFS
func (h *Handler) findNearbyStops(lat, lon float64, radiusMeters int) ([]models.GTFSStop, error) {
	query := `
		SELECT stop_id, stop_name, stop_lat, stop_lon, 
		       (6371000 * acos(cos(radians(?)) * cos(radians(stop_lat)) * 
		        cos(radians(stop_lon) - radians(?)) + sin(radians(?)) * 
		        sin(radians(stop_lat)))) AS distance
		FROM gtfs_stops 
		WHERE (6371000 * acos(cos(radians(?)) * cos(radians(stop_lat)) * 
		       cos(radians(stop_lon) - radians(?)) + sin(radians(?)) * 
		       sin(radians(stop_lat)))) <= ?
		ORDER BY distance 
		LIMIT 10
	`

	rows, err := h.db.Query(query, lat, lon, lat, lat, lon, lat, radiusMeters)
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
		SELECT DISTINCT r.route_id, r.route_short_name, r.route_long_name
		FROM gtfs_routes r
		JOIN gtfs_trips t ON r.route_id = t.route_id
		JOIN gtfs_stop_times st1 ON t.trip_id = st1.trip_id
		JOIN gtfs_stop_times st2 ON t.trip_id = st2.trip_id
		WHERE st1.stop_id IN (` + h.buildInClause(len(originStops)) + `)
		  AND st2.stop_id IN (` + h.buildInClause(len(destStops)) + `)
		  AND st1.stop_sequence < st2.stop_sequence
		ORDER BY r.route_short_name
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
