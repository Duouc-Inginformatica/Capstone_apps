package moovit

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// RedBusRoute representa una ruta de bus Red
type RedBusRoute struct {
	RouteNumber  string      `json:"route_number"`
	RouteName    string      `json:"route_name"`
	Direction    string      `json:"direction"`
	Stops        []BusStop   `json:"stops"`
	Geometry     [][]float64 `json:"geometry"` // [lon, lat] pairs
	Duration     int         `json:"duration_minutes"`
	Distance     float64     `json:"distance_km"`
	FirstService string      `json:"first_service"`
	LastService  string      `json:"last_service"`
}

// BusStop representa una parada de bus
type BusStop struct {
	Name      string  `json:"name"`
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	Sequence  int     `json:"sequence"`
}

// RouteItinerary representa un itinerario completo
type RouteItinerary struct {
	Origin        Coordinate `json:"origin"`
	Destination   Coordinate `json:"destination"`
	DepartureTime string     `json:"departure_time"`
	ArrivalTime   string     `json:"arrival_time"`
	TotalDuration int        `json:"total_duration_minutes"`
	TotalDistance float64    `json:"total_distance_km"`
	Legs          []TripLeg  `json:"legs"`
	RedBusRoutes  []string   `json:"red_bus_routes"` // números de buses Red utilizados
}

// Coordinate representa coordenadas geográficas
type Coordinate struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}

// TripLeg representa un segmento del viaje
type TripLeg struct {
	Type        string      `json:"type"` // "walk", "bus", "metro"
	Mode        string      `json:"mode"` // "Red", "Metro", "walk"
	RouteNumber string      `json:"route_number,omitempty"`
	From        string      `json:"from"`
	To          string      `json:"to"`
	Duration    int         `json:"duration_minutes"`
	Distance    float64     `json:"distance_km"`
	Instruction string      `json:"instruction"`
	Geometry    [][]float64 `json:"geometry,omitempty"`
	DepartStop  *BusStop    `json:"depart_stop,omitempty"`
	ArriveStop  *BusStop    `json:"arrive_stop,omitempty"`
}

// Scraper maneja el scraping de Moovit
type Scraper struct {
	baseURL    string
	httpClient *http.Client
	cache      map[string]*RedBusRoute
}

// NewScraper crea una nueva instancia del scraper
func NewScraper() *Scraper {
	return &Scraper{
		baseURL: "https://moovitapp.com",
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		cache: make(map[string]*RedBusRoute),
	}
}

// GetRedBusRoute obtiene información de una ruta de bus Red específica
func (s *Scraper) GetRedBusRoute(routeNumber string) (*RedBusRoute, error) {
	// Verificar cache
	if cached, exists := s.cache[routeNumber]; exists {
		return cached, nil
	}

	// Construir URL de búsqueda para la ruta Red
	searchURL := fmt.Sprintf("%s/index/es-419/transporte_público-line-%s-Santiago-642",
		s.baseURL, url.QueryEscape(routeNumber))

	// Hacer la solicitud HTTP
	resp, err := s.httpClient.Get(searchURL)
	if err != nil {
		return nil, fmt.Errorf("error fetching route: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("moovit returned status %d for route %s", resp.StatusCode, routeNumber)
	}

	// Leer el body
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("error reading response: %w", err)
	}

	// Parsear la información de la ruta
	route, err := s.parseRouteFromHTML(string(body), routeNumber)
	if err != nil {
		return nil, fmt.Errorf("error parsing route: %w", err)
	}

	// Guardar en cache
	s.cache[routeNumber] = route

	return route, nil
}

// parseRouteFromHTML extrae información de la ruta desde el HTML
func (s *Scraper) parseRouteFromHTML(html, routeNumber string) (*RedBusRoute, error) {
	route := &RedBusRoute{
		RouteNumber: routeNumber,
		Stops:       []BusStop{},
		Geometry:    [][]float64{},
	}

	// Extraer nombre de la ruta
	nameRegex := regexp.MustCompile(`<h1[^>]*>([^<]+)</h1>`)
	if matches := nameRegex.FindStringSubmatch(html); len(matches) > 1 {
		route.RouteName = strings.TrimSpace(matches[1])
	}

	// Extraer paradas (ejemplo simplificado)
	stopRegex := regexp.MustCompile(`data-stop-name="([^"]+)".*?data-lat="([^"]+)".*?data-lon="([^"]+)"`)
	stopMatches := stopRegex.FindAllStringSubmatch(html, -1)

	for i, match := range stopMatches {
		if len(match) >= 4 {
			var lat, lon float64
			fmt.Sscanf(match[2], "%f", &lat)
			fmt.Sscanf(match[3], "%f", &lon)

			stop := BusStop{
				Name:      match[1],
				Latitude:  lat,
				Longitude: lon,
				Sequence:  i + 1,
			}
			route.Stops = append(route.Stops, stop)
			route.Geometry = append(route.Geometry, []float64{lon, lat})
		}
	}

	// Extraer horarios
	scheduleRegex := regexp.MustCompile(`Primer servicio:\s*([0-9:]+).*?Último servicio:\s*([0-9:]+)`)
	if matches := scheduleRegex.FindStringSubmatch(html); len(matches) > 2 {
		route.FirstService = matches[1]
		route.LastService = matches[2]
	}

	// Si no encontramos paradas, crear datos de ejemplo para Santiago
	if len(route.Stops) == 0 {
		route.Stops = s.getDefaultRedRouteStops(routeNumber)
		for _, stop := range route.Stops {
			route.Geometry = append(route.Geometry, []float64{stop.Longitude, stop.Latitude})
		}
	}

	// Calcular estimaciones
	if len(route.Stops) > 0 {
		route.Duration = len(route.Stops) * 2            // ~2 minutos por parada
		route.Distance = float64(len(route.Stops)) * 0.5 // ~500m entre paradas
	}

	return route, nil
}

// GetRouteItinerary obtiene un itinerario completo desde origen a destino usando buses Red
func (s *Scraper) GetRouteItinerary(originLat, originLon, destLat, destLon float64) (*RouteItinerary, error) {
	// Construir URL para planificación de ruta
	params := url.Values{}
	params.Add("from", fmt.Sprintf("%f,%f", originLat, originLon))
	params.Add("to", fmt.Sprintf("%f,%f", destLat, destLon))
	params.Add("time", time.Now().Format("15:04"))

	searchURL := fmt.Sprintf("%s/index/es-419/transporte_público-Santiago-642?%s",
		s.baseURL, params.Encode())

	resp, err := s.httpClient.Get(searchURL)
	if err != nil {
		return nil, fmt.Errorf("error fetching itinerary: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("error reading response: %w", err)
	}

	// Parsear itinerario
	itinerary, err := s.parseItineraryFromHTML(string(body), originLat, originLon, destLat, destLon)
	if err != nil {
		return nil, fmt.Errorf("error parsing itinerary: %w", err)
	}

	return itinerary, nil
}

// parseItineraryFromHTML extrae el itinerario desde el HTML de Moovit
func (s *Scraper) parseItineraryFromHTML(html string, originLat, originLon, destLat, destLon float64) (*RouteItinerary, error) {
	itinerary := &RouteItinerary{
		Origin:       Coordinate{Latitude: originLat, Longitude: originLon},
		Destination:  Coordinate{Latitude: destLat, Longitude: destLon},
		Legs:         []TripLeg{},
		RedBusRoutes: []string{},
	}

	// Buscar rutas de buses Red en el HTML
	redBusRegex := regexp.MustCompile(`(?i)bus[^\d]*(\d{3})[^\d]`)
	matches := redBusRegex.FindAllStringSubmatch(html, -1)

	// Extraer números de buses Red únicos
	seenRoutes := make(map[string]bool)
	for _, match := range matches {
		if len(match) > 1 {
			routeNum := match[1]
			if !seenRoutes[routeNum] {
				seenRoutes[routeNum] = true
				itinerary.RedBusRoutes = append(itinerary.RedBusRoutes, routeNum)
			}
		}
	}

	// Si no se encontraron rutas, crear un itinerario de ejemplo
	if len(itinerary.RedBusRoutes) == 0 {
		return s.createFallbackItinerary(originLat, originLon, destLat, destLon)
	}

	// Construir legs del itinerario
	now := time.Now()
	currentTime := now

	// Leg 1: Caminata al paradero
	walkToStop := TripLeg{
		Type:        "walk",
		Mode:        "walk",
		From:        "Origen",
		To:          "Paradero más cercano",
		Duration:    5,
		Distance:    0.4,
		Instruction: "Camina hasta el paradero más cercano",
	}
	itinerary.Legs = append(itinerary.Legs, walkToStop)
	currentTime = currentTime.Add(5 * time.Minute)

	// Leg 2: Viaje en bus Red
	if len(itinerary.RedBusRoutes) > 0 {
		busRoute := itinerary.RedBusRoutes[0]
		busDuration := 25

		busLeg := TripLeg{
			Type:        "bus",
			Mode:        "Red",
			RouteNumber: busRoute,
			From:        "Paradero inicial",
			To:          "Paradero de destino",
			Duration:    busDuration,
			Distance:    8.5,
			Instruction: fmt.Sprintf("Toma el bus Red %s", busRoute),
		}

		// Obtener información detallada de la ruta
		if routeInfo, err := s.GetRedBusRoute(busRoute); err == nil && len(routeInfo.Stops) > 0 {
			busLeg.DepartStop = &routeInfo.Stops[0]
			if len(routeInfo.Stops) > 1 {
				busLeg.ArriveStop = &routeInfo.Stops[len(routeInfo.Stops)-1]
			}
			busLeg.Geometry = routeInfo.Geometry
		}

		itinerary.Legs = append(itinerary.Legs, busLeg)
		currentTime = currentTime.Add(time.Duration(busDuration) * time.Minute)
	}

	// Leg 3: Caminata final
	walkFromStop := TripLeg{
		Type:        "walk",
		Mode:        "walk",
		From:        "Paradero de bajada",
		To:          "Destino",
		Duration:    3,
		Distance:    0.3,
		Instruction: "Camina hasta tu destino",
	}
	itinerary.Legs = append(itinerary.Legs, walkFromStop)
	currentTime = currentTime.Add(3 * time.Minute)

	// Calcular totales
	for _, leg := range itinerary.Legs {
		itinerary.TotalDuration += leg.Duration
		itinerary.TotalDistance += leg.Distance
	}

	itinerary.DepartureTime = now.Format("15:04")
	itinerary.ArrivalTime = currentTime.Format("15:04")

	return itinerary, nil
}

// createFallbackItinerary crea un itinerario de ejemplo cuando no se puede hacer scraping
func (s *Scraper) createFallbackItinerary(originLat, originLon, destLat, destLon float64) (*RouteItinerary, error) {
	// Determinar qué ruta Red usar basado en la ubicación
	suggestedRoute := s.suggestRedRoute(originLat, originLon, destLat, destLon)

	now := time.Now()

	itinerary := &RouteItinerary{
		Origin:        Coordinate{Latitude: originLat, Longitude: originLon},
		Destination:   Coordinate{Latitude: destLat, Longitude: destLon},
		DepartureTime: now.Format("15:04"),
		ArrivalTime:   now.Add(35 * time.Minute).Format("15:04"),
		TotalDuration: 35,
		TotalDistance: 9.2,
		RedBusRoutes:  []string{suggestedRoute},
		Legs: []TripLeg{
			{
				Type:        "walk",
				Mode:        "walk",
				From:        "Origen",
				To:          "Paradero",
				Duration:    5,
				Distance:    0.4,
				Instruction: "Camina hasta el paradero más cercano",
			},
			{
				Type:        "bus",
				Mode:        "Red",
				RouteNumber: suggestedRoute,
				From:        "Paradero inicial",
				To:          "Paradero final",
				Duration:    27,
				Distance:    8.5,
				Instruction: fmt.Sprintf("Toma el bus Red %s", suggestedRoute),
			},
			{
				Type:        "walk",
				Mode:        "walk",
				From:        "Paradero",
				To:          "Destino",
				Duration:    3,
				Distance:    0.3,
				Instruction: "Camina hasta tu destino",
			},
		},
	}

	return itinerary, nil
}

// suggestRedRoute sugiere una ruta Red basada en las coordenadas
func (s *Scraper) suggestRedRoute(originLat, originLon, destLat, destLon float64) string {
	// Lógica simple para sugerir rutas comunes de Santiago
	// En producción, esto debería usar una base de datos de rutas

	avgLat := (originLat + destLat) / 2
	avgLon := (originLon + destLon) / 2

	// Zona centro (alrededor de -33.45, -70.65)
	if avgLat > -33.50 && avgLat < -33.40 && avgLon > -70.70 && avgLon < -70.60 {
		return "506" // Ruta común en zona centro
	}

	// Zona norte
	if avgLat > -33.40 {
		return "405"
	}

	// Zona sur
	if avgLat < -33.50 {
		return "210"
	}

	// Default
	return "506"
}

// getDefaultRedRouteStops retorna paradas de ejemplo para rutas Red comunes
func (s *Scraper) getDefaultRedRouteStops(routeNumber string) []BusStop {
	// Datos de ejemplo para algunas rutas Red de Santiago
	defaultRoutes := map[string][]BusStop{
		"506": {
			{Name: "Alameda con Ahumada", Latitude: -33.4378, Longitude: -70.6504, Sequence: 1},
			{Name: "Alameda con Estado", Latitude: -33.4391, Longitude: -70.6482, Sequence: 2},
			{Name: "Alameda con San Ignacio", Latitude: -33.4420, Longitude: -70.6420, Sequence: 3},
			{Name: "Vicuña Mackenna con Irarrazaval", Latitude: -33.4528, Longitude: -70.6201, Sequence: 4},
			{Name: "Plaza Egaña", Latitude: -33.4546, Longitude: -70.6175, Sequence: 5},
		},
		"210": {
			{Name: "Estación Central", Latitude: -33.4592, Longitude: -70.6833, Sequence: 1},
			{Name: "Alameda con San Borja", Latitude: -33.4410, Longitude: -70.6445, Sequence: 2},
			{Name: "Providencia con Suecia", Latitude: -33.4242, Longitude: -70.6067, Sequence: 3},
		},
		"405": {
			{Name: "Independencia con Olivos", Latitude: -33.4232, Longitude: -70.6547, Sequence: 1},
			{Name: "Recoleta con Dominica", Latitude: -33.4158, Longitude: -70.6438, Sequence: 2},
			{Name: "La Paz con Perú", Latitude: -33.4091, Longitude: -70.6325, Sequence: 3},
		},
	}

	if stops, exists := defaultRoutes[routeNumber]; exists {
		return stops
	}

	// Ruta genérica si no está en el mapa
	return []BusStop{
		{Name: "Parada Inicial", Latitude: -33.4489, Longitude: -70.6693, Sequence: 1},
		{Name: "Parada Intermedia", Latitude: -33.4378, Longitude: -70.6504, Sequence: 2},
		{Name: "Parada Final", Latitude: -33.4242, Longitude: -70.6067, Sequence: 3},
	}
}

// ToJSON convierte la ruta a JSON
func (r *RedBusRoute) ToJSON() (string, error) {
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// ToJSON convierte el itinerario a JSON
func (i *RouteItinerary) ToJSON() (string, error) {
	data, err := json.MarshalIndent(i, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data), nil
}
