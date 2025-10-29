// ============================================================================
// GEOMETRY SERVICE - WayFindCL
// ============================================================================
// Servicio centralizado para TODOS los cálculos geométricos
// Integra: GTFS (DB) + GraphHopper + Cálculos propios
// ============================================================================

package geometry

import (
	"database/sql"
	"fmt"
	"log"
	"math"
	"strings"
	"time"

	"github.com/yourorg/wayfindcl/internal/graphhopper"
)

// Service centraliza TODOS los cálculos geométricos del sistema
type Service struct {
	db       *sql.DB
	ghClient *graphhopper.Client
}

// NewService crea una instancia del servicio de geometría
func NewService(db *sql.DB, ghClient *graphhopper.Client) *Service {
	return &Service{
		db:       db,
		ghClient: ghClient,
	}
}

// ============================================================================
// ESTRUCTURAS DE DATOS
// ============================================================================

// Point representa un punto geográfico
type Point struct {
	Lat float64 `json:"lat"`
	Lon float64 `json:"lon"`
}

// Stop representa una parada de bus con geometría
type Stop struct {
	ID       int64   `json:"id"`
	Code     string  `json:"code"`
	Name     string  `json:"name"`
	Lat      float64 `json:"lat"`
	Lon      float64 `json:"lon"`
	Distance float64 `json:"distance_meters,omitempty"` // Distancia desde punto de referencia
}

// RouteGeometry representa la geometría de una ruta completa
type RouteGeometry struct {
	Type              string      `json:"type"` // "walking", "driving", "transit"
	TotalDistance     float64     `json:"total_distance_meters"`
	TotalDuration     int         `json:"total_duration_seconds"`
	MainGeometry      [][]float64 `json:"main_geometry"`      // Geometría principal [lon, lat]
	SegmentGeometries []Segment   `json:"segments,omitempty"` // Segmentos individuales
}

// Segment representa un segmento de una ruta (walk, wait, ride)
type Segment struct {
	Type         string      `json:"type"` // "walk", "wait_bus", "ride_bus"
	Distance     float64     `json:"distance_meters"`
	Duration     int         `json:"duration_seconds"`
	Geometry     [][]float64 `json:"geometry"` // [lon, lat] pairs
	Instructions []string    `json:"instructions,omitempty"`
	InstructionIntervals [][]int `json:"instruction_intervals,omitempty"` // ✅ Intervalos de puntos para cada instrucción
	// Para segmentos de bus
	RouteID        string `json:"route_id,omitempty"`
	RouteShortName string `json:"route_short_name,omitempty"`
	Stops          []Stop `json:"stops,omitempty"`
}

// ============================================================================
// MÉTODOS PRINCIPALES - CÁLCULOS GEOMÉTRICOS
// ============================================================================

// translateInstruction convierte instrucciones de GraphHopper a español accesible
// Optimizado para usuarios con discapacidad visual usando TTS
func translateInstruction(ghInstruction string) string {
	text := strings.ToLower(strings.TrimSpace(ghInstruction))
	
	// Eliminar prefijos técnicos
	text = strings.TrimPrefix(text, "continue ")
	text = strings.TrimPrefix(text, "head ")
	text = strings.TrimPrefix(text, "keep ")
	
	// Diccionario de traducciones inglés → español
	replacements := map[string]string{
		// Giros
		"turn left":         "Gira a la izquierda",
		"turn right":        "Gira a la derecha",
		"turn slight left":  "Gira ligeramente a la izquierda",
		"turn slight right": "Gira ligeramente a la derecha",
		"turn sharp left":   "Gira fuertemente a la izquierda",
		"turn sharp right":  "Gira fuertemente a la derecha",
		
		// Continuaciones
		"continue":     "Continúa",
		"onto":         "por",
		"on":           "por",
		"straight":     "recto",
		"ahead":        "adelante",
		
		// Direcciones cardinales
		"head south":   "Dirígete al sur",
		"head north":   "Dirígete al norte",
		"head east":    "Dirígete al este",
		"head west":    "Dirígete al oeste",
		"north":        "norte",
		"south":        "sur",
		"east":         "este",
		"west":         "oeste",
		
		// Elementos viales
		"roundabout":   "rotonda",
		"at the":       "en la",
		"at ":          "en ",
		"the ":         "",
		
		// Destino
		"arrive at":    "Llegas a",
		"destination":  "destino",
		"finish":       "Fin del recorrido",
		
		// Distancias (si vienen en el texto)
		"meters":       "metros",
		"kilometers":   "kilómetros",
		"km":           "kilómetros",
	}
	
	// Aplicar reemplazos
	for en, es := range replacements {
		text = strings.ReplaceAll(text, en, es)
	}
	
	// Limpiar espacios múltiples
	text = strings.Join(strings.Fields(text), " ")
	
	// Capitalizar primera letra
	if len(text) > 0 {
		runes := []rune(text)
		runes[0] = []rune(strings.ToUpper(string(runes[0])))[0]
		text = string(runes)
	}
	
	return text
}

// GetWalkingRoute obtiene geometría de ruta peatonal usando GraphHopper
// CENTRALIZA: Todo cálculo de rutas peatonales
func (s *Service) GetWalkingRoute(fromLat, fromLon, toLat, toLon float64, detailed bool) (*RouteGeometry, error) {
	if !detailed {
		// Solo distancia y tiempo (sin geometría completa)
		route, err := s.ghClient.GetFootRoute(fromLat, fromLon, toLat, toLon)
		if err != nil {
			return nil, fmt.Errorf("graphhopper walking route: %w", err)
		}

		if len(route.Paths) == 0 {
			return nil, fmt.Errorf("no walking route found")
		}

		path := route.Paths[0]
		return &RouteGeometry{
			Type:          "walking",
			TotalDistance: path.Distance,
			TotalDuration: int(path.Time / 1000),
			MainGeometry:  [][]float64{}, // Sin geometría si no es detallado
		}, nil
	}

	// Ruta detallada con geometría completa
	route, err := s.ghClient.GetFootRoute(fromLat, fromLon, toLat, toLon)
	if err != nil {
		return nil, fmt.Errorf("graphhopper walking route: %w", err)
	}

	if len(route.Paths) == 0 {
		return nil, fmt.Errorf("no walking route found")
	}

	path := route.Paths[0]

	// ✅ Extraer y traducir instrucciones a español accesible
	instructions := make([]string, len(path.Instructions))
	intervals := make([][]int, len(path.Instructions))
	for i, inst := range path.Instructions {
		translated := translateInstruction(inst.Text)
		instructions[i] = translated
		intervals[i] = inst.Interval // ✅ Guardar intervalo de puntos
		
		// Log de traducción para debugging
		if inst.Text != translated {
			log.Printf("📝 Instrucción %d: %s → %s (puntos %v)", i+1, inst.Text, translated, inst.Interval)
		}
	}

	return &RouteGeometry{
		Type:          "walking",
		TotalDistance: path.Distance,
		TotalDuration: int(path.Time / 1000),
		MainGeometry:  path.Points.Coordinates,
		SegmentGeometries: []Segment{
			{
				Type:                 "walk",
				Distance:             path.Distance,
				Duration:             int(path.Time / 1000),
				Geometry:             path.Points.Coordinates,
				Instructions:         instructions,
				InstructionIntervals: intervals, // ✅ Incluir intervalos
			},
		},
	}, nil
}

// getRouteGeometry centraliza la construcción de rutas usando distintos perfiles
func (s *Service) getRouteGeometry(profile, routeType, segmentType string, fromLat, fromLon, toLat, toLon float64) (*RouteGeometry, error) {
	route, err := s.ghClient.GetRoute(graphhopper.RouteRequest{
		Points: []graphhopper.Point{
			{Lat: fromLat, Lon: fromLon},
			{Lat: toLat, Lon: toLon},
		},
		Profile:       profile,
		Locale:        "es",
		PointsEncoded: false,
		Instructions:  true,
	})

	if err != nil {
		return nil, fmt.Errorf("graphhopper %s route: %w", profile, err)
	}

	if len(route.Paths) == 0 {
		return nil, fmt.Errorf("no %s route found", profile)
	}

	path := route.Paths[0]
	
	// ✅ Traducir instrucciones a español accesible y extraer intervalos
	instructions := make([]string, len(path.Instructions))
	intervals := make([][]int, len(path.Instructions))
	for i, inst := range path.Instructions {
		instructions[i] = translateInstruction(inst.Text)
		intervals[i] = inst.Interval // ✅ Guardar intervalo de puntos
	}

	return &RouteGeometry{
		Type:          routeType,
		TotalDistance: path.Distance,
		TotalDuration: int(path.Time / 1000),
		MainGeometry:  path.Points.Coordinates,
		SegmentGeometries: []Segment{
			{
				Type:                 segmentType,
				Distance:             path.Distance,
				Duration:             int(path.Time / 1000),
				Geometry:             path.Points.Coordinates,
				Instructions:         instructions,
				InstructionIntervals: intervals, // ✅ Incluir intervalos
			},
		},
	}, nil
}

// GetDrivingRoute obtiene geometría de ruta en auto (perfil "car")
func (s *Service) GetDrivingRoute(fromLat, fromLon, toLat, toLon float64) (*RouteGeometry, error) {
	return s.getRouteGeometry("car", "driving", "drive", fromLat, fromLon, toLat, toLon)
}

// GetVehicleRoute obtiene geometría vehicular para buses (perfil "bus")
func (s *Service) GetVehicleRoute(fromLat, fromLon, toLat, toLon float64) (*RouteGeometry, error) {
	return s.getRouteGeometry("bus", "driving", "drive", fromLat, fromLon, toLat, toLon)
}

// GetMetroRoute obtiene geometría específica para rutas de metro (perfil "metro")
// Usa el nuevo perfil metro de GraphHopper optimizado para velocidad y líneas directas
func (s *Service) GetMetroRoute(fromLat, fromLon, toLat, toLon float64) (*RouteGeometry, error) {
	return s.getRouteGeometry("metro", "metro", "metro_ride", fromLat, fromLon, toLat, toLon)
}

// GetTransitRoute obtiene ruta completa con transporte público
// CENTRALIZA: GTFS (DB) + GraphHopper + Geometrías
func (s *Service) GetTransitRoute(fromLat, fromLon, toLat, toLon float64, departureTime time.Time) (*RouteGeometry, error) {
	// Obtener rutas de GraphHopper con GTFS
	route, err := s.ghClient.GetPublicTransitRoute(
		fromLat, fromLon, toLat, toLon,
		departureTime,
		1000, // max walk distance
	)

	if err != nil {
		return nil, fmt.Errorf("graphhopper transit route: %w", err)
	}

	if len(route.Paths) == 0 {
		return nil, fmt.Errorf("no transit route found")
	}

	path := route.Paths[0]

	// Convertir legs de GraphHopper a Segments enriquecidos con GTFS
	segments := make([]Segment, 0, len(path.Legs))

	for _, leg := range path.Legs {
		segment := Segment{
			Type:     leg.Type,
			Distance: leg.Distance,
			Duration: int((leg.ArrivalTime - leg.DepartureTime) / 1000),
			Geometry: leg.Geometry.Coordinates,
		}

		if leg.Type == "walk" {
			// Segmento peatonal
			instructions := make([]string, len(leg.Instructions))
			for i, inst := range leg.Instructions {
				instructions[i] = inst.Text
			}
			segment.Instructions = instructions
		} else if leg.Type == "pt" {
			// Segmento de transporte público - enriquecer con datos GTFS
			segment.RouteID = leg.RouteID
			segment.RouteShortName = leg.RouteShortName

			// Obtener información detallada de paradas desde GTFS (DB)
			stops, err := s.enrichStopsFromGTFS(leg.Stops)
			if err == nil {
				segment.Stops = stops
			} else {
				// Fallback: usar paradas básicas de GraphHopper
				segment.Stops = convertGraphHopperStops(leg.Stops)
			}
		}

		segments = append(segments, segment)
	}

	return &RouteGeometry{
		Type:              "transit",
		TotalDistance:     path.Distance,
		TotalDuration:     int(path.Time / 1000),
		MainGeometry:      path.Points.Coordinates,
		SegmentGeometries: segments,
	}, nil
}

// ============================================================================
// MÉTODOS DE APOYO - INTEGRACIÓN CON GTFS (DB)
// ============================================================================

// enrichStopsFromGTFS enriquece paradas con información completa de GTFS
// CENTRALIZA: Consultas a DB para información de paradas
func (s *Service) enrichStopsFromGTFS(ghStops []graphhopper.Stop) ([]Stop, error) {
	if len(ghStops) == 0 {
		return []Stop{}, nil
	}

	enriched := make([]Stop, 0, len(ghStops))

	for _, ghStop := range ghStops {
		// Buscar parada en GTFS por ID o coordenadas cercanas
		var stop Stop
		err := s.db.QueryRow(`
			SELECT id, stop_code, stop_name, stop_lat, stop_lon
			FROM gtfs_stops
			WHERE stop_id = ? OR (
				ABS(stop_lat - ?) < 0.0001 AND 
				ABS(stop_lon - ?) < 0.0001
			)
			LIMIT 1
		`, ghStop.StopID, ghStop.Lat, ghStop.Lon).Scan(
			&stop.ID, &stop.Code, &stop.Name, &stop.Lat, &stop.Lon,
		)

		if err != nil {
			// Si no se encuentra en GTFS, usar datos de GraphHopper
			stop = Stop{
				Code: ghStop.StopID,
				Name: ghStop.StopName,
				Lat:  ghStop.Lat,
				Lon:  ghStop.Lon,
			}
		}

		enriched = append(enriched, stop)
	}

	return enriched, nil
}

// GetNearbyStopsFromGTFS obtiene paradas cercanas desde GTFS (DB)
// CENTRALIZA: Búsqueda espacial de paradas
func (s *Service) GetNearbyStopsFromGTFS(lat, lon float64, radiusMeters int, limit int) ([]Stop, error) {
	// Convertir radio de metros a grados aproximados
	// 1 grado ≈ 111km en el ecuador
	radiusDeg := float64(radiusMeters) / 111000.0

	rows, err := s.db.Query(`
		SELECT 
			id, 
			stop_code, 
			stop_name, 
			stop_lat, 
			stop_lon,
			(6371000 * acos(
				cos(radians(?)) * cos(radians(stop_lat)) * 
				cos(radians(stop_lon) - radians(?)) + 
				sin(radians(?)) * sin(radians(stop_lat))
			)) as distance
		FROM gtfs_stops
		WHERE 
			stop_lat BETWEEN ? - ? AND ? + ?
			AND stop_lon BETWEEN ? - ? AND ? + ?
		HAVING distance <= ?
		ORDER BY distance
		LIMIT ?
	`,
		lat, lon, lat,
		lat, radiusDeg, lat, radiusDeg,
		lon, radiusDeg, lon, radiusDeg,
		radiusMeters, limit,
	)

	if err != nil {
		return nil, fmt.Errorf("query nearby stops: %w", err)
	}
	defer rows.Close()

	stops := make([]Stop, 0, limit)
	for rows.Next() {
		var stop Stop
		if err := rows.Scan(&stop.ID, &stop.Code, &stop.Name, &stop.Lat, &stop.Lon, &stop.Distance); err != nil {
			continue
		}
		stops = append(stops, stop)
	}

	return stops, nil
}

// CalculateWalkingDistanceToStops calcula distancia peatonal REAL a múltiples paradas
// CENTRALIZA: Cálculo de distancias peatonales reales (no euclidiana)
func (s *Service) CalculateWalkingDistanceToStops(fromLat, fromLon float64, stops []Stop) ([]Stop, error) {
	enriched := make([]Stop, 0, len(stops))

	for _, stop := range stops {
		// Calcular distancia peatonal real usando GraphHopper
		route, err := s.ghClient.GetFootRoute(fromLat, fromLon, stop.Lat, stop.Lon)

		if err == nil && len(route.Paths) > 0 {
			stop.Distance = route.Paths[0].Distance
		} else {
			// Fallback: distancia euclidiana
			stop.Distance = haversineDistance(fromLat, fromLon, stop.Lat, stop.Lon)
		}

		enriched = append(enriched, stop)
	}

	return enriched, nil
}

// ============================================================================
// UTILIDADES GEOMÉTRICAS
// ============================================================================

// haversineDistance calcula distancia euclidiana entre dos puntos
func haversineDistance(lat1, lon1, lat2, lon2 float64) float64 {
	const earthRadius = 6371000 // metros

	dLat := toRadians(lat2 - lat1)
	dLon := toRadians(lon2 - lon1)

	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(toRadians(lat1))*math.Cos(toRadians(lat2))*
			math.Sin(dLon/2)*math.Sin(dLon/2)

	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))

	return earthRadius * c
}

func toRadians(degrees float64) float64 {
	return degrees * math.Pi / 180
}

// convertGraphHopperStops convierte paradas de GraphHopper a formato interno
func convertGraphHopperStops(ghStops []graphhopper.Stop) []Stop {
	stops := make([]Stop, len(ghStops))
	for i, ghStop := range ghStops {
		stops[i] = Stop{
			Code: ghStop.StopID,
			Name: ghStop.StopName,
			Lat:  ghStop.Lat,
			Lon:  ghStop.Lon,
		}
	}
	return stops
}
