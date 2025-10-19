// ============================================================================
// GraphHopper Route Handlers - WayFindCL
// ============================================================================
// Endpoints para routing usando GraphHopper
// Arquitectura híbrida:
//   - GraphHopper: Routing general (foot, car, public transit con GTFS)
//   - Moovit Scraper: Info específica de rutas Red (se mantiene intacto)
// ============================================================================

package handlers

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/graphhopper"
)

var ghClient *graphhopper.Client

// InitGraphHopper inicializa GraphHopper como subproceso del backend
func InitGraphHopper() error {
	// Iniciar GraphHopper como subproceso
	if err := graphhopper.StartGraphHopperProcess(); err != nil {
		return fmt.Errorf("no se pudo iniciar GraphHopper: %w", err)
	}
	
	// Crear cliente
	ghClient = graphhopper.NewClient()
	return nil
}

// ============================================================================
// ENDPOINT: GET /api/route/walking
// ============================================================================
// Ruta peatonal simple (reemplaza OSRM foot)
// ============================================================================
func GetFootRoute(c *fiber.Ctx) error {
	originLat, _ := strconv.ParseFloat(c.Query("origin_lat"), 64)
	originLon, _ := strconv.ParseFloat(c.Query("origin_lon"), 64)
	destLat, _ := strconv.ParseFloat(c.Query("dest_lat"), 64)
	destLon, _ := strconv.ParseFloat(c.Query("dest_lon"), 64)

	if originLat == 0 || originLon == 0 || destLat == 0 || destLon == 0 {
		return c.Status(400).JSON(fiber.Map{
			"error": "Missing coordinates",
		})
	}

	// Llamar a GraphHopper
	route, err := ghClient.GetFootRoute(originLat, originLon, destLat, destLon)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "GraphHopper error",
			"details": err.Error(),
		})
	}

	if len(route.Paths) == 0 {
		return c.Status(404).JSON(fiber.Map{
			"error": "No route found",
		})
	}

	// Formatear respuesta compatible con frontend
	path := route.Paths[0]
	
	return c.JSON(fiber.Map{
		"distance_meters":    path.Distance,
		"duration_seconds":   path.Time / 1000, // ms to seconds
		"geometry":           path.Points.Coordinates,
		"instructions":       formatInstructions(path.Instructions),
		"source":             "graphhopper",
	})
}

// ============================================================================
// ENDPOINT: GET /api/route/walking/distance
// ============================================================================
// Calcula SOLO distancia y tiempo (sin geometría, ultra rápido)
// ============================================================================
func GetWalkingDistance(c *fiber.Ctx) error {
	originLat, _ := strconv.ParseFloat(c.Query("origin_lat"), 64)
	originLon, _ := strconv.ParseFloat(c.Query("origin_lon"), 64)
	destLat, _ := strconv.ParseFloat(c.Query("dest_lat"), 64)
	destLon, _ := strconv.ParseFloat(c.Query("dest_lon"), 64)

	if originLat == 0 || originLon == 0 || destLat == 0 || destLon == 0 {
		return c.Status(400).JSON(fiber.Map{
			"error": "Missing coordinates",
		})
	}

	route, err := ghClient.GetFootRoute(originLat, originLon, destLat, destLon)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "GraphHopper error",
			"details": err.Error(),
		})
	}

	if len(route.Paths) == 0 {
		return c.Status(404).JSON(fiber.Map{
			"error": "No route found",
		})
	}

	path := route.Paths[0]
	
	return c.JSON(fiber.Map{
		"distance_meters":    path.Distance,
		"duration_seconds":   path.Time / 1000,
		"duration_formatted": fmt.Sprintf("%d min", path.Time/1000/60),
		"walkable":           path.Distance < 2000, // < 2km es caminable
	})
}

// ============================================================================
// ENDPOINT: GET /api/route/driving
// ============================================================================
// Ruta en automóvil
// ============================================================================
func GetDrivingRoute(c *fiber.Ctx) error {
	originLat, _ := strconv.ParseFloat(c.Query("origin_lat"), 64)
	originLon, _ := strconv.ParseFloat(c.Query("origin_lon"), 64)
	destLat, _ := strconv.ParseFloat(c.Query("dest_lat"), 64)
	destLon, _ := strconv.ParseFloat(c.Query("dest_lon"), 64)

	if originLat == 0 || originLon == 0 || destLat == 0 || destLon == 0 {
		return c.Status(400).JSON(fiber.Map{
			"error": "Missing coordinates",
		})
	}

	// Usar perfil 'car' de GraphHopper
	route, err := ghClient.GetRoute(graphhopper.RouteRequest{
		Points: []graphhopper.Point{
			{Lat: originLat, Lon: originLon},
			{Lat: destLat, Lon: destLon},
		},
		Profile:       "car",
		Locale:        "es",
		PointsEncoded: false,
		Instructions:  true,
		Details:       []string{"street_name", "time", "distance"},
	})

	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "GraphHopper error",
			"details": err.Error(),
		})
	}

	if len(route.Paths) == 0 {
		return c.Status(404).JSON(fiber.Map{
			"error": "No route found",
		})
	}

	path := route.Paths[0]
	
	return c.JSON(fiber.Map{
		"distance_meters":    path.Distance,
		"duration_seconds":   path.Time / 1000,
		"geometry":           path.Points.Coordinates,
		"instructions":       formatInstructions(path.Instructions),
		"source":             "graphhopper",
		"profile":            "car",
	})
}

// ============================================================================
// ENDPOINT: GET /api/route/transit/quick
// ============================================================================
// Obtiene la ruta de transporte público MÁS RÁPIDA (primera opción)
// ============================================================================
func GetQuickTransitRoute(c *fiber.Ctx) error {
	var req struct {
		Origin struct {
			Lat float64 `json:"lat"`
			Lon float64 `json:"lon"`
		} `json:"origin"`
		Destination struct {
			Lat float64 `json:"lat"`
			Lon float64 `json:"lon"`
		} `json:"destination"`
		DepartureTime   *time.Time `json:"departure_time"`
		MaxWalkDistance int        `json:"max_walk_distance"`
	}

	if err := c.BodyParser(&req); err != nil {
		return c.Status(400).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	departureTime := time.Now().Add(2 * time.Minute)
	if req.DepartureTime != nil {
		departureTime = *req.DepartureTime
	}

	maxWalk := req.MaxWalkDistance
	if maxWalk == 0 {
		maxWalk = 800 // Más corto para quick route
	}

	route, err := ghClient.GetPublicTransitRoute(
		req.Origin.Lat, req.Origin.Lon,
		req.Destination.Lat, req.Destination.Lon,
		departureTime,
		maxWalk,
	)

	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "GraphHopper error",
			"details": err.Error(),
		})
	}

	if len(route.Paths) == 0 {
		return c.Status(404).JSON(fiber.Map{
			"error": "No public transit route found",
		})
	}

	// Solo retornar la primera (más rápida)
	return c.JSON(fiber.Map{
		"route": formatTransitPath(route.Paths[0]),
		"source": "graphhopper_gtfs",
	})
}

// ============================================================================
// ENDPOINT: POST /api/route/transit
// ============================================================================
// Ruta con transporte público (GTFS completo) - TODAS las alternativas
// Body JSON:
//   {
//     "origin": {"lat": -33.45, "lon": -70.66},
//     "destination": {"lat": -33.52, "lon": -70.68},
//     "departure_time": "2025-10-18T14:30:00Z",  // opcional, default: now+2min
//     "max_walk_distance": 1000  // opcional, default: 1000m
//   }
// ============================================================================
func GetPublicTransitRoute(c *fiber.Ctx) error {
	var req struct {
		Origin struct {
			Lat float64 `json:"lat"`
			Lon float64 `json:"lon"`
		} `json:"origin"`
		Destination struct {
			Lat float64 `json:"lat"`
			Lon float64 `json:"lon"`
		} `json:"destination"`
		DepartureTime   *time.Time `json:"departure_time"`
		MaxWalkDistance int        `json:"max_walk_distance"`
	}

	if err := c.BodyParser(&req); err != nil {
		return c.Status(400).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	// Default departure time: now + 2 minutes
	departureTime := time.Now().Add(2 * time.Minute)
	if req.DepartureTime != nil {
		departureTime = *req.DepartureTime
	}

	// Default max walk: 1km
	maxWalk := req.MaxWalkDistance
	if maxWalk == 0 {
		maxWalk = 1000
	}

	// Llamar a GraphHopper PT
	route, err := ghClient.GetPublicTransitRoute(
		req.Origin.Lat, req.Origin.Lon,
		req.Destination.Lat, req.Destination.Lon,
		departureTime,
		maxWalk,
	)

	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "GraphHopper error",
			"details": err.Error(),
		})
	}

	if len(route.Paths) == 0 {
		return c.Status(404).JSON(fiber.Map{
			"error": "No public transit route found",
			"suggestion": "Try increasing max_walk_distance or use Moovit scraper endpoint",
		})
	}

	// Formatear todas las alternativas
	alternatives := make([]map[string]interface{}, len(route.Paths))
	for i, path := range route.Paths {
		alternatives[i] = formatTransitPath(path)
	}

	return c.JSON(fiber.Map{
		"alternatives": alternatives,
		"count":        len(alternatives),
		"source":       "graphhopper_gtfs",
	})
}

// ============================================================================
// ENDPOINT: POST /api/route/transit/optimal
// ============================================================================
// Encuentra la ruta ÓPTIMA balanceando tiempo, trasbordos y caminata
// ============================================================================
func GetOptimalTransitRoute(c *fiber.Ctx) error {
	var req struct {
		Origin struct {
			Lat float64 `json:"lat"`
			Lon float64 `json:"lon"`
		} `json:"origin"`
		Destination struct {
			Lat float64 `json:"lat"`
			Lon float64 `json:"lon"`
		} `json:"destination"`
		DepartureTime *time.Time `json:"departure_time"`
		Preferences   struct {
			MinimizeTransfers bool `json:"minimize_transfers"` // Priorizar menos trasbordos
			MinimizeWalking   bool `json:"minimize_walking"`   // Priorizar menos caminata
		} `json:"preferences"`
	}

	if err := c.BodyParser(&req); err != nil {
		return c.Status(400).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	departureTime := time.Now().Add(2 * time.Minute)
	if req.DepartureTime != nil {
		departureTime = *req.DepartureTime
	}

	route, err := ghClient.GetPublicTransitRoute(
		req.Origin.Lat, req.Origin.Lon,
		req.Destination.Lat, req.Destination.Lon,
		departureTime,
		1200, // Más flexible
	)

	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "GraphHopper error",
			"details": err.Error(),
		})
	}

	if len(route.Paths) == 0 {
		return c.Status(404).JSON(fiber.Map{
			"error": "No public transit route found",
		})
	}

	// Encontrar ruta óptima según preferencias
	optimalIdx := 0
	bestScore := float64(999999)

	for i, path := range route.Paths {
		// Calcular score basado en preferencias
		score := float64(path.Time / 1000) // Base: tiempo en segundos

		if req.Preferences.MinimizeTransfers {
			score += float64(path.Transfers) * 600 // Penalizar trasbordos (10min cada uno)
		}

		if req.Preferences.MinimizeWalking {
			// Sumar distancia de piernas walk
			walkDistance := 0.0
			for _, leg := range path.Legs {
				if leg.Type == "walk" {
					walkDistance += leg.Distance
				}
			}
			score += walkDistance * 0.5 // Penalizar caminata
		}

		if score < bestScore {
			bestScore = score
			optimalIdx = i
		}
	}

	return c.JSON(fiber.Map{
		"route":              formatTransitPath(route.Paths[optimalIdx]),
		"alternatives_count": len(route.Paths),
		"optimal_reason":     getOptimalReason(req.Preferences),
		"source":             "graphhopper_gtfs",
	})
}

func getOptimalReason(prefs struct {
	MinimizeTransfers bool `json:"minimize_transfers"`
	MinimizeWalking   bool `json:"minimize_walking"`
}) string {
	if prefs.MinimizeTransfers && prefs.MinimizeWalking {
		return "Menos trasbordos y caminata"
	}
	if prefs.MinimizeTransfers {
		return "Menos trasbordos"
	}
	if prefs.MinimizeWalking {
		return "Menos caminata"
	}
	return "Más rápida"
}

// ============================================================================
// ENDPOINT: POST /api/route/options
// ============================================================================
// Obtiene opciones de ruta SIN geometría completa (ligero)
// Ideal para presentar opciones al usuario antes de cargar geometría completa
// Retorna resumen de: tiempo, distancia, trasbordos
// ============================================================================
func GetRouteOptions(c *fiber.Ctx) error {
	var req struct {
		Origin struct {
			Lat float64 `json:"lat"`
			Lon float64 `json:"lon"`
		} `json:"origin"`
		Destination struct {
			Lat float64 `json:"lat"`
			Lon float64 `json:"lon"`
		} `json:"destination"`
	}

	if err := c.BodyParser(&req); err != nil {
		return c.Status(400).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	options := make([]map[string]interface{}, 0)

	// 1. Opción peatonal directa (si es caminable < 2km)
	footRoute, err := ghClient.GetFootRoute(
		req.Origin.Lat, req.Origin.Lon,
		req.Destination.Lat, req.Destination.Lon,
	)

	if err == nil && len(footRoute.Paths) > 0 {
		path := footRoute.Paths[0]
		if path.Distance < 2000 {
			options = append(options, map[string]interface{}{
				"type":            "walking",
				"distance_meters": path.Distance,
				"duration_seconds": path.Time / 1000,
				"description":      fmt.Sprintf("Caminar %.1f km", path.Distance/1000),
			})
		}
	}

	// 2. Opciones de transporte público (GTFS)
	departureTime := time.Now().Add(2 * time.Minute)
	transitRoute, err := ghClient.GetPublicTransitRoute(
		req.Origin.Lat, req.Origin.Lon,
		req.Destination.Lat, req.Destination.Lon,
		departureTime,
		1000,
	)

	if err == nil && len(transitRoute.Paths) > 0 {
		// Tomar las mejores 3 opciones
		maxOptions := 3
		if len(transitRoute.Paths) < maxOptions {
			maxOptions = len(transitRoute.Paths)
		}

		for i := 0; i < maxOptions; i++ {
			path := transitRoute.Paths[i]
			
			// Extraer info resumida de las piernas PT
			var busRoutes []string
			for _, leg := range path.Legs {
				if leg.Type == "pt" && leg.RouteShortName != "" {
					busRoutes = append(busRoutes, leg.RouteShortName)
				}
			}

			description := fmt.Sprintf("%d min", path.Time/1000/60)
			if len(busRoutes) > 0 {
				description = fmt.Sprintf("Bus %s - %d min", 
					strings.Join(busRoutes, " + "), 
					path.Time/1000/60)
			}

			options = append(options, map[string]interface{}{
				"type":             "transit",
				"distance_meters":  path.Distance,
				"duration_seconds": path.Time / 1000,
				"transfers":        path.Transfers,
				"routes":           busRoutes,
				"description":      description,
			})
		}
	}

	if len(options) == 0 {
		return c.Status(404).JSON(fiber.Map{
			"error": "No routes found",
		})
	}

	return c.JSON(fiber.Map{
		"options":     options,
		"origin":      req.Origin,
		"destination": req.Destination,
	})
}

// ============================================================================
// FUNCIONES AUXILIARES
// ============================================================================

func formatInstructions(instructions []graphhopper.Instruction) []map[string]interface{} {
	result := make([]map[string]interface{}, len(instructions))
	for i, inst := range instructions {
		result[i] = map[string]interface{}{
			"text":        inst.Text,
			"distance":    inst.Distance,
			"time":        inst.Time / 1000, // ms to seconds
			"street_name": inst.StreetName,
			"sign":        inst.Sign,
		}
	}
	return result
}

func formatTransitPath(path graphhopper.Path) map[string]interface{} {
	legs := make([]map[string]interface{}, len(path.Legs))
	
	for i, leg := range path.Legs {
		legMap := map[string]interface{}{
			"type":      leg.Type,
			"distance":  leg.Distance,
			"geometry":  leg.Geometry.Coordinates,
		}

		if leg.Type == "pt" {
			// Información de transporte público
			legMap["route_short_name"] = leg.RouteShortName
			legMap["route_long_name"] = leg.RouteLongName
			legMap["headsign"] = leg.Headsign
			legMap["departure_time"] = time.Unix(leg.DepartureTime/1000, 0).Format(time.RFC3339)
			legMap["arrival_time"] = time.Unix(leg.ArrivalTime/1000, 0).Format(time.RFC3339)
			legMap["num_stops"] = leg.NumStops
			
			// Formatear paradas
			if len(leg.Stops) > 0 {
				stops := make([]map[string]interface{}, len(leg.Stops))
				for j, stop := range leg.Stops {
					stops[j] = map[string]interface{}{
						"name":     stop.StopName,
						"lat":      stop.Lat,
						"lon":      stop.Lon,
						"sequence": stop.StopSequence,
					}
				}
				legMap["stops"] = stops
			}
		} else if leg.Type == "walk" {
			// Información de caminata
			if len(leg.Instructions) > 0 {
				legMap["instructions"] = formatInstructions(leg.Instructions)
			}
		}

		legs[i] = legMap
	}

	return map[string]interface{}{
		"distance_meters":  path.Distance,
		"duration_seconds": path.Time / 1000,
		"transfers":        path.Transfers,
		"legs":             legs,
	}
}
