package handlers

import (
	"database/sql"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/geometry"
	"github.com/yourorg/wayfindcl/internal/moovit"
)

// RedBusHandler maneja las solicitudes de rutas de buses Red
type RedBusHandler struct {
	scraper    *moovit.Scraper
	routeCache *RouteCache
}

// GeometryServiceAdapter adapta geometry.Service para moovit.GeometryService
type GeometryServiceAdapter struct {
	service *geometry.Service
}

func (g *GeometryServiceAdapter) GetWalkingRoute(fromLat, fromLon, toLat, toLon float64, detailed bool) (moovit.RouteGeometry, error) {
	route, err := g.service.GetWalkingRoute(fromLat, fromLon, toLat, toLon, detailed)
	if err != nil {
		return moovit.RouteGeometry{}, err
	}

	instructions := make([]string, 0)
	for _, segment := range route.SegmentGeometries {
		if len(segment.Instructions) > 0 {
			instructions = append(instructions, segment.Instructions...)
		}
	}

	return moovit.RouteGeometry{
		TotalDistance: route.TotalDistance,
		TotalDuration: route.TotalDuration,
		MainGeometry:  route.MainGeometry,
		Instructions:  instructions,
	}, nil
}

func (g *GeometryServiceAdapter) GetVehicleRoute(fromLat, fromLon, toLat, toLon float64) (moovit.RouteGeometry, error) {
	route, err := g.service.GetVehicleRoute(fromLat, fromLon, toLat, toLon)
	if err != nil {
		return moovit.RouteGeometry{}, err
	}

	instructions := make([]string, 0)
	for _, segment := range route.SegmentGeometries {
		if len(segment.Instructions) > 0 {
			instructions = append(instructions, segment.Instructions...)
		}
	}

	return moovit.RouteGeometry{
		TotalDistance: route.TotalDistance,
		TotalDuration: route.TotalDuration,
		MainGeometry:  route.MainGeometry,
		Instructions:  instructions,
	}, nil
}

// NewRedBusHandler crea una nueva instancia del handler
func NewRedBusHandler(db *sql.DB) *RedBusHandler {
	scraper := moovit.NewScraper()
	if db != nil {
		scraper.SetDB(db)
		log.Printf("✅ RedBusHandler configurado con acceso a base de datos GTFS")
	} else {
		log.Printf("⚠️  RedBusHandler creado sin base de datos - solo funcionará scraping Moovit")
	}

	// NOTA: El servicio de geometría se configurará después con ConfigureRedBusGeometry()
	// porque se inicializa después de que se crean los handlers

	// Crear caché de rutas: 15 minutos TTL, máximo 100 rutas
	cache := NewRouteCache(15*time.Minute, 100)
	log.Printf("✅ RouteCache inicializado (TTL: 15 min, max: 100 rutas)")

	return &RedBusHandler{
		scraper:    scraper,
		routeCache: cache,
	}
}

// ConfigureRedBusGeometry configura el servicio de geometría en el scraper existente
func (h *RedBusHandler) ConfigureRedBusGeometry(geometrySvc *geometry.Service) {
	if geometrySvc != nil {
		adapter := &GeometryServiceAdapter{service: geometrySvc}
		h.scraper.SetGeometryService(adapter)
		log.Printf("✅ RedBusHandler configurado con servicio de geometría (GraphHopper)")
	} else {
		log.Printf("⚠️  RedBusHandler sin servicio de geometría - usará líneas rectas para caminatas")
	}
}

// GetRedBusRoute maneja GET /api/red/route/:routeNumber
// Obtiene información detallada de una ruta de bus Red específica
func (h *RedBusHandler) GetRedBusRoute(c *fiber.Ctx) error {
	routeNumber := c.Params("routeNumber")

	if routeNumber == "" {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "route number is required",
		})
	}

	log.Printf("Fetching Red bus route: %s", routeNumber)

	route, err := h.scraper.GetRedBusRoute(routeNumber)
	if err != nil {
		log.Printf("Error fetching route %s: %v", routeNumber, err)
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": fmt.Sprintf("error fetching route: %v", err),
		})
	}

	return c.JSON(route)
}

// GetRedBusItinerary maneja POST /api/red/itinerary
// Obtiene un itinerario completo usando buses Red desde Moovit
func (h *RedBusHandler) GetRedBusItinerary(c *fiber.Ctx) error {
	type ItineraryRequest struct {
		OriginLat float64 `json:"origin_lat"`
		OriginLon float64 `json:"origin_lon"`
		DestLat   float64 `json:"dest_lat"`
		DestLon   float64 `json:"dest_lon"`
	}

	var req ItineraryRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "invalid request format",
		})
	}

	// Validar coordenadas
	if req.OriginLat < -90 || req.OriginLat > 90 ||
		req.OriginLon < -180 || req.OriginLon > 180 ||
		req.DestLat < -90 || req.DestLat > 90 ||
		req.DestLon < -180 || req.DestLon > 180 {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "invalid coordinates",
		})
	}

	log.Printf("Fetching Red bus itinerary from (%.4f, %.4f) to (%.4f, %.4f)",
		req.OriginLat, req.OriginLon, req.DestLat, req.DestLon)

	// Intentar obtener del caché primero
	if cachedRoute, found := h.routeCache.Get(req.OriginLat, req.OriginLon, req.DestLat, req.DestLon); found {
		log.Printf("✅ Retornando ruta desde caché")
		return c.JSON(cachedRoute)
	}

	log.Printf("🔄 Ruta no en caché, calculando nueva ruta...")

	// Obtener múltiples opciones de rutas
	routeOptions, err := h.scraper.GetRouteItinerary(
		req.OriginLat,
		req.OriginLon,
		req.DestLat,
		req.DestLon,
	)
	if err != nil {
		log.Printf("Error fetching itinerary: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": fmt.Sprintf("error fetching itinerary: %v", err),
		})
	}

	// Guardar en caché para futuras consultas
	h.routeCache.Set(req.OriginLat, req.OriginLon, req.DestLat, req.DestLon, routeOptions)

	// Retornar TODAS las opciones para que el usuario elija por voz en Flutter
	return c.JSON(routeOptions)
}

// GetRedBusItineraryOptions maneja POST /api/red/itinerary/options
// FASE 1: Obtiene opciones LIGERAS sin geometría para selección por voz
func (h *RedBusHandler) GetRedBusItineraryOptions(c *fiber.Ctx) error {
	type ItineraryRequest struct {
		OriginLat float64 `json:"origin_lat"`
		OriginLon float64 `json:"origin_lon"`
		DestLat   float64 `json:"dest_lat"`
		DestLon   float64 `json:"dest_lon"`
	}

	var req ItineraryRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "invalid request format",
		})
	}

	// Validar coordenadas
	if req.OriginLat < -90 || req.OriginLat > 90 ||
		req.OriginLon < -180 || req.OriginLon > 180 ||
		req.DestLat < -90 || req.DestLat > 90 ||
		req.DestLon < -180 || req.DestLon > 180 {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "invalid coordinates",
		})
	}

	log.Printf("🚌 FASE 1: Obteniendo opciones ligeras de (%.4f, %.4f) a (%.4f, %.4f)",
		req.OriginLat, req.OriginLon, req.DestLat, req.DestLon)

	// Obtener opciones LIGERAS (sin geometría)
	lightweightOptions, err := h.scraper.GetLightweightRouteOptions(
		req.OriginLat,
		req.OriginLon,
		req.DestLat,
		req.DestLon,
	)
	if err != nil {
		log.Printf("Error obteniendo opciones ligeras: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": fmt.Sprintf("error obteniendo opciones: %v", err),
		})
	}

	log.Printf("✅ Retornando %d opciones ligeras para selección por voz", len(lightweightOptions.Options))

	// 📊 RESUMEN DE OPCIONES DISPONIBLES
	if len(lightweightOptions.Options) > 0 {
		log.Printf("\n╔══════════════════════════════════════════════════════════════════╗")
		log.Printf("║              OPCIONES DE RUTA DISPONIBLES (FASE 1)              ║")
		log.Printf("╠══════════════════════════════════════════════════════════════════╣")
		for i, option := range lightweightOptions.Options {
			busesText := strings.Join(option.RouteNumbers, ", ")
			log.Printf("║ Opción %d: Bus %s", i+1, busesText)
			log.Printf("║   ⏱️  Duración: %d minutos", option.TotalDuration)
			if option.Transfers > 0 {
				log.Printf("║   🔄 Transbordos: %d", option.Transfers)
			}
			if option.WalkingTime > 0 {
				log.Printf("║   🚶 Caminata: %d minutos", option.WalkingTime)
			}
			log.Printf("║   📝 %s", option.Summary)
			if i < len(lightweightOptions.Options)-1 {
				log.Printf("╟──────────────────────────────────────────────────────────────────╢")
			}
		}
		log.Printf("╚══════════════════════════════════════════════════════════════════╝\n")
	}

	// Retornar opciones para que Flutter las lea por voz
	return c.JSON(lightweightOptions)
}

// GetRedBusItineraryDetail maneja POST /api/red/itinerary/detail
// FASE 2: Genera geometría completa DESPUÉS de que usuario selecciona por voz
func (h *RedBusHandler) GetRedBusItineraryDetail(c *fiber.Ctx) error {
	type DetailRequest struct {
		OriginLat           float64 `json:"origin_lat"`
		OriginLon           float64 `json:"origin_lon"`
		DestLat             float64 `json:"dest_lat"`
		DestLon             float64 `json:"dest_lon"`
		SelectedOptionIndex int     `json:"selected_option_index"`
	}

	var req DetailRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "invalid request format",
		})
	}

	// Validar coordenadas
	if req.OriginLat < -90 || req.OriginLat > 90 ||
		req.OriginLon < -180 || req.OriginLon > 180 ||
		req.DestLat < -90 || req.DestLat > 90 ||
		req.DestLon < -180 || req.DestLon > 180 {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "invalid coordinates",
		})
	}

	// Validar índice de opción
	if req.SelectedOptionIndex < 0 {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "selected_option_index must be >= 0",
		})
	}

	log.Printf("🚌 FASE 2: Generando geometría detallada para opción %d", req.SelectedOptionIndex)

	// Generar geometría completa para la opción seleccionada
	detailedItinerary, err := h.scraper.GetDetailedItinerary(
		req.OriginLat,
		req.OriginLon,
		req.DestLat,
		req.DestLon,
		req.SelectedOptionIndex,
	)
	if err != nil {
		log.Printf("Error generando itinerario detallado: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": fmt.Sprintf("error generando geometría: %v", err),
		})
	}

	log.Printf("✅ Geometría detallada generada con %d legs", len(detailedItinerary.Legs))

	// � RESUMEN VISUAL DE LA RUTA (estilo Google Maps)
	log.Printf("\n╔══════════════════════════════════════════════════════════════════╗")
	log.Printf("║                    RESUMEN DE RUTA GENERADA                      ║")
	log.Printf("╠══════════════════════════════════════════════════════════════════╣")

	// Extraer información de los buses
	totalBusStops := 0
	busDuration := 0
	busRoutes := []string{}
	walkDuration := 0
	totalWalkDistance := 0.0

	for _, leg := range detailedItinerary.Legs {
		if leg.Type == "bus" {
			totalBusStops += len(leg.Stops)
			busDuration += leg.Duration
			if leg.RouteNumber != "" {
				busRoutes = append(busRoutes, leg.RouteNumber)
			}
		} else if leg.Type == "walk" {
			walkDuration += leg.Duration
			totalWalkDistance += leg.Distance
		}
	}

	log.Printf("║ 🚌 Buses a tomar: %s", strings.Join(busRoutes, ", "))
	log.Printf("║ 🚏 Total de paradas: %d paradas", totalBusStops)
	log.Printf("║ ⏱️  Tiempo en bus: %d minutos", busDuration)
	log.Printf("║ 🚶 Tiempo caminando: %d minutos (%.2f km)", walkDuration, totalWalkDistance)
	log.Printf("║ ⏰ Duración total: %d minutos", detailedItinerary.TotalDuration)
	log.Printf("║ 📏 Distancia total: %.2f km", detailedItinerary.TotalDistance)
	log.Printf("╚══════════════════════════════════════════════════════════════════╝\n")

	// �� DEBUG: Mostrar datos que se envían al frontend
	log.Printf("🔍 [DEBUG-RESPONSE] ========== DATOS ENVIADOS AL FRONTEND ==========")
	log.Printf("🔍 [DEBUG-RESPONSE] Total Legs: %d", len(detailedItinerary.Legs))
	log.Printf("🔍 [DEBUG-RESPONSE] Duración Total: %d min", detailedItinerary.TotalDuration)
	log.Printf("🔍 [DEBUG-RESPONSE] Distancia Total: %.2f km", detailedItinerary.TotalDistance)
	log.Printf("🔍 [DEBUG-RESPONSE] Rutas de Bus: %v", detailedItinerary.RedBusRoutes)

	for i, leg := range detailedItinerary.Legs {
		log.Printf("🔍 [DEBUG-RESPONSE-LEG-%d] ----------------------", i+1)
		log.Printf("   Type: %s", leg.Type)
		log.Printf("   Mode: %s", leg.Mode)
		log.Printf("   RouteNumber: %s", leg.RouteNumber)
		log.Printf("   From: %s", leg.From)
		log.Printf("   To: %s", leg.To)
		log.Printf("   Duration: %d min", leg.Duration)
		log.Printf("   Distance: %.2f km", leg.Distance)
		log.Printf("   Geometry Points: %d", len(leg.Geometry))
		log.Printf("   StopCount: %d", leg.StopCount)
		log.Printf("   Total Stops in array: %d", len(leg.Stops))

		if len(leg.Geometry) > 0 {
			log.Printf("   Geometría - Primer punto: [%.6f, %.6f]", leg.Geometry[0][1], leg.Geometry[0][0])
			log.Printf("   Geometría - Último punto: [%.6f, %.6f]",
				leg.Geometry[len(leg.Geometry)-1][1], leg.Geometry[len(leg.Geometry)-1][0])
		} else {
			log.Printf("   ⚠️  SIN GEOMETRÍA EN ESTE LEG")
		}

		if leg.DepartStop != nil {
			log.Printf("   DepartStop: %s (%.6f, %.6f)",
				leg.DepartStop.Name, leg.DepartStop.Latitude, leg.DepartStop.Longitude)
		}

		if leg.ArriveStop != nil {
			log.Printf("   ArriveStop: %s (%.6f, %.6f)",
				leg.ArriveStop.Name, leg.ArriveStop.Latitude, leg.ArriveStop.Longitude)
		}

		if len(leg.Stops) > 0 {
			log.Printf("   ┌─────────────────────────────────────────────────────────────┐")
			log.Printf("   │ 🚏 PARADAS DE LA RUTA %s (%d paradas)", leg.RouteNumber, len(leg.Stops))
			log.Printf("   ├─────────────────────────────────────────────────────────────┤")
			for j, stop := range leg.Stops {
				stopType := "   "
				if j == 0 {
					stopType = "🟢" // Primera parada
				} else if j == len(leg.Stops)-1 {
					stopType = "🔴" // Última parada
				} else {
					stopType = "⚪" // Parada intermedia
				}
				log.Printf("   │ %s %2d. %-45s [%s]", stopType, j+1, stop.Name, stop.Code)
			}
			log.Printf("   └─────────────────────────────────────────────────────────────┘")
		}
	}
	log.Printf("🔍 [DEBUG-RESPONSE] ========== FIN DATOS ==========")

	return c.JSON(detailedItinerary)
}

// ListCommonRedRoutes maneja GET /api/red/routes/common
// Lista rutas Red comunes en Santiago
func (h *RedBusHandler) ListCommonRedRoutes(c *fiber.Ctx) error {
	commonRoutes := []fiber.Map{
		{
			"route_number": "506",
			"name":         "Línea 506 - Alameda / Vicuña Mackenna",
			"description":  "Conecta el centro con Peñalolén",
			"zones":        []string{"Centro", "Providencia", "Ñuñoa", "Peñalolén"},
		},
		{
			"route_number": "210",
			"name":         "Línea 210 - Estación Central / Providencia",
			"description":  "Ruta que conecta el poniente con el oriente",
			"zones":        []string{"Estación Central", "Santiago", "Providencia"},
		},
		{
			"route_number": "405",
			"name":         "Línea 405 - Independencia / Recoleta",
			"description":  "Servicio en el sector norte de Santiago",
			"zones":        []string{"Independencia", "Recoleta", "Conchalí"},
		},
		{
			"route_number": "427",
			"name":         "Línea 427 - Maipú / Pudahuel",
			"description":  "Conecta comunas del poniente",
			"zones":        []string{"Maipú", "Pudahuel", "Estación Central"},
		},
		{
			"route_number": "516",
			"name":         "Línea 516 - La Florida / Puente Alto",
			"description":  "Servicio en el sector sur-oriente",
			"zones":        []string{"La Florida", "Puente Alto", "San José de Maipo"},
		},
	}

	return c.JSON(fiber.Map{
		"total":  len(commonRoutes),
		"routes": commonRoutes,
	})
}

// SearchRedRoutes maneja GET /api/red/routes/search?q=query
// Busca rutas Red por nombre o zona
func (h *RedBusHandler) SearchRedRoutes(c *fiber.Ctx) error {
	query := c.Query("q")

	if query == "" {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "search query is required",
		})
	}

	// En producción, esto debería buscar en una base de datos
	// Por ahora, retornamos resultados de ejemplo
	results := []fiber.Map{
		{
			"route_number": "506",
			"name":         "Línea 506",
			"relevance":    0.95,
		},
	}

	return c.JSON(fiber.Map{
		"query":   query,
		"total":   len(results),
		"results": results,
	})
}

// GetRedBusStops maneja GET /api/red/route/:routeNumber/stops
// Obtiene todas las paradas de una ruta Red específica
func (h *RedBusHandler) GetRedBusStops(c *fiber.Ctx) error {
	routeNumber := c.Params("routeNumber")

	if routeNumber == "" {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "route number is required",
		})
	}

	route, err := h.scraper.GetRedBusRoute(routeNumber)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": fmt.Sprintf("error fetching route: %v", err),
		})
	}

	return c.JSON(fiber.Map{
		"route_number": routeNumber,
		"route_name":   route.RouteName,
		"total_stops":  len(route.Stops),
		"stops":        route.Stops,
	})
}

// GetCacheStats maneja GET /api/red/cache/stats
// Devuelve estadísticas del caché de rutas
func (h *RedBusHandler) GetCacheStats(c *fiber.Ctx) error {
	stats := h.routeCache.Stats()
	return c.JSON(fiber.Map{
		"status": "ok",
		"cache":  stats,
	})
}

// ClearCache maneja POST /api/red/cache/clear
// Limpia todo el caché de rutas
func (h *RedBusHandler) ClearCache(c *fiber.Ctx) error {
	h.routeCache.Clear()
	return c.JSON(fiber.Map{
		"status":  "ok",
		"message": "Cache cleared successfully",
	})
}

// GetRedBusGeometry maneja GET /api/red/route/:routeNumber/geometry
// Obtiene la geometría (polilínea) de una ruta Red para visualización en mapa
func (h *RedBusHandler) GetRedBusGeometry(c *fiber.Ctx) error {
	routeNumber := c.Params("routeNumber")

	if routeNumber == "" {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "route number is required",
		})
	}

	route, err := h.scraper.GetRedBusRoute(routeNumber)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": fmt.Sprintf("error fetching route: %v", err),
		})
	}

	return c.JSON(fiber.Map{
		"route_number": routeNumber,
		"type":         "LineString",
		"coordinates":  route.Geometry,
		"properties": fiber.Map{
			"name":         route.RouteName,
			"color":        "#E30613", // Color rojo característico de buses Red
			"stroke_width": 4,
			"stops_count":  len(route.Stops),
		},
	})
}
