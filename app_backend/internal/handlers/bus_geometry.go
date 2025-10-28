// ============================================================================
// Bus Geometry Handler - WayFindCL
// ============================================================================
// Endpoint especializado para obtener geometría EXACTA entre paraderos
// Usa GTFS shapes primero, con fallback a GraphHopper
// ============================================================================

package handlers

import (
	"database/sql"
	"fmt"
	"log"
	"math"

	"github.com/gofiber/fiber/v2"
)

// BusGeometryRequest representa la solicitud de geometría
type BusGeometryRequest struct {
	RouteNumber  string  `json:"route_number"`   // Ej: "506", "D09"
	FromStopCode string  `json:"from_stop_code"` // Ej: "PC1237"
	ToStopCode   string  `json:"to_stop_code"`   // Ej: "PC615"
	FromLat      float64 `json:"from_lat,omitempty"`
	FromLon      float64 `json:"from_lon,omitempty"`
	ToLat        float64 `json:"to_lat,omitempty"`
	ToLon        float64 `json:"to_lon,omitempty"`
}

// BusGeometryResponse representa la respuesta
type BusGeometryResponse struct {
	Geometry        [][]float64 `json:"geometry"`         // [[lon, lat], ...]
	DistanceMeters  float64     `json:"distance_meters"`
	DurationSeconds int         `json:"duration_seconds"`
	Source          string      `json:"source"`           // "gtfs_shape", "graphhopper", "fallback"
	FromStop        StopInfo    `json:"from_stop"`
	ToStop          StopInfo    `json:"to_stop"`
	NumStops        int         `json:"num_stops"`        // Paradas entre origen y destino
}

type StopInfo struct {
	Code string  `json:"code"`
	Name string  `json:"name"`
	Lat  float64 `json:"lat"`
	Lon  float64 `json:"lon"`
}

// ============================================================================
// ENDPOINT: POST /api/bus/geometry/segment
// ============================================================================
// Obtiene geometría exacta entre dos paraderos en una ruta de bus específica
// ============================================================================
func GetBusRouteSegment(c *fiber.Ctx) error {
	var req BusGeometryRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(400).JSON(fiber.Map{
			"error": "Invalid request body",
			"details": err.Error(),
		})
	}

	// Validar campos requeridos
	if req.RouteNumber == "" {
		return c.Status(400).JSON(fiber.Map{
			"error": "route_number is required",
		})
	}

	log.Printf("🔍 [BUS-GEOMETRY] Solicitud: Ruta %s desde %s hasta %s", 
		req.RouteNumber, req.FromStopCode, req.ToStopCode)

	// ESTRATEGIA 1: Intentar obtener geometría desde GTFS shapes
	if req.FromStopCode != "" && req.ToStopCode != "" {
		geometry, source, err := getGeometryFromGTFSShapes(
			req.RouteNumber,
			req.FromStopCode,
			req.ToStopCode,
		)
		
		if err == nil && len(geometry) > 0 {
			log.Printf("✅ [BUS-GEOMETRY] Geometría obtenida desde %s: %d puntos", source, len(geometry))
			
			// Calcular distancia y duración
			distance := calculateGeometryDistance(geometry)
			duration := int(distance / 10.0) // ~10 m/s para buses (36 km/h promedio)
			
			// Obtener info de paradas
			fromStop, _ := getStopInfo(req.FromStopCode)
			toStop, _ := getStopInfo(req.ToStopCode)
			
			// Contar paradas intermedias
			numStops := countStopsBetween(req.RouteNumber, req.FromStopCode, req.ToStopCode)
			
			return c.JSON(BusGeometryResponse{
				Geometry:        geometry,
				DistanceMeters:  distance,
				DurationSeconds: duration,
				Source:          source,
				FromStop:        fromStop,
				ToStop:          toStop,
				NumStops:        numStops,
			})
		}
		
		log.Printf("⚠️ [BUS-GEOMETRY] No se encontró geometría en GTFS: %v", err)
	}

	// ESTRATEGIA 2: Usar coordenadas directamente con GraphHopper
	if req.FromLat != 0 && req.FromLon != 0 && req.ToLat != 0 && req.ToLon != 0 {
		log.Printf("🔄 [BUS-GEOMETRY] Usando GraphHopper con coordenadas directas")
		
		client := getGHClient()
		if client == nil {
			return c.Status(503).JSON(fiber.Map{
				"error": "GraphHopper no disponible",
			})
		}

		route, err := client.GetFootRoute(req.FromLat, req.FromLon, req.ToLat, req.ToLon)
		if err != nil {
			return c.Status(500).JSON(fiber.Map{
				"error": "Error calculando ruta",
				"details": err.Error(),
			})
		}

		if len(route.Paths) == 0 {
			return c.Status(404).JSON(fiber.Map{
				"error": "No route found",
			})
		}

		path := route.Paths[0]
		
		return c.JSON(BusGeometryResponse{
			Geometry:        path.Points.Coordinates,
			DistanceMeters:  path.Distance,
			DurationSeconds: int(path.Time / 1000),
			Source:          "graphhopper",
			FromStop:        StopInfo{Lat: req.FromLat, Lon: req.FromLon},
			ToStop:          StopInfo{Lat: req.ToLat, Lon: req.ToLon},
		})
	}

	// ESTRATEGIA 3: Fallback - línea recta
	log.Printf("⚠️ [BUS-GEOMETRY] Usando fallback (línea recta)")
	
	fromStop, _ := getStopInfo(req.FromStopCode)
	toStop, _ := getStopInfo(req.ToStopCode)
	
	geometry := [][]float64{
		{fromStop.Lon, fromStop.Lat},
		{toStop.Lon, toStop.Lat},
	}
	
	distance := haversineDistance(fromStop.Lat, fromStop.Lon, toStop.Lat, toStop.Lon)
	
	return c.JSON(BusGeometryResponse{
		Geometry:        geometry,
		DistanceMeters:  distance,
		DurationSeconds: int(distance / 10.0),
		Source:          "fallback_straight_line",
		FromStop:        fromStop,
		ToStop:          toStop,
	})
}

// ============================================================================
// FUNCIONES AUXILIARES
// ============================================================================

// getGeometryFromGTFSShapes obtiene geometría desde shapes GTFS
func getGeometryFromGTFSShapes(routeNumber, fromStopCode, toStopCode string) ([][]float64, string, error) {
	setupMu.RLock()
	database := dbConn
	setupMu.RUnlock()
	
	if database == nil {
		return nil, "", fmt.Errorf("base de datos no inicializada")
	}
	
	// 1. Buscar shape_id de la ruta
	var shapeID string
	query := `
		SELECT DISTINCT s.shape_id
		FROM gtfs_trips t
		JOIN gtfs_routes r ON t.route_id = r.route_id
		JOIN gtfs_shapes s ON t.shape_id = s.shape_id
		WHERE r.route_short_name = $1
		LIMIT 1
	`
	
	err := database.QueryRow(query, routeNumber).Scan(&shapeID)
	if err != nil {
		return nil, "", fmt.Errorf("no se encontró shape para ruta %s: %w", routeNumber, err)
	}
	
	log.Printf("📍 [GTFS] Shape encontrado: %s para ruta %s", shapeID, routeNumber)
	
	// 2. Obtener coordenadas de paradas
	fromStop, err := getStopInfo(fromStopCode)
	if err != nil {
		return nil, "", fmt.Errorf("parada origen no encontrada: %w", err)
	}
	
	toStop, err := getStopInfo(toStopCode)
	if err != nil {
		return nil, "", fmt.Errorf("parada destino no encontrada: %w", err)
	}
	
	// 3. Obtener todos los puntos del shape ordenados
	shapeQuery := `
		SELECT shape_pt_lat, shape_pt_lon, shape_pt_sequence
		FROM gtfs_shapes
		WHERE shape_id = $1
		ORDER BY shape_pt_sequence
	`
	
	rows, err := database.Query(shapeQuery, shapeID)
	if err != nil {
		return nil, "", fmt.Errorf("error obteniendo shape points: %w", err)
	}
	defer rows.Close()
	
	var allPoints [][]float64
	for rows.Next() {
		var lat, lon float64
		var seq int
		if err := rows.Scan(&lat, &lon, &seq); err != nil {
			continue
		}
		allPoints = append(allPoints, []float64{lon, lat})
	}
	
	if len(allPoints) == 0 {
		return nil, "", fmt.Errorf("no se encontraron puntos en el shape")
	}
	
	log.Printf("📍 [GTFS] Shape completo: %d puntos", len(allPoints))
	
	// 4. Encontrar índices más cercanos a las paradas en el shape
	startIdx := findClosestPointIndex(allPoints, fromStop.Lat, fromStop.Lon)
	endIdx := findClosestPointIndex(allPoints, toStop.Lat, toStop.Lon)
	
	// Validar que el segmento tiene sentido
	if startIdx >= endIdx {
		log.Printf("⚠️ [GTFS] Índices invertidos: start=%d, end=%d. Usando geometría completa", startIdx, endIdx)
		return allPoints, "gtfs_shape_full", nil
	}
	
	// 5. Extraer segmento
	segment := allPoints[startIdx : endIdx+1]
	
	log.Printf("✅ [GTFS] Segmento extraído: %d puntos (índices %d a %d)", len(segment), startIdx, endIdx)
	
	return segment, "gtfs_shape", nil
}

// getStopInfo obtiene información de una parada por código
func getStopInfo(stopCode string) (StopInfo, error) {
	setupMu.RLock()
	database := dbConn
	setupMu.RUnlock()
	
	if database == nil {
		return StopInfo{}, fmt.Errorf("base de datos no inicializada")
	}
	
	var info StopInfo
	query := `
		SELECT stop_code, stop_name, stop_lat, stop_lon
		FROM gtfs_stops
		WHERE stop_code = $1
		LIMIT 1
	`
	
	err := database.QueryRow(query, stopCode).Scan(&info.Code, &info.Name, &info.Lat, &info.Lon)
	if err != nil {
		return info, err
	}
	
	return info, nil
}

// findClosestPointIndex encuentra el índice del punto más cercano
func findClosestPointIndex(points [][]float64, lat, lon float64) int {
	minDist := math.MaxFloat64
	closestIdx := 0
	
	for i, point := range points {
		pointLon := point[0]
		pointLat := point[1]
		
		dist := haversineDistance(lat, lon, pointLat, pointLon)
		if dist < minDist {
			minDist = dist
			closestIdx = i
		}
	}
	
	return closestIdx
}

// calculateGeometryDistance calcula distancia total de una geometría
func calculateGeometryDistance(geometry [][]float64) float64 {
	if len(geometry) < 2 {
		return 0
	}
	
	totalDistance := 0.0
	for i := 0; i < len(geometry)-1; i++ {
		lat1 := geometry[i][1]
		lon1 := geometry[i][0]
		lat2 := geometry[i+1][1]
		lon2 := geometry[i+1][0]
		
		totalDistance += haversineDistance(lat1, lon1, lat2, lon2)
	}
	
	return totalDistance
}

// haversineDistance calcula distancia entre dos puntos en metros
func haversineDistance(lat1, lon1, lat2, lon2 float64) float64 {
	const R = 6371000 // Radio de la Tierra en metros
	
	dLat := toRadians(lat2 - lat1)
	dLon := toRadians(lon2 - lon1)
	
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(toRadians(lat1))*math.Cos(toRadians(lat2))*
		math.Sin(dLon/2)*math.Sin(dLon/2)
	
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
	
	return R * c
}

func toRadians(degrees float64) float64 {
	return degrees * math.Pi / 180
}

// countStopsBetween cuenta paradas entre dos códigos en una ruta
func countStopsBetween(routeNumber, fromStopCode, toStopCode string) int {
	setupMu.RLock()
	database := dbConn
	setupMu.RUnlock()
	
	if database == nil {
		return 0
	}
	
	query := `
		WITH route_stops AS (
			SELECT st.stop_id, st.stop_sequence, s.stop_code
			FROM gtfs_stop_times st
			JOIN gtfs_trips t ON st.trip_id = t.trip_id
			JOIN gtfs_routes r ON t.route_id = r.route_id
			JOIN gtfs_stops s ON st.stop_id = s.stop_id
			WHERE r.route_short_name = $1
			ORDER BY st.stop_sequence
		)
		SELECT COUNT(DISTINCT stop_id)
		FROM route_stops
		WHERE stop_sequence >= (SELECT stop_sequence FROM route_stops WHERE stop_code = $2 LIMIT 1)
		  AND stop_sequence <= (SELECT stop_sequence FROM route_stops WHERE stop_code = $3 LIMIT 1)
	`
	
	var count int
	err := database.QueryRow(query, routeNumber, fromStopCode, toStopCode).Scan(&count)
	if err != nil && err != sql.ErrNoRows {
		log.Printf("⚠️ Error contando paradas: %v", err)
		return 0
	}
	
	return count
}
