package moovit

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
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
	Code      string  `json:"code,omitempty"` // Código del paradero (ej: "PC293")
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

// RouteOptions representa múltiples opciones de rutas sugeridas por Moovit
type RouteOptions struct {
	Origin      Coordinate        `json:"origin"`
	Destination Coordinate        `json:"destination"`
	Options     []RouteItinerary  `json:"options"` // Múltiples opciones para que el usuario elija
}

// LightweightOption representa una opción básica sin geometría (para selección por voz)
type LightweightOption struct {
	Index         int      `json:"index"`          // 0, 1, 2 para "opción uno, dos, tres"
	RouteNumbers  []string `json:"route_numbers"`  // ["426"] o ["506", "210"]
	TotalDuration int      `json:"total_duration_minutes"`
	Summary       string   `json:"summary"`        // "Bus 426, 38 minutos"
	WalkingTime   int      `json:"walking_time_minutes,omitempty"`
	Transfers     int      `json:"transfers"`      // número de transbordos
}

// LightweightRouteOptions representa opciones ligeras para selección por voz
type LightweightRouteOptions struct {
	Origin      Coordinate          `json:"origin"`
	Destination Coordinate          `json:"destination"`
	Options     []LightweightOption `json:"options"`
	HTMLCache   string              `json:"-"` // HTML guardado para fase 2 (no se envía al cliente)
}

// DetailedItineraryRequest representa la solicitud de detalles después de selección
type DetailedItineraryRequest struct {
	Origin           Coordinate `json:"origin"`
	Destination      Coordinate `json:"destination"`
	SelectedOptionIndex int     `json:"selected_option_index"` // 0, 1, o 2
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
	StopCount   int         `json:"stop_count,omitempty"` // Numero de paradas en el viaje
	Stops       []BusStop   `json:"stops,omitempty"`      // Lista completa de paradas (solo para buses)
}

// Scraper maneja el scraping de Moovit
type Scraper struct {
	baseURL         string
	httpClient      *http.Client
	cache           map[string]*RedBusRoute
	htmlCache       map[string]HTMLCacheEntry // Cache de HTML entre FASE 1 y FASE 2
	db              *sql.DB                   // Conexión a base de datos GTFS
	geometryService GeometryService           // Servicio para geometrías (GraphHopper)
}

// GeometryService interface para obtener geometrías de rutas
type GeometryService interface {
	GetWalkingRoute(fromLat, fromLon, toLat, toLon float64, detailed bool) (RouteGeometry, error)
	GetVehicleRoute(fromLat, fromLon, toLat, toLon float64) (RouteGeometry, error)
}

// RouteGeometry representa una geometría de ruta (compatible con geometry.RouteGeometry)
type RouteGeometry struct {
	TotalDistance float64       `json:"total_distance"` // metros
	TotalDuration int           `json:"total_duration"` // segundos
	MainGeometry  [][]float64   `json:"main_geometry"`  // [lon, lat] pairs
}

// HTMLCacheEntry representa un HTML cacheado con timestamp
type HTMLCacheEntry struct {
	HTML      string
	Timestamp time.Time
	OriginLat float64
	OriginLon float64
	DestLat   float64
	DestLon   float64
}

// NewScraper crea una nueva instancia del scraper
func NewScraper() *Scraper {
	return &Scraper{
		baseURL: "https://moovitapp.com",
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		cache:           make(map[string]*RedBusRoute),
		htmlCache:       make(map[string]HTMLCacheEntry),
		db:              nil, // Se configurará después con SetDB
		geometryService: nil, // Se configurará después con SetGeometryService
	}
}

// SetDB configura la conexión de base de datos para consultas GTFS
func (s *Scraper) SetDB(db *sql.DB) {
	s.db = db
}

// SetGeometryService configura el servicio de geometría (GraphHopper)
func (s *Scraper) SetGeometryService(service GeometryService) {
	s.geometryService = service
}

// GetRedBusRoute obtiene información de una ruta de bus Red específica desde GTFS
func (s *Scraper) GetRedBusRoute(routeNumber string) (*RedBusRoute, error) {
	// Verificar cache
	if cached, exists := s.cache[routeNumber]; exists {
		return cached, nil
	}

	// Si no hay base de datos, retornar error
	if s.db == nil {
		return nil, fmt.Errorf("database connection not configured")
	}

	// Consultar GTFS directamente desde la base de datos
	route, err := s.getRouteFromGTFS(routeNumber)
	if err != nil {
		return nil, err
	}

	// Guardar en cache
	s.cache[routeNumber] = route

	return route, nil
}

// getRouteFromGTFS consulta la base de datos GTFS para obtener información de la ruta
func (s *Scraper) getRouteFromGTFS(routeNumber string) (*RedBusRoute, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// 1. Buscar la ruta en gtfs_routes
	var routeID, routeName string
	err := s.db.QueryRowContext(ctx, `
		SELECT route_id, COALESCE(long_name, short_name, route_id) as route_name
		FROM gtfs_routes
		WHERE short_name = ? OR route_id = ?
		LIMIT 1
	`, routeNumber, routeNumber).Scan(&routeID, &routeName)

	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("route %s not found in GTFS", routeNumber)
	}
	if err != nil {
		return nil, fmt.Errorf("error querying route: %w", err)
	}

	log.Printf("✅ Ruta %s encontrada en GTFS: %s (ID: %s)", routeNumber, routeName, routeID)

	// 2. Obtener un trip representativo para esta ruta
	var tripID string
	err = s.db.QueryRowContext(ctx, `
		SELECT trip_id
		FROM gtfs_trips
		WHERE route_id = ?
		LIMIT 1
	`, routeID).Scan(&tripID)

	if err == sql.ErrNoRows {
		log.Printf("⚠️  No se encontraron trips para ruta %s", routeNumber)
		return &RedBusRoute{
			RouteNumber: routeNumber,
			RouteName:   routeName,
			Direction:   "Dirección principal",
			Stops:       []BusStop{},
		}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("error querying trips: %w", err)
	}

	// 3. Obtener todas las paradas del trip en orden
	rows, err := s.db.QueryContext(ctx, `
		SELECT 
			s.stop_id,
			COALESCE(s.code, '') as code,
			s.name,
			s.latitude,
			s.longitude,
			st.stop_sequence
		FROM gtfs_stop_times st
		JOIN gtfs_stops s ON st.stop_id = s.stop_id
		WHERE st.trip_id = ?
		ORDER BY st.stop_sequence ASC
	`, tripID)

	if err != nil {
		return nil, fmt.Errorf("error querying stops: %w", err)
	}
	defer rows.Close()

	route := &RedBusRoute{
		RouteNumber: routeNumber,
		RouteName:   routeName,
		Direction:   "Dirección principal",
		Stops:       []BusStop{},
		Geometry:    [][]float64{},
	}

	for rows.Next() {
		var stopID, code, name string
		var lat, lon float64
		var sequence int

		if err := rows.Scan(&stopID, &code, &name, &lat, &lon, &sequence); err != nil {
			log.Printf("⚠️  Error escaneando parada: %v", err)
			continue
		}

		stop := BusStop{
			Name:      name,
			Latitude:  lat,
			Longitude: lon,
			Sequence:  sequence,
		}
		route.Stops = append(route.Stops, stop)
		route.Geometry = append(route.Geometry, []float64{lon, lat})
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating stops: %w", err)
	}

	// Calcular estimaciones
	if len(route.Stops) > 0 {
		route.Duration = len(route.Stops) * 2            // ~2 minutos por parada
		route.Distance = float64(len(route.Stops)) * 0.5 // ~500m entre paradas
	}

	log.Printf("✅ Ruta %s cargada desde GTFS: %d paradas", routeNumber, len(route.Stops))

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

	// Si no encontramos paradas, la ruta queda vacía
	// Ya NO usamos datos genéricos - debe fallar y usar GTFS real
	if len(route.Stops) == 0 {
		log.Printf("[WARN] No se encontraron paradas en HTML para ruta %s", routeNumber)
	}

	// Calcular estimaciones
	if len(route.Stops) > 0 {
		route.Duration = len(route.Stops) * 2            // ~2 minutos por parada
		route.Distance = float64(len(route.Stops)) * 0.5 // ~500m entre paradas
	}

	return route, nil
}

// GetRouteItinerary obtiene múltiples opciones de rutas desde origen a destino
// CORREGIDO: Usa la estructura correcta de URLs de Moovit con coordenadas
// RETORNA: Múltiples opciones de rutas para que el usuario elija por voz
func (s *Scraper) GetRouteItinerary(originLat, originLon, destLat, destLon float64) (*RouteOptions, error) {
	log.Printf("============================================")
	log.Printf("NUEVA SOLICITUD DE RUTA")
	log.Printf("============================================")
	log.Printf("ORIGEN recibido del frontend: LAT=%.6f, LON=%.6f", originLat, originLon)
	log.Printf("DESTINO recibido del frontend: LAT=%.6f, LON=%.6f", destLat, destLon)
	
	// Convertir coordenadas a nombres de lugares
	originName, err := s.reverseGeocode(originLat, originLon)
	if err != nil {
		log.Printf("⚠️  Error en geocoding de origen: %v", err)
		originName = "Origen"
	}
	
	destName, err := s.reverseGeocode(destLat, destLon)
	if err != nil {
		log.Printf("⚠️  Error en geocoding de destino: %v", err)
		destName = "Destino"
	}
	
	log.Printf("📍 Origen geocodificado: %s", originName)
	log.Printf("📍 Destino geocodificado: %s", destName)
	
	// Intentar scraping con la URL correcta de Moovit
	routeOptions, err := s.scrapeMovitWithCorrectURL(originName, destName, originLat, originLon, destLat, destLon)
	if err != nil {
		log.Printf("[WARN] Scraping fallo: %v, usando algoritmo heuristico", err)
		return s.generateFallbackOptions(originLat, originLon, destLat, destLon), nil
	}
	
	log.Printf("[INFO] Se generaron %d opciones de rutas", len(routeOptions.Options))
	
	// LOG DETALLADO: Verificar que todas las opciones tienen sus legs completos
	for optIdx, option := range routeOptions.Options {
		log.Printf("📋 [OPCIÓN %d] Legs: %d, Duración: %d min, Distancia: %.2f km", 
			optIdx+1, len(option.Legs), option.TotalDuration, option.TotalDistance)
		for legIdx, leg := range option.Legs {
			geometryPoints := len(leg.Geometry)
			log.Printf("   └─ Leg %d: type=%s, mode=%s, route=%s, geometry=%d pts, from='%s', to='%s'", 
				legIdx+1, leg.Type, leg.Mode, leg.RouteNumber, geometryPoints, leg.From, leg.To)
		}
	}
	
	return routeOptions, nil
}

// reverseGeocode convierte coordenadas a nombre de lugar usando Nominatim
func (s *Scraper) reverseGeocode(lat, lon float64) (string, error) {
	geocodeURL := fmt.Sprintf("https://nominatim.openstreetmap.org/reverse?format=json&lat=%.6f&lon=%.6f&zoom=18&addressdetails=1",
		lat, lon)
	
	req, err := http.NewRequest("GET", geocodeURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "WayFindCL/1.0 (Educational Project)")
	
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("geocoding returned status %d", resp.StatusCode)
	}
	
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	
	var result map[string]interface{}
	if err := json.Unmarshal(body, &result); err != nil {
		return "", err
	}
	
	if displayName, ok := result["display_name"].(string); ok {
		parts := strings.Split(displayName, ",")
		if len(parts) > 0 {
			return strings.TrimSpace(parts[0]), nil
		}
		return strings.TrimSpace(displayName), nil
	}
	
	return "", fmt.Errorf("no display_name in response")
}

// scrapeMovitWithCorrectURL usa Chrome headless para obtener el HTML completo con JavaScript ejecutado
// RETORNA: Múltiples opciones de rutas extraídas de Moovit
func (s *Scraper) scrapeMovitWithCorrectURL(originName, destName string, originLat, originLon, destLat, destLon float64) (*RouteOptions, error) {
	// URL correcta de Moovit
	originEncoded := url.PathEscape(originName)
	destEncoded := url.PathEscape(destName)
	
	moovitURL := fmt.Sprintf("%s/tripplan/santiago-642/poi/%s/%s/es-419?fll=%.6f_%.6f&tll=%.6f_%.6f&customerId=4908&metroSeoName=Santiago",
		s.baseURL,
		destEncoded,
		originEncoded,
		originLat, originLon,
		destLat, destLon,
	)
	
	log.Printf("🔍 [MOOVIT] URL construida: %s", moovitURL)
	log.Printf("🌐 [MOOVIT] Iniciando Chrome headless...")
	
	// Detectar Chrome/Edge en Windows
	chromePaths := []string{
		"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
		"C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
		"C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
		"C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
	}
	
	var chromePath string
	for _, path := range chromePaths {
		if _, err := os.Stat(path); err == nil {
			chromePath = path
			log.Printf("✅ [CHROME] Encontrado en: %s", chromePath)
			break
		}
	}
	
	if chromePath == "" {
		return nil, fmt.Errorf("no se encontró Chrome o Edge instalado. Instala Chrome desde https://www.google.com/chrome/")
	}
	
	// Crear contexto con timeout de 30 segundos
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	
	// Crear contexto de Chrome con opciones
	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.ExecPath(chromePath),
		chromedp.Flag("headless", true),
		chromedp.Flag("disable-gpu", true),
		chromedp.Flag("no-sandbox", true),
		chromedp.Flag("disable-dev-shm-usage", true),
		chromedp.UserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
	)
	
	allocCtx, allocCancel := chromedp.NewExecAllocator(ctx, opts...)
	defer allocCancel()
	
	// Crear contexto del navegador
	browserCtx, browserCancel := chromedp.NewContext(allocCtx, chromedp.WithLogf(log.Printf))
	defer browserCancel()
	
	// Variable para capturar el HTML
	var htmlContent string
	
	// ESTRATEGIA CENTRALIZADA - JavaScript extrae paraderos directamente
	log.Printf("🌐 [MOOVIT] Iniciando extracción CENTRALIZADA con JavaScript...")
	
	var htmlStage1, htmlStage2, htmlStage3 string
	
	err := chromedp.Run(browserCtx,
		// ETAPA 1: Cargar página inicial
		chromedp.Navigate(moovitURL),
		chromedp.WaitVisible(`mv-suggested-route`, chromedp.ByQuery),
		chromedp.Sleep(3*time.Second),
		chromedp.OuterHTML(`html`, &htmlStage1, chromedp.ByQuery),
		chromedp.ActionFunc(func(ctx context.Context) error {
			log.Printf("   � ETAPA 1: HTML inicial capturado (%d chars)", len(htmlStage1))
			return nil
		}),
		
		// ETAPA 2: Extraer URL de la primera ruta y navegar a la página de detalles
		chromedp.ActionFunc(func(ctx context.Context) error {
			log.Printf("   🔍 ETAPA 2: Extrayendo URL del itinerario...")
			var itineraryURL string
			_ = chromedp.Evaluate(`
				(function() {
					// Buscar el primer mv-suggested-route y hacer clic
					const firstRoute = document.querySelector('mv-suggested-route:first-child');
					if (firstRoute) {
						firstRoute.click();
						console.log('[EXTRACTOR] Clicked first route');
					}
					// Esperar un momento para que Angular actualice la URL
					return window.location.href;
				})();
			`, &itineraryURL).Do(ctx)
			log.Printf("      ✅ URL actual: %s", itineraryURL)
			return nil
		}),
		chromedp.Sleep(5*time.Second), // Esperar a que Angular actualice la URL y renderice contenido
		
		// ETAPA 3: Capturar HTML después de la navegación
		chromedp.OuterHTML(`html`, &htmlStage2, chromedp.ByQuery),
		chromedp.ActionFunc(func(ctx context.Context) error {
			log.Printf("   📄 ETAPA 3: HTML de itinerario capturado (%d chars)", len(htmlStage2))
			return nil
		}),
		
		// ETAPA 3.5: Expandir detalles de las paradas haciendo clic en "X paradas"
		chromedp.ActionFunc(func(ctx context.Context) error {
			log.Printf("   🔍 ETAPA 3.5: Expandiendo detalles de paradas...")
			var clicksResult interface{}
			_ = chromedp.Evaluate(`
				(function() {
					console.log('[EXPANDER] Buscando botones de "paradas" para expandir...');
					let clickCount = 0;
					
					// ESTRATEGIA 1: Buscar elementos .details-title que contengan "paradas"
					const detailsTitles = document.querySelectorAll('.details-title');
					console.log('[EXPANDER] Encontrados', detailsTitles.length, '.details-title');
					
					detailsTitles.forEach((el, index) => {
						const text = el.textContent.toLowerCase();
						if (text.includes('parada') || text.includes('stop')) {
							try {
								console.log('[EXPANDER] Click en .details-title:', text.substring(0, 50));
								el.click();
								clickCount++;
							} catch(e) {
								console.log('[EXPANDER] Error:', e);
							}
						}
					});
					
					// ESTRATEGIA 2: Buscar elementos con clase toggle-details
					const toggles = document.querySelectorAll('.toggle-details, [class*="toggle"]');
					console.log('[EXPANDER] Encontrados', toggles.length, 'toggles');
					
					toggles.forEach((el, index) => {
						if (el.offsetParent !== null) {
							try {
								const parent = el.closest('.details-title, .details-wrapper');
								if (parent) {
									console.log('[EXPANDER] Click en toggle');
									parent.click();
									clickCount++;
								}
							} catch(e) {}
						}
					});
					
					// ESTRATEGIA 3: Buscar spans con texto "X paradas" y hacer clic en su padre
					const allSpans = document.querySelectorAll('span');
					allSpans.forEach(span => {
						const text = span.textContent.trim();
						if (/\d+\s*parada/i.test(text)) {
							try {
								const clickable = span.closest('[tabindex], a, button, .details-title');
								if (clickable && clickable.offsetParent !== null) {
									console.log('[EXPANDER] Click en span con paradas:', text);
									clickable.click();
									clickCount++;
								}
							} catch(e) {}
						}
					});
					
					console.log('[EXPANDER] Total clicks realizados:', clickCount);
					return clickCount;
				})();
			`, &clicksResult).Do(ctx)
			log.Printf("      ✅ Clicks para expandir: %v", clicksResult)
			return nil
		}),
		chromedp.Sleep(3*time.Second), // Esperar a que se expandan los detalles
		
		// ETAPA 4: Hacer scroll hacia abajo para cargar toda la lista de paradas (lazy loading)
		chromedp.ActionFunc(func(ctx context.Context) error {
			log.Printf("   � ETAPA 4: Haciendo scroll para cargar todas las paradas...")
			var scrollResult interface{}
			_ = chromedp.Evaluate(`
				(function() {
					console.log('[SCROLLER] Iniciando scroll para cargar contenido lazy...');
					
					// Scroll gradual hacia abajo para forzar carga de contenido lazy
					const scrollHeight = document.documentElement.scrollHeight;
					const scrollStep = 500;
					let scrolled = 0;
					
					// Simular scroll de usuario real
					for (let i = 0; i < scrollHeight; i += scrollStep) {
						window.scrollTo(0, i);
						scrolled = i;
					}
					
					// Scroll final al fondo
					window.scrollTo(0, scrollHeight);
					
					console.log('[SCROLLER] Scroll completado:', scrolled, 'px');
					return scrolled;
				})();
			`, &scrollResult).Do(ctx)
			log.Printf("      ✅ Scroll realizado: %v px", scrollResult)
			return nil
		}),
		chromedp.Sleep(2*time.Second), // Esperar a que cargue contenido lazy
		
		// ETAPA 5: Extraer paraderos con JavaScript detallado
		chromedp.ActionFunc(func(ctx context.Context) error {
			log.Printf("   🔍 ETAPA 5: Extrayendo paraderos con JavaScript...")
			var result interface{}
			_ = chromedp.Evaluate(`
				(function() {
					console.log('[EXTRACTOR] Iniciando extracción detallada...');
					
					// Buscar códigos PC en TODO el HTML
					const stopPattern = /\b(P[CABDEIJLRSUX]\d{3,5})\b/gi;
					const foundStops = new Set();
					
					// 1. Buscar en innerText (más confiable)
					const bodyText = document.body.innerText;
					console.log('[EXTRACTOR] Tamaño de innerText:', bodyText.length);
					console.log('[EXTRACTOR] Muestra de texto:', bodyText.substring(0, 500));
					
					let match;
					stopPattern.lastIndex = 0;
					let matchCount = 0;
					while ((match = stopPattern.exec(bodyText)) !== null) {
						foundStops.add(match[1].toUpperCase());
						matchCount++;
					}
					console.log('[EXTRACTOR] Matches en innerText:', matchCount);
					
					// 2. Buscar en outerHTML
					const htmlSource = document.documentElement.outerHTML;
					console.log('[EXTRACTOR] Tamaño de outerHTML:', htmlSource.length);
					stopPattern.lastIndex = 0;
					let htmlMatchCount = 0;
					while ((match = stopPattern.exec(htmlSource)) !== null) {
						foundStops.add(match[1].toUpperCase());
						htmlMatchCount++;
					}
					console.log('[EXTRACTOR] Matches en outerHTML:', htmlMatchCount);
					
					// 3. Buscar específicamente en elementos mv-suggested-route
					const routeElements = document.querySelectorAll('mv-suggested-route');
					console.log('[EXTRACTOR] Elementos mv-suggested-route encontrados:', routeElements.length);
					routeElements.forEach((el, idx) => {
						const elText = el.innerText;
						console.log('[EXTRACTOR] Ruta', idx, 'texto:', elText.substring(0, 200));
						stopPattern.lastIndex = 0;
						while ((match = stopPattern.exec(elText)) !== null) {
							foundStops.add(match[1].toUpperCase());
						}
					});
					
					const stops = Array.from(foundStops).sort();
					console.log('[EXTRACTOR] TOTAL paraderos únicos:', stops.length);
					console.log('[EXTRACTOR] Lista:', stops);
					
					// Inyectar en HTML
					if (stops.length > 0) {
						const injectedDiv = document.createElement('div');
						injectedDiv.id = 'moovit-extracted-stops';
						injectedDiv.textContent = 'EXTRACTED_STOPS: ' + stops.join(', ');
						document.body.appendChild(injectedDiv);
						console.log('[EXTRACTOR] Inyectado en HTML');
					}
					
					return {
						clicks: 0,
						stops: stops
					};
				})();
			`, &result).Do(ctx)
			
			if result != nil {
				if resultMap, ok := result.(map[string]interface{}); ok {
					clicks := resultMap["clicks"]
					stops := resultMap["stops"]
					log.Printf("      ✅ Clicks: %v, Paraderos extraídos: %v", clicks, stops)
				} else {
					log.Printf("      ℹ️  Resultado: %v", result)
				}
			}
			return nil
		}),
		chromedp.Sleep(2*time.Second),
		chromedp.OuterHTML(`html`, &htmlStage3, chromedp.ByQuery),
		chromedp.ActionFunc(func(ctx context.Context) error {
			log.Printf("   📄 ETAPA 6: HTML final capturado (%d chars)", len(htmlStage3))
			return nil
		}),
	)
	
	// Usar el HTML que tenga más contenido (probablemente tiene más paraderos)
	if len(htmlStage3) > len(htmlStage2) {
		htmlContent = htmlStage3
		log.Printf("   ✅ Usando HTML de ETAPA 3 (más completo)")
	} else if len(htmlStage2) > len(htmlStage1) {
		htmlContent = htmlStage2
		log.Printf("   ✅ Usando HTML de ETAPA 2")
	} else {
		htmlContent = htmlStage1
		log.Printf("   ✅ Usando HTML de ETAPA 1 (inicial)")
	}
	
	if err != nil {
		log.Printf("❌ [MOOVIT] Error en Chrome: %v", err)
		return nil, fmt.Errorf("error ejecutando Chrome headless: %v", err)
	}
	
	log.Printf("📄 [MOOVIT] HTML con JavaScript ejecutado: %d caracteres", len(htmlContent))
	
	// Guardar HTML para debugging
	if err := os.WriteFile("moovit_chromedp_debug.html", []byte(htmlContent), 0644); err != nil {
		log.Printf("⚠️  No se pudo guardar HTML debug: %v", err)
	} else {
		log.Printf("💾 HTML de Chrome guardado en moovit_chromedp_debug.html")
	}
	
	// Parsear HTML para extraer rutas
	return s.parseMovitHTML(htmlContent, originLat, originLon, destLat, destLon)
}

// scrapeMovitRoute hace scraping real de Moovit.com para obtener rutas
func (s *Scraper) scrapeMovitRoute(originName, destName string, originLat, originLon, destLat, destLon float64) (*RouteItinerary, error) {
	// NOTA: Moovit tiene protección anti-scraping y las URLs dinámicas son complejas
	// Para proyecto educacional, vamos a usar una API alternativa (GraphHopper) o datos locales
	
	log.Printf("[WARN] [MOOVIT] Scraping directo de Moovit no es viable (anti-bot, URLs dinamicas)")
	log.Printf("📍 [MOOVIT] Origen solicitado: %s (%.4f, %.4f)", originName, originLat, originLon)
	log.Printf("� [MOOVIT] Destino solicitado: %s (%.4f, %.4f)", destName, destLat, destLon)
	log.Printf("🔄 [MOOVIT] Usando algoritmo heurístico basado en datos reales de Santiago")
	
	// Moovit no permite scraping directo de manera confiable
	// Retornar error para que use el fallback heurístico
	return nil, fmt.Errorf("moovit scraping no disponible - usando datos locales")
}

// parseMovitHTML parsea el HTML de Moovit para extraer información de rutas
func (s *Scraper) parseMovitHTML(html string, originLat, originLon, destLat, destLon float64) (*RouteOptions, error) {
	log.Printf("🔍 Iniciando parseado de HTML de Moovit...")
	
	// Guardar HTML completo para búsquedas posteriores
	fullHTML := html
	
	// PRIORIDAD 1: Buscar div inyectado con paraderos extraídos desde página de itinerario
	extractedStopsRegex := regexp.MustCompile(`<div id="moovit-extracted-stops"[^>]*>EXTRACTED_STOPS:\s*([^<]+)</div>`)
	extractedStopsMatch := extractedStopsRegex.FindStringSubmatch(html)
	
	if len(extractedStopsMatch) > 1 {
		log.Printf("✅ [ITINERARIO] Encontrado div con paraderos extraídos por JavaScript")
		stopsText := strings.TrimSpace(extractedStopsMatch[1])
		stopCodes := strings.Split(stopsText, ",")
		
		// Limpiar códigos
		cleanedStops := []string{}
		for _, code := range stopCodes {
			cleaned := strings.TrimSpace(code)
			if len(cleaned) > 0 {
				cleanedStops = append(cleanedStops, cleaned)
			}
		}
		
		if len(cleanedStops) > 0 {
			log.Printf("✅ [ITINERARIO] Paraderos extraídos: %d - %v", len(cleanedStops), cleanedStops)
			
			// Crear opción de ruta usando los paraderos extraídos
			return s.parseItineraryPageWithStops(html, cleanedStops, originLat, originLon, destLat, destLon)
		}
	}
	
	// FALLBACK: Buscar mv-suggested-route (página de resultados)
	log.Printf("[INFO] No se encontraron paraderos extraídos, buscando mv-suggested-route...")
	log.Printf("[INFO] Esto puede ocurrir si Moovit sugiere caminar en lugar de tomar bus (distancia corta)")
	suggestedRouteRegex := regexp.MustCompile(`<mv-suggested-route[^>]*>([\s\S]*?)</mv-suggested-route>`)
	containerMatches := suggestedRouteRegex.FindAllStringSubmatch(html, -1)
	
	if len(containerMatches) == 0 {
		log.Printf("[WARN] No se encontro mv-suggested-route en el HTML renderizado")
		log.Printf("[WARN] Moovit probablemente sugiere caminar o no hay rutas disponibles para esta combinación origen-destino")
		return nil, fmt.Errorf("no se encontraron rutas en la respuesta de Moovit")
	}
	
	log.Printf("[INFO] Encontrados %d opciones de rutas sugeridas por Moovit", len(containerMatches))
	
	routeOptions := &RouteOptions{
		Origin:      Coordinate{Latitude: originLat, Longitude: originLon},
		Destination: Coordinate{Latitude: destLat, Longitude: destLon},
		Options:     []RouteItinerary{},
	}
	
	// Procesar cada opción de ruta
	for idx, match := range containerMatches {
		if len(match) < 2 {
			continue
		}
		
		routeHTML := match[1]
		log.Printf("🔍 Procesando opción %d...", idx+1)
		
		// LOG: Mostrar snippet del HTML para debug
		htmlPreview := routeHTML
		if len(htmlPreview) > 500 {
			htmlPreview = htmlPreview[:500] + "..."
		}
		log.Printf("   📄 HTML snippet: %s", htmlPreview)
		
		// Extraer duración (ej: "38 min")
		durationRegex := regexp.MustCompile(`<span[^>]*class="[^"]*duration[^"]*"[^>]*>(\d+)\s*min</span>`)
		durationMatch := durationRegex.FindStringSubmatch(routeHTML)
		duration := 30 // default
		if len(durationMatch) > 1 {
			fmt.Sscanf(durationMatch[1], "%d", &duration)
			log.Printf("   ⏱️  Duración: %d min", duration)
		}
		
		// Extraer número de ruta (ej: "426")
		routeNumber := s.extractRouteNumber(routeHTML, idx+1)
		if routeNumber == "" {
			log.Printf("   [WARN] No se pudo extraer numero de ruta, saltando...")
			continue
		}
		
		// Extraer número de paradas del HTML
		stopCount := s.extractStopCount(routeHTML)
		
		// Extraer código de paradero (ej: "PC1237")
		stopCode := s.extractStopCode(routeHTML)
		
		log.Printf("   [INFO] Opcion %d: Ruta %s - %d min - %d paradas - Paradero: %s", 
			idx+1, routeNumber, duration, stopCount, stopCode)
		
		// Generar itinerario para esta opción
		// IMPORTANTE: Pasar también la duración de Moovit, número de paradas, código de paradero, HTML fragmento Y HTML COMPLETO
		itinerary := s.generateItineraryWithRouteFromMovit(
			routeNumber, duration, stopCount, stopCode, routeHTML, fullHTML,
			originLat, originLon, destLat, destLon)
		
		// SIEMPRE agregar si tenemos número de ruta, incluso si GTFS falla
		if len(itinerary.Legs) > 0 {
			routeOptions.Options = append(routeOptions.Options, *itinerary)
		}
	}
	
	if len(routeOptions.Options) == 0 {
		return nil, fmt.Errorf("no se pudieron generar opciones de ruta")
	}
	
	log.Printf("[INFO] Total de opciones generadas: %d", len(routeOptions.Options))
	return routeOptions, nil
}

// parseItineraryPageWithStops procesa paraderos extraídos de página de itinerario
func (s *Scraper) parseItineraryPageWithStops(html string, stopCodes []string, originLat, originLon, destLat, destLon float64) (*RouteOptions, error) {
	log.Printf("🔍 [ITINERARIO] Procesando %d paraderos extraídos...", len(stopCodes))
	
	// Buscar número de ruta en el HTML de itinerario
	routeNumber := s.extractRouteNumberFromItinerary(html)
	if routeNumber == "" {
		log.Printf("[WARN] No se pudo extraer número de ruta del HTML de itinerario")
		routeNumber = "Red" // Fallback genérico
	}
	
	// Buscar duración en el HTML
	durationRegex := regexp.MustCompile(`(\d+)\s*min`)
	durationMatch := durationRegex.FindStringSubmatch(html)
	duration := 30 // default
	if len(durationMatch) > 1 {
		fmt.Sscanf(durationMatch[1], "%d", &duration)
	}
	log.Printf("   ⏱️  Duración estimada: %d min", duration)
	
	// Geocodificar paraderos usando GTFS
	geocodedStops := []BusStop{}
	seenCodes := make(map[string]bool)
	
	for i, code := range stopCodes {
		code = strings.TrimSpace(code)
		if code == "" || seenCodes[code] {
			continue
		}
		seenCodes[code] = true
		
		stop, err := s.getStopByCode(code)
		if err == nil && stop != nil {
			// Asignar secuencia basada en orden en el array
			stop.Sequence = i + 1
			geocodedStops = append(geocodedStops, *stop)
			log.Printf("   ✅ [GTFS] %s: %s (%.6f, %.6f)", code, stop.Name, stop.Latitude, stop.Longitude)
		} else {
			log.Printf("   ⚠️  [GTFS] No encontrado: %s", code)
		}
	}
	
	log.Printf("✅ [MOOVIT-HTML] Total paraderos geocodificados: %d de %d", len(geocodedStops), len(stopCodes))
	
	if len(geocodedStops) < 2 {
		return nil, fmt.Errorf("no se pudieron geocodificar suficientes paraderos (%d)", len(geocodedStops))
	}
	
	// Crear RouteOptions con una sola opción de ruta
	routeOptions := &RouteOptions{
		Origin:      Coordinate{Latitude: originLat, Longitude: originLon},
		Destination: Coordinate{Latitude: destLat, Longitude: destLon},
		Options:     []RouteItinerary{},
	}
	
	// Construir itinerario con los paraderos geocodificados
	itinerary := s.buildItineraryFromStops(routeNumber, duration, geocodedStops, originLat, originLon, destLat, destLon)
	routeOptions.Options = append(routeOptions.Options, *itinerary)
	
	log.Printf("✅ [ITINERARIO] Ruta generada: %s con %d piernas y %d puntos de geometría", 
		routeNumber, len(itinerary.Legs), s.countGeometryPoints(itinerary))
	
	// 🔍 DEBUG: Mostrar paraderos de la ruta
	log.Printf("🔍 [DEBUG-PARADEROS] Total paraderos en ruta: %d", len(geocodedStops))
	for i, stop := range geocodedStops {
		log.Printf("   [%d] %s [%s] - Seq:%d - (%.6f, %.6f)", 
			i+1, stop.Name, stop.Code, stop.Sequence, stop.Latitude, stop.Longitude)
	}
	
	// 🔍 DEBUG: Mostrar origen y destino del itinerario
	log.Printf("🔍 [DEBUG-ITINERARIO] Origen request: (%.6f, %.6f)", originLat, originLon)
	log.Printf("🔍 [DEBUG-ITINERARIO] Destino request: (%.6f, %.6f)", destLat, destLon)
	
	// 🔍 DEBUG: Mostrar geometría de cada pierna
	for i, leg := range itinerary.Legs {
		log.Printf("🔍 [DEBUG-LEG-%d] Tipo:%s Mode:%s Puntos:%d From:%s To:%s", 
			i+1, leg.Type, leg.Mode, len(leg.Geometry), leg.From, leg.To)
		if len(leg.Geometry) > 0 {
			log.Printf("   Primer punto: [%.6f, %.6f]", leg.Geometry[0][1], leg.Geometry[0][0])
			log.Printf("   Último punto: [%.6f, %.6f]", 
				leg.Geometry[len(leg.Geometry)-1][1], leg.Geometry[len(leg.Geometry)-1][0])
		} else {
			log.Printf("   ⚠️  SIN GEOMETRÍA")
		}
	}
	
	return routeOptions, nil
}

// extractRouteNumberFromItinerary extrae número de ruta de página de itinerario
func (s *Scraper) extractRouteNumberFromItinerary(html string) string {
	patterns := []struct {
		name  string
		regex *regexp.Regexp
	}{
		{"line-name class", regexp.MustCompile(`class="[^"]*line-name[^"]*"[^>]*>([A-Z]?\d{2,3})</`)},
		{"route-number class", regexp.MustCompile(`class="[^"]*route-number[^"]*"[^>]*>([A-Z]?\d{2,3})</`)},
		{"data-line attribute", regexp.MustCompile(`data-line=["']([A-Z]?\d{2,3})["']`)},
		{"badge/text class", regexp.MustCompile(`class="[^"]*(?:badge|text)[^"]*"[^>]*>([A-Z]?\d{2,3})</`)},
		{"span con número", regexp.MustCompile(`<span[^>]*>([A-Z]?\d{2,3})</span>`)},
	}
	
	for _, pattern := range patterns {
		matches := pattern.regex.FindStringSubmatch(html)
		if len(matches) > 1 {
			routeNum := strings.TrimSpace(matches[1])
			if len(routeNum) >= 2 && len(routeNum) <= 4 {
				log.Printf("   ✅ [RUTA] Encontrado '%s' con patrón '%s'", routeNum, pattern.name)
				return routeNum
			}
		}
	}
	
	log.Printf("   ⚠️  [RUTA] No se encontró número de ruta en HTML de itinerario")
	return ""
}

// buildItineraryFromStops construye itinerario completo desde lista de paraderos
func (s *Scraper) buildItineraryFromStops(routeNumber string, duration int, stops []BusStop, originLat, originLon, destLat, destLon float64) *RouteItinerary {
	log.Printf("🚌 [GEOMETRY] Construyendo geometría con %d paraderos reales...", len(stops))
	
	// Mostrar resumen de paradas antes de construir
	log.Printf("📋 [RESUMEN] Paradas detectadas:")
	for i, stop := range stops {
		log.Printf("   %d. %s [%s] - Seq: %d", i+1, stop.Name, stop.Code, stop.Sequence)
	}
	
	itinerary := &RouteItinerary{
		Origin:        Coordinate{Latitude: originLat, Longitude: originLon},
		Destination:   Coordinate{Latitude: destLat, Longitude: destLon},
		Legs:          []TripLeg{},
		RedBusRoutes:  []string{routeNumber},
		TotalDuration: duration,
	}
	
	// Encontrar paradero más cercano al origen
	originStop := stops[0]
	minDist := s.calculateDistance(originLat, originLon, stops[0].Latitude, stops[0].Longitude)
	for _, stop := range stops {
		dist := s.calculateDistance(originLat, originLon, stop.Latitude, stop.Longitude)
		if dist < minDist {
			minDist = dist
			originStop = stop
		}
	}
	
	// Encontrar paradero más cercano al destino
	destStop := stops[len(stops)-1]
	minDist = s.calculateDistance(destLat, destLon, stops[len(stops)-1].Latitude, stops[len(stops)-1].Longitude)
	for _, stop := range stops {
		dist := s.calculateDistance(destLat, destLon, stop.Latitude, stop.Longitude)
		if dist < minDist {
			minDist = dist
			destStop = stop
		}
	}
	
	log.Printf("   📍 Paradero origen: %s (%.6f, %.6f)", originStop.Name, originStop.Latitude, originStop.Longitude)
	log.Printf("   📍 Paradero destino: %s (%.6f, %.6f)", destStop.Name, destStop.Latitude, destStop.Longitude)
	
	// PIERNA 1: Caminata al paradero de origen (usando GraphHopper)
	var walkLeg TripLeg
	
	if s.geometryService != nil {
		log.Printf("🗺️ [GraphHopper] Calculando ruta a pie: origen → paradero %s", originStop.Name)
		walkRoute, err := s.geometryService.GetWalkingRoute(originLat, originLon, originStop.Latitude, originStop.Longitude, true)
		
		if err == nil {
			log.Printf("✅ [GraphHopper] Ruta a pie: %.0fm, %d segundos, %d puntos de geometría", 
				walkRoute.TotalDistance, walkRoute.TotalDuration, len(walkRoute.MainGeometry))
			
			walkLeg = TripLeg{
				Type:        "walk",
				Mode:        "walk",
				Duration:    walkRoute.TotalDuration / 60, // convertir segundos a minutos
				Distance:    walkRoute.TotalDistance / 1000,
				Instruction: fmt.Sprintf("Camina hacia el paradero %s", originStop.Name),
				Geometry:    walkRoute.MainGeometry,
				DepartStop: &BusStop{
					Name:      "Tu ubicación",
					Latitude:  originLat,
					Longitude: originLon,
				},
				ArriveStop: &originStop,
			}
			
			itinerary.TotalDuration += walkRoute.TotalDuration / 60
			itinerary.TotalDistance += walkRoute.TotalDistance / 1000
		} else {
			log.Printf("⚠️  [GraphHopper] Error calculando ruta a pie: %v (usando fallback)", err)
			// Fallback: línea recta
			walkDistance := s.calculateDistance(originLat, originLon, originStop.Latitude, originStop.Longitude)
			walkDuration := int((walkDistance / 80) / 60) // 80 m/min
			if walkDuration < 1 {
				walkDuration = 1
			}
			
			walkLeg = TripLeg{
				Type:        "walk",
				Mode:        "walk",
				Duration:    walkDuration,
				Distance:    walkDistance / 1000,
				Instruction: fmt.Sprintf("Camina hacia el paradero %s", originStop.Name),
				Geometry: [][]float64{
					{originLon, originLat},
					{originStop.Longitude, originStop.Latitude},
				},
				DepartStop: &BusStop{
					Name:      "Tu ubicación",
					Latitude:  originLat,
					Longitude: originLon,
				},
				ArriveStop: &originStop,
			}
			
			itinerary.TotalDuration += walkDuration
			itinerary.TotalDistance += walkDistance / 1000
		}
	} else {
		log.Printf("⚠️  [GraphHopper] Servicio no disponible, usando línea recta")
		// Fallback: línea recta
		walkDistance := s.calculateDistance(originLat, originLon, originStop.Latitude, originStop.Longitude)
		walkDuration := int((walkDistance / 80) / 60) // 80 m/min
		if walkDuration < 1 {
			walkDuration = 1
		}
		
		walkLeg = TripLeg{
			Type:        "walk",
			Mode:        "walk",
			Duration:    walkDuration,
			Distance:    walkDistance / 1000,
			Instruction: fmt.Sprintf("Camina hacia el paradero %s", originStop.Name),
			Geometry: [][]float64{
				{originLon, originLat},
				{originStop.Longitude, originStop.Latitude},
			},
			DepartStop: &BusStop{
				Name:      "Tu ubicación",
				Latitude:  originLat,
				Longitude: originLon,
			},
			ArriveStop: &originStop,
		}
		
		itinerary.TotalDuration += walkDuration
		itinerary.TotalDistance += walkDistance / 1000
	}
	
	itinerary.Legs = append(itinerary.Legs, walkLeg)
	
	// PIERNA 2: Bus con geometría REAL usando GraphHopper
	// IMPORTANTE: Usar GraphHopper para calcular ruta vehicular realista
	log.Printf("🗺️ [GEOMETRY] Generando geometría de paradas para bus")
	log.Printf("🗺️ [GEOMETRY] Parada origen: %s (seq: %d)", originStop.Name, originStop.Sequence)
	log.Printf("🗺️ [GEOMETRY] Parada destino: %s (seq: %d)", destStop.Name, destStop.Sequence)
	
	// Ordenar paradas por secuencia
	sort.Slice(stops, func(i, j int) bool {
		return stops[i].Sequence < stops[j].Sequence
	})
	
	log.Printf("🗺️ [GEOMETRY] Total de paradas ordenadas: %d", len(stops))
	
	busGeometry := [][]float64{}
	
	// Intentar obtener geometría realista usando GraphHopper (perfil vehicular)
	if s.geometryService != nil {
		log.Printf("🗺️ [GraphHopper] Calculando ruta vehicular: %s → %s", originStop.Name, destStop.Name)
		
		vehicleRoute, err := s.geometryService.GetVehicleRoute(
			originStop.Latitude, originStop.Longitude,
			destStop.Latitude, destStop.Longitude,
		)
		
		if err == nil && len(vehicleRoute.MainGeometry) > 0 {
			log.Printf("✅ [GraphHopper] Ruta vehicular: %.0fm, %d segundos, %d puntos de geometría", 
				vehicleRoute.TotalDistance, vehicleRoute.TotalDuration, len(vehicleRoute.MainGeometry))
			
			busGeometry = vehicleRoute.MainGeometry
			busDistance := vehicleRoute.TotalDistance
			
			// Loggear info de geometría
			log.Printf("✅ [GEOMETRY] Geometría de bus: %d puntos (ruta vehicular GraphHopper)", len(busGeometry))
			
			// Crear leg con geometría realista
			busLeg := TripLeg{
				Type:        "bus",
				Mode:        "Red",
				RouteNumber: routeNumber,
				From:        originStop.Name,
				To:          destStop.Name,
				Duration:    duration,
				Distance:    busDistance / 1000,
				Instruction: fmt.Sprintf("Toma el bus Red %s en %s hacia %s", routeNumber, originStop.Name, destStop.Name),
				Geometry:    busGeometry,
				DepartStop:  &originStop,
				ArriveStop:  &destStop,
				StopCount:   len(stops),
				Stops:       stops,
			}
			
			itinerary.Legs = append(itinerary.Legs, busLeg)
			itinerary.TotalDistance += busDistance / 1000
			
			log.Printf("   🚌 Bus: %.2fkm, %d min, %d paradas, %d puntos de geometría", 
				busDistance/1000, duration, len(stops), len(busGeometry))
		} else {
			// Fallback: usar solo coordenadas de paradas conocidas
			log.Printf("⚠️  [GraphHopper] Error obteniendo ruta vehicular (%v), usando puntos de paradas", err)
			
			// Agregar las coordenadas de TODAS las paradas geocodificadas
			for i, stop := range stops {
				busGeometry = append(busGeometry, []float64{stop.Longitude, stop.Latitude})
				
				// Identificar tipo de parada
				stopType := "INTERMEDIA"
				if stop.Code == originStop.Code {
					stopType = "🟢 INICIO"
				} else if stop.Code == destStop.Code {
					stopType = "🔴 FINAL"
				}
				
				log.Printf("   %s | Parada %d/%d: %s [%s] (seq: %d, %.6f, %.6f)", 
					stopType, i+1, len(stops), stop.Name, stop.Code, stop.Sequence, stop.Latitude, stop.Longitude)
			}
			
			log.Printf("✅ [GEOMETRY] Geometría de bus: %d puntos (coordenadas de paradas)", len(busGeometry))
			
			// Calcular distancia entre paradas
			busDistance := 0.0
			for i := 0; i < len(busGeometry)-1; i++ {
				dist := s.calculateDistance(
					busGeometry[i][1], busGeometry[i][0],
					busGeometry[i+1][1], busGeometry[i+1][0],
				)
				busDistance += dist
			}
			
			busLeg := TripLeg{
				Type:        "bus",
				Mode:        "Red",
				RouteNumber: routeNumber,
				From:        originStop.Name,
				To:          destStop.Name,
				Duration:    duration,
				Distance:    busDistance / 1000,
				Instruction: fmt.Sprintf("Toma el bus Red %s en %s hacia %s", routeNumber, originStop.Name, destStop.Name),
				Geometry:    busGeometry,
				DepartStop:  &originStop,
				ArriveStop:  &destStop,
				StopCount:   len(stops),
				Stops:       stops,
			}
			
			itinerary.Legs = append(itinerary.Legs, busLeg)
			itinerary.TotalDistance += busDistance / 1000
			
			log.Printf("   🚌 Bus: %.2fkm, %d min, %d paradas, %d puntos de geometría", 
				busDistance/1000, duration, len(stops), len(busGeometry))
		}
	} else {
		log.Printf("⚠️  [GraphHopper] Servicio no disponible, usando puntos de paradas")
		
		// Fallback cuando no hay servicio de geometría: usar coordenadas de paradas
		for i, stop := range stops {
			busGeometry = append(busGeometry, []float64{stop.Longitude, stop.Latitude})
			
			stopType := "INTERMEDIA"
			if stop.Code == originStop.Code {
				stopType = "🟢 INICIO"
			} else if stop.Code == destStop.Code {
				stopType = "🔴 FINAL"
			}
			
			log.Printf("   %s | Parada %d/%d: %s [%s] (seq: %d, %.6f, %.6f)", 
				stopType, i+1, len(stops), stop.Name, stop.Code, stop.Sequence, stop.Latitude, stop.Longitude)
		}
		
		log.Printf("✅ [GEOMETRY] Geometría de bus: %d puntos (sin GraphHopper)", len(busGeometry))
		
		busDistance := 0.0
		for i := 0; i < len(busGeometry)-1; i++ {
			dist := s.calculateDistance(
				busGeometry[i][1], busGeometry[i][0],
				busGeometry[i+1][1], busGeometry[i+1][0],
			)
			busDistance += dist
		}
		
		busLeg := TripLeg{
			Type:        "bus",
			Mode:        "Red",
			RouteNumber: routeNumber,
			From:        originStop.Name,
			To:          destStop.Name,
			Duration:    duration,
			Distance:    busDistance / 1000,
			Instruction: fmt.Sprintf("Toma el bus Red %s en %s hacia %s", routeNumber, originStop.Name, destStop.Name),
			Geometry:    busGeometry,
			DepartStop:  &originStop,
			ArriveStop:  &destStop,
			StopCount:   len(stops),
			Stops:       stops,
		}
		
		itinerary.Legs = append(itinerary.Legs, busLeg)
		itinerary.TotalDistance += busDistance / 1000
		
		log.Printf("   🚌 Bus: %.2fkm, %d min, %d paradas, %d puntos de geometría", 
			busDistance/1000, duration, len(stops), len(busGeometry))
	}
	
	// PIERNA 3: Caminata del paradero de destino al destino final (usando GraphHopper)
	finalWalkDistance := s.calculateDistance(destStop.Latitude, destStop.Longitude, destLat, destLon)
	if finalWalkDistance > 1 { // Agregar caminata final siempre que exista desplazamiento real
		
		if s.geometryService != nil {
			log.Printf("🗺️ [GraphHopper] Calculando ruta a pie: paradero %s → destino", destStop.Name)
			finalWalkRoute, err := s.geometryService.GetWalkingRoute(destStop.Latitude, destStop.Longitude, destLat, destLon, true)
			
			if err == nil {
				log.Printf("✅ [GraphHopper] Ruta a pie final: %.0fm, %d segundos, %d puntos de geometría", 
					finalWalkRoute.TotalDistance, finalWalkRoute.TotalDuration, len(finalWalkRoute.MainGeometry))

				geometry := finalWalkRoute.MainGeometry
				if len(geometry) == 0 {
					log.Printf("⚠️  [GraphHopper] Geometría vacía para caminata final, usando línea recta como respaldo")
					geometry = s.generateStraightLineGeometry(destStop.Latitude, destStop.Longitude, destLat, destLon, 3)
				}

				durationMinutes := int(math.Ceil(float64(finalWalkRoute.TotalDuration) / 60.0))
				if durationMinutes < 1 {
					durationMinutes = 1
				}

				distanceKm := finalWalkRoute.TotalDistance / 1000
				
				finalWalkLeg := TripLeg{
					Type:        "walk",
					Mode:        "walk",
					Duration:    durationMinutes,
					Distance:    distanceKm,
					Instruction: fmt.Sprintf("Camina hacia tu destino"),
					Geometry:    geometry,
					DepartStop:  &destStop,
					ArriveStop: &BusStop{
						Name:      "Tu destino",
						Latitude:  destLat,
						Longitude: destLon,
					},
				}
				
				itinerary.Legs = append(itinerary.Legs, finalWalkLeg)
				itinerary.TotalDuration += durationMinutes
				itinerary.TotalDistance += distanceKm
				
				log.Printf("   🚶 Caminata final: %.0fm, %d min", finalWalkRoute.TotalDistance, durationMinutes)
			} else {
				log.Printf("⚠️  [GraphHopper] Error calculando ruta a pie final: %v (usando fallback)", err)
				// Fallback: línea recta
				finalWalkDuration := int(math.Ceil(finalWalkDistance / 80)) // 80 m/min
				if finalWalkDuration < 1 {
					finalWalkDuration = 1
				}
				
				finalWalkLeg := TripLeg{
					Type:        "walk",
					Mode:        "walk",
					Duration:    finalWalkDuration,
					Distance:    finalWalkDistance / 1000,
					Instruction: fmt.Sprintf("Camina hacia tu destino"),
					Geometry: [][]float64{
						{destStop.Longitude, destStop.Latitude},
						{destLon, destLat},
					},
					DepartStop: &destStop,
					ArriveStop: &BusStop{
						Name:      "Tu destino",
						Latitude:  destLat,
						Longitude: destLon,
					},
				}
				
				itinerary.Legs = append(itinerary.Legs, finalWalkLeg)
				itinerary.TotalDuration += finalWalkDuration
				itinerary.TotalDistance += finalWalkDistance / 1000
				
				log.Printf("   🚶 Caminata final: %.0fm, %d min", finalWalkDistance, finalWalkDuration)
			}
		} else {
			log.Printf("⚠️  [GraphHopper] Servicio no disponible, usando línea recta para caminata final")
			// Fallback: línea recta
			finalWalkDuration := int(math.Ceil(finalWalkDistance / 80)) // 80 m/min
			if finalWalkDuration < 1 {
				finalWalkDuration = 1
			}
			
			finalWalkLeg := TripLeg{
				Type:        "walk",
				Mode:        "walk",
				Duration:    finalWalkDuration,
				Distance:    finalWalkDistance / 1000,
				Instruction: fmt.Sprintf("Camina hacia tu destino"),
				Geometry: [][]float64{
					{destStop.Longitude, destStop.Latitude},
					{destLon, destLat},
				},
				DepartStop: &destStop,
				ArriveStop: &BusStop{
					Name:      "Tu destino",
					Latitude:  destLat,
					Longitude: destLon,
				},
			}
			
			itinerary.Legs = append(itinerary.Legs, finalWalkLeg)
			itinerary.TotalDuration += finalWalkDuration
			itinerary.TotalDistance += finalWalkDistance / 1000
			
			log.Printf("   🚶 Caminata final: %.0fm, %d min", finalWalkDistance, finalWalkDuration)
		}
	} else {
		log.Printf("   ℹ️  Sin caminata final (destino muy cercano al paradero: %.0fm)", finalWalkDistance)
	}
	
	// LOG DETALLADO: Mostrar todos los legs que se van a enviar
	log.Printf("📋 [ITINERARIO FINAL] Total de legs: %d", len(itinerary.Legs))
	for i, leg := range itinerary.Legs {
		log.Printf("   Leg %d: type=%s, mode=%s, geometry=%d puntos, from=%s, to=%s", 
			i+1, leg.Type, leg.Mode, len(leg.Geometry), leg.From, leg.To)
	}
	
	return itinerary
}

// countGeometryPoints cuenta el total de puntos de geometría en un itinerario
func (s *Scraper) countGeometryPoints(itinerary *RouteItinerary) int {
	total := 0
	for _, leg := range itinerary.Legs {
		total += len(leg.Geometry)
	}
	return total
}

// extractRouteNumber extrae el número de ruta del HTML de una opción
func (s *Scraper) extractRouteNumber(routeHTML string, optionNum int) string {
	// Patrones ORDENADOS POR PRIORIDAD (más específicos primero)
	patterns := []struct {
		name  string
		regex *regexp.Regexp
	}{
		// PRIORIDAD 1: Texto de color (servicio real de Moovit)
		{"servicio con style color", regexp.MustCompile(`<span[^>]*class="[^"]*text[^"]*"[^>]*style="[^"]*color:[^"]*"[^>]*>([A-Z]?\d{2,3})</span>`)},
		{"span.text con contenido", regexp.MustCompile(`<span[^>]*class="[^"]*text[^"]*"[^>]*>([A-Z]?\d{2,3})</span>`)},
		
		// PRIORIDAD 2: Atributos de datos específicos de transporte
		{"data-line attribute", regexp.MustCompile(`data-line=["']([A-Z]?\d{2,3})["']`)},
		{"data-route attribute", regexp.MustCompile(`data-route=["']([A-Z]?\d{2,3})["']`)},
		{"route-id attribute", regexp.MustCompile(`route-id=["']([A-Z]?\d{2,3})["']`)},
		
		// PRIORIDAD 3: Clases CSS específicas de líneas
		{"line-number class", regexp.MustCompile(`class="[^"]*line-number[^"]*"[^>]*>([A-Z]?\d{2,3})</`)},
		{"badge class", regexp.MustCompile(`class="[^"]*badge[^"]*"[^>]*>([A-Z]?\d{2,3})</`)},
		{"transit class", regexp.MustCompile(`class="[^"]*transit[^"]*"[^>]*>([A-Z]?\d{2,3})</`)},
		
		// PRIORIDAD 4: Texto contextual
		{"texto Red/Bus", regexp.MustCompile(`(?i)(?:red|bus|línea|linea|servicio)\s+([A-Z]?\d{2,3})`)},
		
		// PRIORIDAD 5: Números genéricos (solo si no hay nada más)
		{"span con 3 dígitos", regexp.MustCompile(`<span[^>]*>([A-Z]?\d{3})</span>`)},
		{"span con 2-3 dígitos", regexp.MustCompile(`<span[^>]*>([A-Z]?\d{2,3})</span>`)},
	}
	
	// Usar un mapa con peso para cada ruta encontrada
	type RouteScore struct {
		route    string
		score    int
		priority int
	}
	routesFound := make(map[string]*RouteScore)
	
	for priority, pattern := range patterns {
		matches := pattern.regex.FindAllStringSubmatch(routeHTML, -1)
		for _, match := range matches {
			if len(match) > 1 {
				routeNum := strings.TrimSpace(match[1])
				
				// Filtrar números válidos de buses Red (2-4 caracteres: C28, 430, etc)
				if len(routeNum) >= 2 && len(routeNum) <= 4 {
					if existing, exists := routesFound[routeNum]; exists {
						existing.score++
						// Mantener la mejor prioridad
						if priority < existing.priority {
							existing.priority = priority
						}
					} else {
						routesFound[routeNum] = &RouteScore{
							route:    routeNum,
							score:    1,
							priority: priority,
						}
					}
					
					log.Printf("   🔍 Patrón '%s' (prioridad %d) encontró: %s", pattern.name, priority+1, routeNum)
				}
			}
		}
		
		// Si encontramos algo con alta prioridad (primeros 4 patrones), detenerse
		if priority < 4 && len(routesFound) > 0 {
			log.Printf("   ✅ Encontrado con patrón de alta prioridad, deteniendo búsqueda")
			break
		}
	}
	
	// Seleccionar la mejor ruta basado en prioridad y frecuencia
	var bestRoute string
	var bestScore *RouteScore
	
	for _, score := range routesFound {
		if bestScore == nil {
			bestScore = score
			bestRoute = score.route
		} else {
			// Preferir prioridad más alta (menor número)
			if score.priority < bestScore.priority {
				bestScore = score
				bestRoute = score.route
			} else if score.priority == bestScore.priority && score.score > bestScore.score {
				// Misma prioridad, preferir más frecuente
				bestScore = score
				bestRoute = score.route
			}
		}
	}
	
	if bestRoute != "" {
		log.Printf("   ✅ [SELECCIONADO] Ruta: %s (prioridad: %d, apariciones: %d)", 
			bestRoute, bestScore.priority+1, bestScore.score)
		
		// Mostrar TODAS las rutas encontradas para comparar
		log.Printf("   📊 Resumen de todas las rutas encontradas:")
		for route, score := range routesFound {
			marker := ""
			if route == bestRoute {
				marker = " ← SELECCIONADO"
			}
			log.Printf("      • %s: prioridad %d, apariciones %d%s", 
				route, score.priority+1, score.score, marker)
		}
	} else {
		log.Printf("   ⚠️  [ERROR] No se pudo extraer numero de ruta del HTML")
	}
	
	return bestRoute
}

// extractStopCount extrae el número de paradas del HTML de Moovit
// Formato: "32 paradas" o "32 stops"
func (s *Scraper) extractStopCount(routeHTML string) int {
	log.Printf("   🔍 Buscando conteo de paradas en HTML de tamaño: %d caracteres", len(routeHTML))
	
	// Patrones para buscar número de paradas (más exhaustivos)
	patterns := []*regexp.Regexp{
		regexp.MustCompile(`(?i)(\d+)\s+paradas?`),                // "32 paradas" (case insensitive)
		regexp.MustCompile(`(?i)(\d+)\s+stops?`),                  // "32 stops"
		regexp.MustCompile(`(?i)paradas?[\s:]+(\d+)`),             // "paradas: 32"
		regexp.MustCompile(`(?i)stops?[\s:]+(\d+)`),               // "stops: 32"
		regexp.MustCompile(`data-stops=["'](\d+)["']`),            // data-stops="32"
		regexp.MustCompile(`class="stops"[^>]*>(\d+)</`),          // class="stops">32</
		regexp.MustCompile(`stop-count['":\s]+(\d+)`),             // stop-count: 32
		regexp.MustCompile(`"stops"\s*:\s*(\d+)`),                 // "stops": 32 (JSON)
		regexp.MustCompile(`(\d+)\s+(?:stops?|paradas?)\s+en`),    // "32 stops en total"
	}
	
	for i, pattern := range patterns {
		matches := pattern.FindStringSubmatch(routeHTML)
		if len(matches) > 1 {
			if stopCount, err := strconv.Atoi(matches[1]); err == nil {
				if stopCount > 0 && stopCount < 200 { // Validar rango razonable
					log.Printf("   ✅ Patrón %d encontró: %d paradas", i+1, stopCount)
					return stopCount
				}
			}
		}
	}
	
	// Si no se encuentra, intentar buscar en el HTML completo cualquier referencia a paradas
	stopRegex := regexp.MustCompile(`(?i)(paradas?|stops?)`)
	if stopRegex.MatchString(routeHTML) {
		log.Printf("   ⚠️  Se encontró la palabra 'paradas/stops' pero no se pudo extraer el número")
		// Log de contexto alrededor de la palabra
		matches := stopRegex.FindAllStringIndex(routeHTML, -1)
		if len(matches) > 0 && len(matches[0]) >= 1 {
			idx := matches[0][0]
			start := idx - 50
			if start < 0 {
				start = 0
			}
			end := idx + 100
			if end > len(routeHTML) {
				end = len(routeHTML)
			}
			log.Printf("   📝 Contexto: ...%s...", routeHTML[start:end])
		}
	} else {
		log.Printf("   ⚠️  No se encontró la palabra 'paradas' o 'stops' en el HTML")
	}
	
	return 0 // No se encontró
}

// extractStopCode extrae el código del paradero desde el HTML de Moovit
// Ejemplos: "PC1237", "PJ178", "PA4321"
// Formato común en Moovit: "Pc1237-Raúl Labbé / Esq. Av. La Dehesa"
func (s *Scraper) extractStopCode(routeHTML string) string {
	log.Printf("   🔍 Buscando código de paradero en HTML...")
	
	// Patrones para códigos de paraderos en Santiago
	patterns := []*regexp.Regexp{
		// PRIORIDAD 1: Formato "Pc1237-Nombre del paradero" (más común en Moovit)
		regexp.MustCompile(`(?i)\b([A-Z]{1,2}\d{3,4})-`),
		
		// PRIORIDAD 2: Con contexto de parada/paradero
		regexp.MustCompile(`(?i)(?:paradero|stop|parada)[\s:-]*([A-Z]{1,2}\d{3,4})`),
		
		// PRIORIDAD 3: Standalone (cuidado con falsos positivos)
		regexp.MustCompile(`\b([A-Z]{1,2}\d{3,4})\b`),
		
		// PRIORIDAD 4: Atributos HTML
		regexp.MustCompile(`stop[_-]?code['":\s]+([A-Z]{1,2}\d{3,4})`),
		regexp.MustCompile(`data-stop['":\s]+([A-Z]{1,2}\d{3,4})`),
		regexp.MustCompile(`(?:desde|from|at)[\s:-]*([A-Z]{1,2}\d{3,4})`),
	}
	
	for i, pattern := range patterns {
		matches := pattern.FindStringSubmatch(routeHTML)
		if len(matches) > 1 {
			stopCode := strings.ToUpper(matches[1])
			// Validar que sea un código válido de Santiago (PC, PJ, PA, PB, etc.)
			// Formato: 1-2 letras + 3-4 dígitos
			if len(stopCode) >= 4 && len(stopCode) <= 6 {
				// Verificar que tenga al menos una letra al inicio
				if stopCode[0] >= 'A' && stopCode[0] <= 'Z' {
					log.Printf("   ✅ Patrón %d encontró código de paradero: %s", i+1, stopCode)
					return stopCode
				}
			}
		}
	}
	
	log.Printf("   ⚠️  No se encontró código de paradero en el HTML")
	return ""
}

// isValidSantiagoRoute verifica si una ruta pertenece a las rutas Red de Santiago conocidas
// generateItineraryWithRoute genera un itinerario usando una ruta específica encontrada
func (s *Scraper) generateItineraryWithRoute(routeNumber string, originLat, originLon, destLat, destLon float64) *RouteItinerary {
	log.Printf("🚌 Generando itinerario con ruta %s", routeNumber)
	
	itinerary := &RouteItinerary{
		Origin:       Coordinate{Latitude: originLat, Longitude: originLon},
		Destination:  Coordinate{Latitude: destLat, Longitude: destLon},
		Legs:         []TripLeg{},
		RedBusRoutes: []string{routeNumber},
	}
	
	// Obtener información de la ruta
	routeInfo := s.getRouteInfo(routeNumber)
	
	// FALLBACK: Si no hay paradas GTFS, generar itinerario simple con línea recta
	if len(routeInfo.Stops) == 0 {
		log.Printf("⚠️  No hay paradas GTFS para ruta %s - generando itinerario simplificado", routeNumber)
		
		// Calcular duración estimada basada en distancia
		distance := s.calculateDistance(originLat, originLon, destLat, destLon)
		duration := int((distance / 400) / 60) // 400 m/min velocidad promedio bus
		if duration < 10 {
			duration = 15
		}
		
		now := time.Now()
		
		// Crear geometría simple (línea recta origen → destino)
		simpleGeometry := [][]float64{
			{originLon, originLat},
			{destLon, destLat},
		}
		
		busLeg := TripLeg{
			Type:        "bus",
			Mode:        "Red",
			RouteNumber: routeNumber,
			From:        "Origen",
			To:          "Destino",
			Duration:    duration,
			Distance:    distance / 1000,
			Instruction: fmt.Sprintf("Toma el bus %s hacia tu destino", routeNumber),
			Geometry:    simpleGeometry,
		}
		
		return &RouteItinerary{
			Origin:        Coordinate{Latitude: originLat, Longitude: originLon},
			Destination:   Coordinate{Latitude: destLat, Longitude: destLon},
			Legs:          []TripLeg{busLeg},
			RedBusRoutes:  []string{routeNumber},
			TotalDuration: duration,
			TotalDistance: distance / 1000,
			DepartureTime: now.Format("15:04"),
			ArrivalTime:   now.Add(time.Duration(duration) * time.Minute).Format("15:04"),
		}
	}
	
	now := time.Now()
	currentTime := now
	
	// Encontrar paradas más cercanas
	originStop := s.findNearestStopOnRoute(originLat, originLon, routeInfo.Stops)
	destStop := s.findNearestStopOnRoute(destLat, destLon, routeInfo.Stops)
	
	// SOLO VIAJE EN BUS - Sin caminatas
	busDistance := s.calculateDistance(originStop.Latitude, originStop.Longitude, destStop.Latitude, destStop.Longitude)
	busDuration := int((busDistance / 400) / 60)
	if busDuration < 10 {
		busDuration = 15 // Duración mínima realista
	}
	
	// Crear geometría
	busGeometry := s.generateBusRouteGeometry(originStop, destStop, routeInfo.Stops)
	fullGeometry := [][]float64{{originLon, originLat}}
	fullGeometry = append(fullGeometry, busGeometry...)
	fullGeometry = append(fullGeometry, []float64{destLon, destLat})
	
	busLeg := TripLeg{
		Type:        "bus",
		Mode:        "Red",
		RouteNumber: routeNumber,
		From:        originStop.Name,
		To:          destStop.Name,
		Duration:    busDuration,
		Distance:    busDistance / 1000,
		Instruction: fmt.Sprintf("Toma el bus Red %s en %s. Viaja hacia %s y bájate en %s", 
			routeNumber, originStop.Name, routeInfo.Direction, destStop.Name),
		Geometry:    fullGeometry,
		DepartStop:  &originStop,
		ArriveStop:  &destStop,
	}
	
	itinerary.Legs = append(itinerary.Legs, busLeg)
	currentTime = currentTime.Add(time.Duration(busDuration) * time.Minute)
	
	// Calcular totales
	itinerary.TotalDuration = busDuration
	itinerary.TotalDistance = busDistance / 1000
	itinerary.DepartureTime = now.Format("15:04")
	itinerary.ArrivalTime = currentTime.Format("15:04")
	
	return itinerary
}

// generateItineraryWithRouteFromMovit genera un itinerario usando datos de Moovit
// NO depende de GTFS - usa la duración y número de ruta extraídos del HTML
func (s *Scraper) generateItineraryWithRouteFromMovit(routeNumber string, durationMinutes int, stopCount int, stopCode string, routeHTML string, fullHTML string, originLat, originLon, destLat, destLon float64) *RouteItinerary {
	log.Printf("🚌 Generando itinerario básico con datos de Moovit: Ruta %s, %d min, %d paradas, Paradero: %s", 
		routeNumber, durationMinutes, stopCount, stopCode)
	
	// Si no se pudo extraer el stopCount del HTML, estimarlo basado en la duración
	if stopCount == 0 && durationMinutes > 0 {
		// Estimado: 1 parada cada 1.5 minutos en promedio
		stopCount = int(float64(durationMinutes) / 1.5)
		if stopCount < 1 {
			stopCount = 1 // Al menos 1 parada
		}
		log.Printf("   📊 Estimando número de paradas basado en duración: %d paradas (~1 cada 1.5 min)", stopCount)
	}
	
	itinerary := &RouteItinerary{
		Origin:        Coordinate{Latitude: originLat, Longitude: originLon},
		Destination:   Coordinate{Latitude: destLat, Longitude: destLon},
		Legs:          []TripLeg{},
		RedBusRoutes:  []string{routeNumber},
		TotalDuration: durationMinutes,
	}
	
	// Intentar obtener información de GTFS primero
	routeInfo := s.getRouteInfo(routeNumber)
	
	// Si tenemos stopCode de Moovit, buscar paradero exacto en GTFS por código
	var originStop BusStop
	var useExactStop bool = false
	
	if stopCode != "" {
		log.Printf("🔍 [GTFS] Buscando paradero con código exacto: '%s' (len=%d)", stopCode, len(stopCode))
		// DEBUGGING: Mostrar cada carácter
		for i, ch := range stopCode {
			log.Printf("   [DEBUG] Antes de getStopByCode - stopCode[%d] = '%c' (byte=%d)", i, ch, ch)
		}
		
		exactStop, err := s.getStopByCode(stopCode)
		if err == nil && exactStop != nil {
			log.Printf("✅ [GTFS] Paradero encontrado por código: %s - %s (%.6f, %.6f)", 
				stopCode, exactStop.Name, exactStop.Latitude, exactStop.Longitude)
			originStop = *exactStop
			useExactStop = true
		} else {
			log.Printf("⚠️  [GTFS] No se encontró paradero con código %s: %v", stopCode, err)
		}
	}
	
	// Si no tenemos código o no se encontró, buscar por proximidad
	if !useExactStop && len(routeInfo.Stops) > 0 {
		log.Printf("🔍 [GTFS] Buscando paradero más cercano al origen")
		originStop = s.findNearestStopOnRoute(originLat, originLon, routeInfo.Stops)
		log.Printf("✅ [GTFS] Paradero más cercano: %s (%.6f, %.6f)", 
			originStop.Name, originStop.Latitude, originStop.Longitude)
	}
	
	// Si tenemos paradas de GTFS, generar geometría detallada
	if len(routeInfo.Stops) > 0 {
		log.Printf("[INFO] Usando paradas de GTFS para ruta %s", routeNumber)
		
		destStop := s.findNearestStopOnRoute(destLat, destLon, routeInfo.Stops)
		
		// Calcular distancia de caminata al paradero de origen
		walkDistance := s.calculateDistance(originLat, originLon, originStop.Latitude, originStop.Longitude)
		
		// SIEMPRE agregar pierna de caminata (incluso si está cerca)
		// El frontend decidirá si saltarla basado en GPS real
		walkDuration := int((walkDistance / 80) / 60) // 80 m/min velocidad de caminata
		if walkDuration < 1 {
			walkDuration = 1 // Mínimo 1 minuto
		}
		
		walkGeometry := [][]float64{
			{originLon, originLat},
			{originStop.Longitude, originStop.Latitude},
		}
		
		walkLeg := TripLeg{
			Type:        "walk",
			Mode:        "walk",
			Duration:    walkDuration,
			Distance:    walkDistance / 1000,
			Instruction: fmt.Sprintf("Camina hacia el paradero %s", originStop.Name),
			Geometry:    walkGeometry,
			DepartStop: &BusStop{
				Name:      "Tu ubicación",
				Latitude:  originLat,
				Longitude: originLon,
			},
			ArriveStop: &originStop,
		}
		
		itinerary.Legs = append(itinerary.Legs, walkLeg)
		itinerary.TotalDuration += walkDuration
		itinerary.TotalDistance += walkDistance / 1000
		
		log.Printf("🚶 Agregada pierna de caminata: %.0fm, %d min (distancia al paradero)", walkDistance, walkDuration)
		
		busDistance := s.calculateDistance(originStop.Latitude, originStop.Longitude, destStop.Latitude, destStop.Longitude)
		busGeometry := s.generateBusRouteGeometry(originStop, destStop, routeInfo.Stops)
		
		fullGeometry := [][]float64{{originStop.Longitude, originStop.Latitude}}
		fullGeometry = append(fullGeometry, busGeometry...)
		fullGeometry = append(fullGeometry, []float64{destLon, destLat})
		
		busLeg := TripLeg{
			Type:        "bus",
			Mode:        "Red",
			RouteNumber: routeNumber,
			From:        originStop.Name,
			To:          destStop.Name,
			Duration:    durationMinutes,
			Distance:    busDistance / 1000,
			Instruction: fmt.Sprintf("Toma el bus Red %s en %s hacia %s", routeNumber, originStop.Name, destStop.Name),
			Geometry:    fullGeometry,
			DepartStop:  &originStop,
			ArriveStop:  &destStop,
			StopCount:   stopCount, // Número de paradas desde Moovit
		}
		
		itinerary.Legs = append(itinerary.Legs, busLeg)
		itinerary.TotalDistance += busDistance / 1000
	} else {
		// GTFS falló - intentar extraer paraderos reales desde HTML de Moovit
		log.Printf("[WARN] GTFS no disponible para ruta %s - intentando extraer paraderos desde HTML de Moovit", routeNumber)
		
		distance := s.calculateDistance(originLat, originLon, destLat, destLon)
		
		// Intentar extraer nombres de paraderos desde el HTML COMPLETO
		// Buscar patrones comunes de códigos de paraderos en Moovit
		// Patrones a buscar (ordenados por especificidad):
		stopPatterns := []*regexp.Regexp{
			// Patrón 1: Código dentro de <span> con guion (ej: <span>PC115-Avenida...)
			regexp.MustCompile(`<span[^>]*>(P[CABDEIJLRSUX]\d{3,5})-`),
			// Patrón 2: Código con guion y nombre (ej: PC615-Avenida Las Condes)
			regexp.MustCompile(`(P[CABDEIJLRSUX]\d{3,5})-[A-Za-zÁ-ú\s/\.]+`),
			// Patrón 3: Código entre delimitadores (>, espacio, comilla)
			regexp.MustCompile(`[>\s"'](P[CABDEIJLRSUX]\d{3,5})[-\s<"']`),
			// Patrón 4: Código en texto general
			regexp.MustCompile(`\b(P[CABDEIJLRSUX]\d{3,5})\b`),
		}
		
		geocodedStops := make([]BusStop, 0)
		seenCodes := make(map[string]bool) // Evitar duplicados
		
		// DEBUG: Buscar manualmente el código de paradero que sabemos que existe
		if strings.Contains(fullHTML, "PC1237") {
			log.Printf("   🔍 [DEBUG] HTML contiene 'PC1237', buscando contexto...")
			// Encontrar la posición y mostrar contexto
			idx := strings.Index(fullHTML, "PC1237")
			if idx >= 0 {
				start := idx - 100
				if start < 0 {
					start = 0
				}
				end := idx + 150
				if end > len(fullHTML) {
					end = len(fullHTML)
				}
				log.Printf("   📄 [CONTEXT] ...%s...", fullHTML[start:end])
			}
		} else {
			log.Printf("   ⚠️  [DEBUG] HTML NO contiene 'PC1237'")
		}
		
		// Buscar en HTML completo primero
		for patternIdx, pattern := range stopPatterns {
			matches := pattern.FindAllStringSubmatch(fullHTML, -1)
			if len(matches) > 0 {
				log.Printf("   🔍 [PATTERN %d] Encontrados %d matches en HTML completo", patternIdx+1, len(matches))
				
				for _, match := range matches {
					if len(match) < 2 {
						continue
					}
					stopCode := match[1]
					
					// Evitar duplicados
					if seenCodes[stopCode] {
						continue
					}
					seenCodes[stopCode] = true
					
					// Intentar buscar por código en GTFS
					gtfsStop, err := s.getStopByCode(stopCode)
					if err == nil && gtfsStop != nil {
						geocodedStop := BusStop{
							Name:      gtfsStop.Name,
							Latitude:  gtfsStop.Latitude,
							Longitude: gtfsStop.Longitude,
							Sequence:  len(geocodedStops),
						}
						geocodedStops = append(geocodedStops, geocodedStop)
						log.Printf("      ✅ %s: %s (%.6f, %.6f)", stopCode, gtfsStop.Name, gtfsStop.Latitude, gtfsStop.Longitude)
						
						// Limitar a máximo 50 paraderos para evitar exceso
						if len(geocodedStops) >= 50 {
							break
						}
					}
				}
				
				// Si encontramos suficientes paraderos con este patrón, no probar los siguientes
				if len(geocodedStops) >= 5 {
					break
				}
			}
		}
		
		if len(geocodedStops) > 0 {
			log.Printf("✅ [MOOVIT-HTML] Total paraderos geocodificados: %d", len(geocodedStops))
		} else {
			log.Printf("⚠️  [MOOVIT-HTML] No se encontraron paraderos en HTML")
		}
		
		var geometry [][]float64
		
		// Si obtuvimos suficientes paraderos geocodificados, usarlos para geometría
		if len(geocodedStops) >= 2 {
			log.Printf("✅ [GEOMETRY] Construyendo geometría con %d paraderos reales", len(geocodedStops))
			geometry = make([][]float64, 0, len(geocodedStops))
			for _, stop := range geocodedStops {
				geometry = append(geometry, []float64{stop.Longitude, stop.Latitude})
			}
		} else {
			log.Printf("⚠️  [GEOMETRY] Solo %d paraderos geocodificados, usando geometría simple", len(geocodedStops))
			geometry = s.generateStraightLineGeometry(originLat, originLon, destLat, destLon, 5)
		}
		
		simpleGeometry := geometry
		
		// IMPORTANTE: Si encontramos el paradero por código, usarlo aunque la ruta no exista
		var departStop *BusStop
		if useExactStop {
			// Usar el paradero real encontrado por código
			departStop = &BusStop{
				Name:      originStop.Name,
				Latitude:  originStop.Latitude,
				Longitude: originStop.Longitude,
				Sequence:  0,
			}
			log.Printf("✅ [FALLBACK] Usando paradero real encontrado: %s (%.6f, %.6f)", departStop.Name, departStop.Latitude, departStop.Longitude)
		} else {
			// Si no encontramos paradero, usar coordenadas de origen (subóptimo)
			departStop = &BusStop{
				Name:      fmt.Sprintf("Paradero cercano (%s)", stopCode),
				Latitude:  originLat,
				Longitude: originLon,
				Sequence:  0,
			}
			log.Printf("⚠️  [FALLBACK] Usando coordenadas de origen como paradero: %s (%.6f, %.6f)", departStop.Name, departStop.Latitude, departStop.Longitude)
		}
		
		arriveStop := &BusStop{
			Name:      "Paradero de destino",
			Latitude:  destLat,
			Longitude: destLon,
			Sequence:  1,
		}
		
		log.Printf("✅ [FALLBACK] Creado arriveStop: %s (%.6f, %.6f)", arriveStop.Name, arriveStop.Latitude, arriveStop.Longitude)
		
		busLeg := TripLeg{
			Type:        "bus",
			Mode:        "Red",
			RouteNumber: routeNumber,
			From:        departStop.Name,
			To:          arriveStop.Name,
			Duration:    durationMinutes,
			Distance:    distance / 1000,
			Instruction: fmt.Sprintf("Tomar bus Red %s hacia el destino", routeNumber),
			Geometry:    simpleGeometry,
			StopCount:   stopCount, // Número de paradas desde Moovit
			DepartStop:  departStop, // CRÍTICO: Siempre tener paradero de origen
			ArriveStop:  arriveStop, // CRÍTICO: Siempre tener paradero de destino
		}
		
		log.Printf("✅ [FALLBACK] busLeg creado - DepartStop: %v, ArriveStop: %v", busLeg.DepartStop != nil, busLeg.ArriveStop != nil)
		
		itinerary.Legs = append(itinerary.Legs, busLeg)
		itinerary.TotalDistance = distance / 1000
	}
	
	// Calcular tiempos
	now := time.Now()
	itinerary.DepartureTime = now.Format("15:04")
	itinerary.ArrivalTime = now.Add(time.Duration(durationMinutes) * time.Minute).Format("15:04")
	
	log.Printf("[INFO] Itinerario generado: %d legs, duracion total: %d min", len(itinerary.Legs), itinerary.TotalDuration)
	
	return itinerary
}

// generateItineraryFromRealData genera un itinerario usando datos reales de rutas Red de Santiago
// Basado en información pública de Transantiago para fines educacionales
func (s *Scraper) generateItineraryFromRealData(originLat, originLon, destLat, destLon float64) *RouteItinerary {
	itinerary := &RouteItinerary{
		Origin:       Coordinate{Latitude: originLat, Longitude: originLon},
		Destination:  Coordinate{Latitude: destLat, Longitude: destLon},
		Legs:         []TripLeg{},
		RedBusRoutes: []string{},
	}

	// Calcular distancia total del viaje para logging
	totalDistance := s.calculateDistance(originLat, originLon, destLat, destLon)
	log.Printf("[INFO] Distancia total del viaje: %.2f km", totalDistance/1000)
	
	// Determinar la mejor ruta Red basada en ubicación y dirección
	bestRoute := s.findBestRedRoute(originLat, originLon, destLat, destLon)
	routeInfo := s.getRouteInfo(bestRoute)
	
	itinerary.RedBusRoutes = []string{bestRoute}
	
	now := time.Now()
	currentTime := now
	
	// Calcular paradas cercanas al origen y destino
	originStop := s.findNearestStopOnRoute(originLat, originLon, routeInfo.Stops)
	destStop := s.findNearestStopOnRoute(destLat, destLon, routeInfo.Stops)
	
	log.Printf("🚏 PARADA DE ORIGEN: %s (%.6f, %.6f) - Secuencia: %d", 
		originStop.Name, originStop.Latitude, originStop.Longitude, originStop.Sequence)
	log.Printf("🚏 PARADA DE DESTINO: %s (%.6f, %.6f) - Secuencia: %d", 
		destStop.Name, destStop.Latitude, destStop.Longitude, destStop.Sequence)
	
	// VALIDAR: Si origen y destino son la misma parada, hay un problema
	if originStop.Sequence == destStop.Sequence {
		log.Printf("❌ ERROR: Origen y destino son la misma parada!")
		log.Printf("   Esto significa que las coordenadas recibidas están muy cerca")
		log.Printf("   Origen frontend: %.6f, %.6f", originLat, originLon)
		log.Printf("   Destino frontend: %.6f, %.6f", destLat, destLon)
	}
	
	// SOLO VIAJE EN BUS - Sin caminatas
	// Calcular distancia y duración del viaje en bus
	busDistance := s.calculateDistance(originStop.Latitude, originStop.Longitude, destStop.Latitude, destStop.Longitude)
	busDuration := int((busDistance / 400) / 60) // 400 m/min = velocidad promedio bus urbano
	if busDuration < 5 {
		busDuration = 10 // Duración mínima realista
	}
	
	// Crear geometría de la ruta del bus incluyendo origen y destino
	busGeometry := s.generateBusRouteGeometry(originStop, destStop, routeInfo.Stops)
	
	// Agregar punto de origen al inicio de la geometría
	fullGeometry := [][]float64{{originLon, originLat}}
	fullGeometry = append(fullGeometry, busGeometry...)
	fullGeometry = append(fullGeometry, []float64{destLon, destLat})
	
	// Validar que la geometría no esté vacía
	if len(fullGeometry) < 2 {
		log.Printf("⚠️  [GEOMETRY] Geometría insuficiente, creando línea directa")
		fullGeometry = [][]float64{
			{originLon, originLat},
			{originStop.Longitude, originStop.Latitude},
			{destStop.Longitude, destStop.Latitude},
			{destLon, destLat},
		}
	}
	
	log.Printf("✅ [ROUTE] Geometría final: %d puntos", len(fullGeometry))
	
	busLeg := TripLeg{
		Type:        "bus",
		Mode:        "Red",
		RouteNumber: bestRoute,
		From:        originStop.Name,
		To:          destStop.Name,
		Duration:    busDuration,
		Distance:    busDistance / 1000, // metros a km
		Instruction: fmt.Sprintf("Toma el bus Red %s en %s. Viaja hacia %s y bájate en %s", 
			bestRoute, originStop.Name, routeInfo.Direction, destStop.Name),
		Geometry:    fullGeometry,
		DepartStop:  &originStop,
		ArriveStop:  &destStop,
	}
	itinerary.Legs = append(itinerary.Legs, busLeg)
	currentTime = currentTime.Add(time.Duration(busDuration) * time.Minute)
	
	// Calcular totales
	for _, leg := range itinerary.Legs {
		itinerary.TotalDuration += leg.Duration
		itinerary.TotalDistance += leg.Distance
	}
	
	itinerary.DepartureTime = now.Format("15:04")
	itinerary.ArrivalTime = currentTime.Format("15:04")
	
	return itinerary
}

// generateFallbackOptions genera opciones de ruta cuando el scraping falla
func (s *Scraper) generateFallbackOptions(originLat, originLon, destLat, destLon float64) *RouteOptions {
	log.Printf("🔄 Generando opciones de ruta con algoritmo heurístico")
	
	itinerary := s.generateItineraryFromRealData(originLat, originLon, destLat, destLon)
	
	return &RouteOptions{
		Origin:      Coordinate{Latitude: originLat, Longitude: originLon},
		Destination: Coordinate{Latitude: destLat, Longitude: destLon},
		Options:     []RouteItinerary{*itinerary},
	}
}

// calculateDistance calcula la distancia en metros entre dos coordenadas usando Haversine
func (s *Scraper) calculateDistance(lat1, lon1, lat2, lon2 float64) float64 {
	const R = 6371000 // Radio de la Tierra en metros
	
	lat1Rad := lat1 * math.Pi / 180
	lat2Rad := lat2 * math.Pi / 180
	deltaLat := (lat2 - lat1) * math.Pi / 180
	deltaLon := (lon2 - lon1) * math.Pi / 180
	
	// Fórmula de Haversine
	a := math.Sin(deltaLat/2)*math.Sin(deltaLat/2) +
	    math.Cos(lat1Rad)*math.Cos(lat2Rad)*
	    math.Sin(deltaLon/2)*math.Sin(deltaLon/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
	
	return R * c
}

// generateStraightLineGeometry crea una línea recta con puntos intermedios para mejor visualización
func (s *Scraper) generateStraightLineGeometry(lat1, lon1, lat2, lon2 float64, numPoints int) [][]float64 {
	geometry := make([][]float64, 0, numPoints+2)
	
	// Punto inicial
	geometry = append(geometry, []float64{lon1, lat1})
	
	// Generar puntos intermedios
	for i := 1; i <= numPoints; i++ {
		fraction := float64(i) / float64(numPoints+1)
		
		// Interpolación lineal
		lat := lat1 + (lat2-lat1)*fraction
		lon := lon1 + (lon2-lon1)*fraction
		
		geometry = append(geometry, []float64{lon, lat})
	}
	
	// Punto final
	geometry = append(geometry, []float64{lon2, lat2})
	
	log.Printf("📏 Geometría simple generada con %d puntos", len(geometry))
	return geometry
}

// findBestRedRoute determina la mejor ruta Red basada en origen y destino
// Busca rutas que tengan paradas cerca tanto del origen como del destino
func (s *Scraper) findBestRedRoute(originLat, originLon, destLat, destLon float64) string {
	log.Printf("🔍 Buscando mejor ruta para origen (%.4f, %.4f) y destino (%.4f, %.4f)", 
		originLat, originLon, destLat, destLon)
	
	// Lista de rutas disponibles
	routeNumbers := []string{"104", "210", "211", "405", "426", "427", "506", "516"}
	
	type RouteScore struct {
		RouteNumber      string
		OriginDistance   float64 // Distancia del origen a la parada más cercana
		DestDistance     float64 // Distancia del destino a la parada más cercana
		TotalScore       float64 // Combinación de ambas distancias
	}
	
	var scores []RouteScore
	
	for _, routeNum := range routeNumbers {
		route, err := s.GetRedBusRoute(routeNum)
		if err != nil || len(route.Stops) == 0 {
			log.Printf("⚠️  Ruta %s no disponible", routeNum)
			continue
		}
		
		// Encontrar parada más cercana al origen
		minOriginDist := 999999.0
		for _, stop := range route.Stops {
			dist := s.calculateDistance(originLat, originLon, stop.Latitude, stop.Longitude)
			if dist < minOriginDist {
				minOriginDist = dist
			}
		}
		
		// Encontrar parada más cercana al destino
		minDestDist := 999999.0
		for _, stop := range route.Stops {
			dist := s.calculateDistance(destLat, destLon, stop.Latitude, stop.Longitude)
			if dist < minDestDist {
				minDestDist = dist
			}
		}
		
		// Score: menor es mejor (suma de distancias)
		// Penalizar si cualquiera de las dos está muy lejos
		totalScore := minOriginDist + minDestDist
		
		// Penalizar si origen o destino está a más de 1km
		if minOriginDist > 1000 {
			totalScore += 10000
		}
		if minDestDist > 1000 {
			totalScore += 10000
		}
		
		scores = append(scores, RouteScore{
			RouteNumber:    routeNum,
			OriginDistance: minOriginDist,
			DestDistance:   minDestDist,
			TotalScore:     totalScore,
		})
		
		log.Printf("📊 Ruta %s: origen %.0fm, destino %.0fm, score: %.0f", 
			routeNum, minOriginDist, minDestDist, totalScore)
	}
	
	if len(scores) == 0 {
		log.Printf("❌ No se encontraron rutas disponibles, usando 506 por defecto")
		return "506"
	}
	
	// Ordenar por score (menor es mejor)
	bestRoute := scores[0]
	for _, score := range scores {
		if score.TotalScore < bestRoute.TotalScore {
			bestRoute = score
		}
	}
	
	log.Printf("🎯 Mejor ruta seleccionada: %s (origen: %.0fm, destino: %.0fm)", 
		bestRoute.RouteNumber, bestRoute.OriginDistance, bestRoute.DestDistance)
	
	return bestRoute.RouteNumber
}

// getRouteInfo obtiene información detallada de una ruta desde GTFS
func (s *Scraper) getRouteInfo(routeNumber string) *RedBusRoute {
	route, err := s.GetRedBusRoute(routeNumber)
	if err != nil || len(route.Stops) == 0 {
		log.Printf("⚠️  No se pudo obtener información de ruta %s desde GTFS: %v", routeNumber, err)
		// IMPORTANTE: Retornar ruta vacía en lugar de datos fake
		// Esto forzará al frontend a mostrar error en lugar de datos incorrectos
		route = &RedBusRoute{
			RouteNumber: routeNumber,
			RouteName:   fmt.Sprintf("Red %s", routeNumber),
			Direction:   "Dirección principal",
			Stops:       []BusStop{}, // Lista vacía - NO usar datos genéricos
		}
	} else {
		log.Printf("✅ Ruta %s cargada desde GTFS con %d paradas", routeNumber, len(route.Stops))
	}
	return route
}

// findNearestStopOnRoute encuentra la parada más cercana en una ruta
func (s *Scraper) findNearestStopOnRoute(lat, lon float64, stops []BusStop) BusStop {
	if len(stops) == 0 {
		return BusStop{
			Name:      "Paradero cercano",
			Latitude:  lat,
			Longitude: lon,
			Sequence:  1,
		}
	}
	
	minDist := 999999.0
	var nearestStop BusStop
	
	for _, stop := range stops {
		dist := s.calculateDistance(lat, lon, stop.Latitude, stop.Longitude)
		if dist < minDist {
			minDist = dist
			nearestStop = stop
		}
	}
	
	return nearestStop
}

// getStopByCode busca un paradero por código en la base de datos GTFS
// Código de ejemplo: "PC1237", "PJ178", "PA4321"
func (s *Scraper) getStopByCode(stopCode string) (*BusStop, error) {
	if s.db == nil {
		return nil, fmt.Errorf("base de datos no disponible")
	}
	
	log.Printf("🔍 [GTFS] Consultando base de datos para código: '%s' (len=%d bytes)", stopCode, len(stopCode))
	
	// DEBUGGING: Mostrar cada carácter del código
	for i, ch := range stopCode {
		log.Printf("   [DEBUG] stopCode[%d] = '%c' (byte=%d)", i, ch, ch)
	}
	
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	
	var stop BusStop
	var stopID, code, description, zoneID sql.NullString
	
	// CORREGIDO: Buscar en AMBOS campos (stop_id Y code) porque en GTFS de Santiago
	// el código PC1237 está en stop_id, no en code
	query := `
		SELECT stop_id, code, name, description, latitude, longitude, zone_id
		FROM gtfs_stops
		WHERE UPPER(stop_id) = UPPER(?) OR UPPER(code) = UPPER(?)
		LIMIT 1
	`
	
	log.Printf("🔍 [GTFS] Ejecutando query con parámetro: '%s'", stopCode)
	
	err := s.db.QueryRowContext(ctx, query, stopCode, stopCode).Scan(
		&stopID,      // stop_id
		&code,        // code
		&stop.Name,
		&description,
		&stop.Latitude,
		&stop.Longitude,
		&zoneID,
	)
	
	if err != nil {
		if err == sql.ErrNoRows {
			log.Printf("❌ [GTFS] No se encontraron filas para código: '%s'", stopCode)
			// DEBUGGING: Verificar si hay datos similares
			var count int
			s.db.QueryRow("SELECT COUNT(*) FROM gtfs_stops WHERE stop_id LIKE ? OR code LIKE ?", "%"+stopCode+"%", "%"+stopCode+"%").Scan(&count)
			log.Printf("   [DEBUG] Paraderos con código similar: %d", count)
			
			return nil, fmt.Errorf("paradero con código %s no encontrado en GTFS", stopCode)
		}
		log.Printf("❌ [GTFS] Error de base de datos: %v", err)
		return nil, fmt.Errorf("error consultando GTFS: %v", err)
	}
	
	// Asignar el código del paradero (priorizar stop_id si code está vacío)
	if code.Valid && code.String != "" {
		stop.Code = code.String
	} else if stopID.Valid && stopID.String != "" {
		stop.Code = stopID.String
	} else {
		stop.Code = stopCode // Usar el código buscado como fallback
	}
	
	log.Printf("✅ [GTFS] Paradero encontrado: %s-%s (%.6f, %.6f)", stop.Code, stop.Name, stop.Latitude, stop.Longitude)
	
	return &stop, nil
}

// generateBusRouteGeometry genera la geometría del recorrido del bus
// NOTA: Solo usa coordenadas de paradas porque en frontend se visualizan con GraphHopper
// como marcadores individuales, no como una línea de ruta
func (s *Scraper) generateBusRouteGeometry(origin, dest BusStop, allStops []BusStop) [][]float64 {
	geometry := [][]float64{}
	
	log.Printf("🗺️  [GEOMETRY] Generando geometría entre parada %d y %d", origin.Sequence, dest.Sequence)
	log.Printf("🗺️  [GEOMETRY] Total de paradas disponibles: %d", len(allStops))
	
	// Encontrar índices de origen y destino
	startIdx := -1
	endIdx := -1
	
	for i, stop := range allStops {
		if stop.Sequence == origin.Sequence {
			startIdx = i
			log.Printf("🗺️  [GEOMETRY] Parada origen encontrada en índice %d: %s", i, stop.Name)
		}
		if stop.Sequence == dest.Sequence {
			endIdx = i
			log.Printf("🗺️  [GEOMETRY] Parada destino encontrada en índice %d: %s", i, stop.Name)
		}
	}
	
	// Si encontramos ambos, usar las paradas intermedias (solo coordenadas de paradas)
	if startIdx >= 0 && endIdx >= 0 {
		if startIdx > endIdx {
			startIdx, endIdx = endIdx, startIdx
		}
		
		log.Printf("🗺️  [GEOMETRY] Agregando %d paradas entre origen y destino", endIdx-startIdx+1)
		// SOLO agregar coordenadas de paradas (routing de calles lo hace GraphHopper en frontend)
		for i := startIdx; i <= endIdx; i++ {
			geometry = append(geometry, []float64{allStops[i].Longitude, allStops[i].Latitude})
		}
	} else {
		// Si no encontramos índices, crear línea directa entre origen y destino
		log.Printf("⚠️  [GEOMETRY] No se encontraron índices, usando línea directa")
		geometry = append(geometry, []float64{origin.Longitude, origin.Latitude})
		geometry = append(geometry, []float64{dest.Longitude, dest.Latitude})
	}
	
	log.Printf("✅ [GEOMETRY] Geometría de bus generada con %d puntos (solo paradas)", len(geometry))
	return geometry
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

// ============================================================================
// FASE 1: Obtener opciones ligeras SIN geometría (para selección por voz)
// ============================================================================

// GetLightweightRouteOptions obtiene opciones básicas sin generar geometría completa
// Esto permite que el usuario seleccione por voz antes de calcular rutas detalladas
func (s *Scraper) GetLightweightRouteOptions(originLat, originLon, destLat, destLon float64) (*LightweightRouteOptions, error) {
	log.Printf("🚌 ============================================")
	log.Printf("🚌 FASE 1: OBTENER OPCIONES LIGERAS")
	log.Printf("🚌 ============================================")
	log.Printf("📍 ORIGEN: LAT=%.6f, LON=%.6f", originLat, originLon)
	log.Printf("📍 DESTINO: LAT=%.6f, LON=%.6f", destLat, destLon)
	
	// Convertir coordenadas a nombres de lugares
	originName, err := s.reverseGeocode(originLat, originLon)
	if err != nil {
		log.Printf("⚠️  Error en geocoding de origen: %v", err)
		originName = "Origen"
	}
	
	destName, err := s.reverseGeocode(destLat, destLon)
	if err != nil {
		log.Printf("⚠️  Error en geocoding de destino: %v", err)
		destName = "Destino"
	}
	
	log.Printf("📍 Origen geocodificado: %s", originName)
	log.Printf("📍 Destino geocodificado: %s", destName)
	
	// Scraping de Moovit con Chrome headless
	originEncoded := url.PathEscape(originName)
	destEncoded := url.PathEscape(destName)
	
	moovitURL := fmt.Sprintf("%s/tripplan/santiago-642/poi/%s/%s/es-419?fll=%.6f_%.6f&tll=%.6f_%.6f&customerId=4908&metroSeoName=Santiago",
		s.baseURL,
		destEncoded,
		originEncoded,
		originLat, originLon,
		destLat, destLon,
	)
	
	log.Printf("🔍 [MOOVIT] URL construida: %s", moovitURL)
	
	// Obtener HTML con Chrome headless
	htmlContent, err := s.fetchMovitHTML(moovitURL)
	if err != nil {
		return nil, fmt.Errorf("error obteniendo HTML de Moovit: %v", err)
	}
	
	log.Printf("📄 [MOOVIT] HTML obtenido: %d caracteres", len(htmlContent))
	
	// Parsear solo información básica (sin geometría)
	return s.parseLightweightOptions(htmlContent, originLat, originLon, destLat, destLon)
}

// fetchMovitHTML usa Chrome headless para obtener el HTML renderizado de Moovit
func (s *Scraper) fetchMovitHTML(moovitURL string) (string, error) {
	log.Printf("🌐 [MOOVIT] Iniciando Chrome headless...")
	
	// Detectar Chrome/Edge en Windows
	chromePaths := []string{
		"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
		"C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
		"C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
		"C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
	}
	
	var chromePath string
	for _, path := range chromePaths {
		if _, err := os.Stat(path); err == nil {
			chromePath = path
			log.Printf("✅ [CHROME] Encontrado en: %s", chromePath)
			break
		}
	}
	
	if chromePath == "" {
		return "", fmt.Errorf("no se encontró Chrome o Edge instalado")
	}
	
	// Crear contexto con timeout
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	
	// Crear contexto de Chrome
	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.ExecPath(chromePath),
		chromedp.Flag("headless", true),
		chromedp.Flag("disable-gpu", true),
		chromedp.Flag("no-sandbox", true),
		chromedp.Flag("disable-dev-shm-usage", true),
		chromedp.UserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
	)
	
	allocCtx, allocCancel := chromedp.NewExecAllocator(ctx, opts...)
	defer allocCancel()
	
	browserCtx, browserCancel := chromedp.NewContext(allocCtx, chromedp.WithLogf(log.Printf))
	defer browserCancel()
	
	var htmlContent string
	
	err := chromedp.Run(browserCtx,
		chromedp.Navigate(moovitURL),
		chromedp.WaitVisible(`mv-suggested-route`, chromedp.ByQuery),
		chromedp.Sleep(2*time.Second),
		chromedp.OuterHTML(`html`, &htmlContent, chromedp.ByQuery),
	)
	
	if err != nil {
		return "", fmt.Errorf("error ejecutando Chrome: %v", err)
	}
	
	// Guardar HTML para debugging
	if err := os.WriteFile("moovit_chromedp_debug.html", []byte(htmlContent), 0644); err != nil {
		log.Printf("⚠️  No se pudo guardar HTML debug: %v", err)
	} else {
		log.Printf("💾 HTML guardado en moovit_chromedp_debug.html")
	}
	
	return htmlContent, nil
}

// parseLightweightOptions parsea el HTML de Moovit para extraer SOLO información básica
func (s *Scraper) parseLightweightOptions(html string, originLat, originLon, destLat, destLon float64) (*LightweightRouteOptions, error) {
	log.Printf("🔍 Parseando opciones ligeras del HTML de Moovit...")
	
	// CACHEAR HTML para FASE 2 (evitar re-scraping)
	cacheKey := fmt.Sprintf("%.4f_%.4f_%.4f_%.4f", originLat, originLon, destLat, destLon)
	s.htmlCache[cacheKey] = HTMLCacheEntry{
		HTML:      html,
		Timestamp: time.Now(),
		OriginLat: originLat,
		OriginLon: originLon,
		DestLat:   destLat,
		DestLon:   destLon,
	}
	log.Printf("💾 HTML cacheado con clave: %s (válido por 5 minutos)", cacheKey)
	
	// Buscar todos los contenedores de rutas sugeridas
	suggestedRouteRegex := regexp.MustCompile(`<mv-suggested-route[^>]*>([\s\S]*?)</mv-suggested-route>`)
	containerMatches := suggestedRouteRegex.FindAllStringSubmatch(html, -1)
	
	if len(containerMatches) == 0 {
		log.Printf("⚠️  No se encontró mv-suggested-route en el HTML")
		return nil, fmt.Errorf("no se encontraron rutas en Moovit")
	}
	
	log.Printf("✅ Encontradas %d opciones de rutas", len(containerMatches))
	
	lightweightOptions := &LightweightRouteOptions{
		Origin:      Coordinate{Latitude: originLat, Longitude: originLon},
		Destination: Coordinate{Latitude: destLat, Longitude: destLon},
		Options:     []LightweightOption{},
		HTMLCache:   "", // No enviamos HTML al cliente (solo interno)
	}
	
	// Procesar cada opción
	for idx, match := range containerMatches {
		if len(match) < 2 {
			continue
		}
		
		routeHTML := match[1]
		log.Printf("🔍 Procesando opción %d...", idx)
		
		// Extraer duración
		durationRegex := regexp.MustCompile(`<span[^>]*class="[^"]*duration[^"]*"[^>]*>(\d+)\s*min</span>`)
		durationMatch := durationRegex.FindStringSubmatch(routeHTML)
		duration := 30 // default
		if len(durationMatch) > 1 {
			fmt.Sscanf(durationMatch[1], "%d", &duration)
			log.Printf("   ⏱️  Duración: %d min", duration)
		}
		
		// Extraer número(s) de ruta
		routeNumbers := s.extractAllRouteNumbers(routeHTML)
		if len(routeNumbers) == 0 {
			log.Printf("   ⚠️  No se encontraron números de ruta, saltando...")
			continue
		}
		
		// Extraer tiempo de caminata
		walkingMinutes := s.extractWalkingTime(routeHTML)
		
		// Contar transbordos (número de rutas - 1)
		transfers := len(routeNumbers) - 1
		if transfers < 0 {
			transfers = 0
		}
		
		// Crear resumen legible para TTS
		summary := s.createSummary(routeNumbers, duration)
		
		log.Printf("   ✅ Opción %d: %s", idx, summary)
		
		option := LightweightOption{
			Index:         idx,
			RouteNumbers:  routeNumbers,
			TotalDuration: duration,
			Summary:       summary,
			WalkingTime:   walkingMinutes,
			Transfers:     transfers,
		}
		
		lightweightOptions.Options = append(lightweightOptions.Options, option)
	}
	
	if len(lightweightOptions.Options) == 0 {
		return nil, fmt.Errorf("no se pudieron extraer opciones de ruta")
	}
	
	log.Printf("🎯 Total de opciones ligeras generadas: %d", len(lightweightOptions.Options))
	return lightweightOptions, nil
}

// extractAllRouteNumbers extrae todos los números de ruta de un bloque HTML
func (s *Scraper) extractAllRouteNumbers(routeHTML string) []string {
	routeNumbers := []string{}
	
	// Patrones para buscar números de ruta
	patterns := []string{
		`line-number[^>]*>([A-Z0-9]+)</`,
		`route[^>]*>([A-Z0-9]+)</`,
		`line[^>]*>\s*([A-Z0-9]+)\s*</`,
		`bus[^>]*>([A-Z0-9]+)</`,
	}
	
	for _, pattern := range patterns {
		regex := regexp.MustCompile(pattern)
		matches := regex.FindAllStringSubmatch(routeHTML, -1)
		for _, match := range matches {
			if len(match) > 1 {
				routeNum := strings.TrimSpace(match[1])
				// Evitar duplicados
				isDuplicate := false
				for _, existing := range routeNumbers {
					if existing == routeNum {
						isDuplicate = true
						break
					}
				}
				if !isDuplicate && routeNum != "" {
					routeNumbers = append(routeNumbers, routeNum)
				}
			}
		}
		if len(routeNumbers) > 0 {
			break
		}
	}
	
	return routeNumbers
}

// extractWalkingTime extrae el tiempo total de caminata del HTML
func (s *Scraper) extractWalkingTime(routeHTML string) int {
	walkRegex := regexp.MustCompile(`(?i)walk|caminar[^>]*>(\d+)\s*min`)
	matches := walkRegex.FindAllStringSubmatch(routeHTML, -1)
	
	totalWalking := 0
	for _, match := range matches {
		if len(match) > 1 {
			var minutes int
			fmt.Sscanf(match[1], "%d", &minutes)
			totalWalking += minutes
		}
	}
	
	return totalWalking
}

// createSummary crea un resumen legible para TTS
func (s *Scraper) createSummary(routeNumbers []string, duration int) string {
	if len(routeNumbers) == 0 {
		return fmt.Sprintf("%d minutos", duration)
	}
	
	if len(routeNumbers) == 1 {
		return fmt.Sprintf("Bus %s, %d minutos", routeNumbers[0], duration)
	}
	
	// Múltiples buses
	busesStr := strings.Join(routeNumbers, " y ")
	return fmt.Sprintf("Buses %s, %d minutos", busesStr, duration)
}

// ============================================================================
// FASE 2: Obtener geometría detallada DESPUÉS de selección por voz
// ============================================================================

// GetDetailedItinerary genera geometría completa para la opción seleccionada
func (s *Scraper) GetDetailedItinerary(originLat, originLon, destLat, destLon float64, selectedOptionIndex int) (*RouteItinerary, error) {
	log.Printf("🚌 ============================================")
	log.Printf("🚌 FASE 2: GENERAR GEOMETRÍA DETALLADA")
	log.Printf("🚌 ============================================")
	log.Printf("📍 Opción seleccionada: %d", selectedOptionIndex)
	
	// INTENTAR USAR CACHÉ PRIMERO (evitar re-scraping)
	cacheKey := fmt.Sprintf("%.4f_%.4f_%.4f_%.4f", originLat, originLon, destLat, destLon)
	var htmlContent string
	
	if cached, exists := s.htmlCache[cacheKey]; exists {
		// Verificar si el caché es reciente (5 minutos)
		age := time.Since(cached.Timestamp)
		if age < 5*time.Minute {
			log.Printf("✅ Usando HTML cacheado (edad: %.0f segundos)", age.Seconds())
			htmlContent = cached.HTML
		} else {
			log.Printf("⚠️  Caché expirado (edad: %.0f segundos), re-scraping", age.Seconds())
			delete(s.htmlCache, cacheKey) // Limpiar caché expirado
		}
	}
	
	// Si no hay caché o expiró, hacer scraping
	if htmlContent == "" {
		log.Printf("🔄 No hay caché disponible, haciendo scraping...")
		
		originName, _ := s.reverseGeocode(originLat, originLon)
		destName, _ := s.reverseGeocode(destLat, destLon)
		
		if originName == "" {
			originName = "Origen"
		}
		if destName == "" {
			destName = "Destino"
		}
		
		originEncoded := url.PathEscape(originName)
		destEncoded := url.PathEscape(destName)
		
		moovitURL := fmt.Sprintf("%s/tripplan/santiago-642/poi/%s/%s/es-419?fll=%.6f_%.6f&tll=%.6f_%.6f&customerId=4908&metroSeoName=Santiago",
			s.baseURL,
			destEncoded,
			originEncoded,
			originLat, originLon,
			destLat, destLon,
		)
		
		var err error
		htmlContent, err = s.fetchMovitHTML(moovitURL)
		if err != nil {
			return nil, fmt.Errorf("error obteniendo HTML: %v", err)
		}
	}
	
	// Parsear HTML para obtener la opción específica
	return s.parseDetailedOption(htmlContent, originLat, originLon, destLat, destLon, selectedOptionIndex)
}

// parseDetailedOption parsea el HTML para generar geometría de una opción específica
func (s *Scraper) parseDetailedOption(html string, originLat, originLon, destLat, destLon float64, optionIndex int) (*RouteItinerary, error) {
	log.Printf("🔍 Parseando opción detallada %d...", optionIndex)
	
	// Guardar HTML completo para búsquedas posteriores
	fullHTML := html
	
	// Buscar todos los contenedores
	suggestedRouteRegex := regexp.MustCompile(`<mv-suggested-route[^>]*>([\s\S]*?)</mv-suggested-route>`)
	containerMatches := suggestedRouteRegex.FindAllStringSubmatch(html, -1)
	
	if len(containerMatches) == 0 {
		return nil, fmt.Errorf("no se encontraron rutas en el HTML")
	}
	
	if optionIndex >= len(containerMatches) {
		return nil, fmt.Errorf("índice de opción %d fuera de rango (total: %d)", optionIndex, len(containerMatches))
	}
	
	routeHTML := containerMatches[optionIndex][1]
	
	// Extraer duración
	durationRegex := regexp.MustCompile(`<span[^>]*class="[^"]*duration[^"]*"[^>]*>(\d+)\s*min</span>`)
	durationMatch := durationRegex.FindStringSubmatch(routeHTML)
	duration := 30
	if len(durationMatch) > 1 {
		fmt.Sscanf(durationMatch[1], "%d", &duration)
	}
	
	// Extraer número de ruta
	routeNumber := s.extractRouteNumber(routeHTML, optionIndex+1)
	if routeNumber == "" {
		return nil, fmt.Errorf("no se pudo extraer número de ruta")
	}
	
	log.Printf("✅ Generando geometría para ruta %s", routeNumber)
	
	// ESTRATEGIA MEJORADA: Extraer paradas EN ORDEN del itinerario
	// 1. Buscar "Sale desde XXX" para obtener parada de inicio con nombre
	// 2. Extraer todas las paradas del recorrido EN ORDEN
	// 3. Identificar parada final (última del bus antes de bajar)
	
	// Extraer parada de inicio desde "Sale desde PcXXXX-Nombre"
	startStopRegex := regexp.MustCompile(`(?i)Sale desde\s+(P[CABDEIJLRSUX]\d{3,5})[^<]*([^<]+)`)
	startMatch := startStopRegex.FindStringSubmatch(routeHTML)
	
	var startStopCode, startStopName string
	if len(startMatch) >= 3 {
		startStopCode = strings.ToUpper(startMatch[1])
		startStopName = strings.TrimSpace(startMatch[2])
		// Limpiar el nombre (remover "-" al inicio)
		startStopName = strings.TrimPrefix(startStopName, "-")
		startStopName = strings.TrimSpace(startStopName)
		log.Printf("🚏 Parada de INICIO: %s - %s", startStopCode, startStopName)
	}
	
	// Extraer TODAS las paradas del HTML (en orden de aparición)
	stopPattern := regexp.MustCompile(`(?i)(P[CABDEIJLRSUX]\d{3,5})`)
	foundStops := make(map[string]bool)
	stopCodes := []string{} // Mantiene el orden de aparición
	
	// Buscar en el HTML completo
	matches := stopPattern.FindAllStringSubmatch(fullHTML, -1)
	
	for _, match := range matches {
		if len(match) > 1 {
			code := strings.ToUpper(match[1])
			if !foundStops[code] {
				foundStops[code] = true
				stopCodes = append(stopCodes, code)
			}
		}
	}
	
	log.Printf("🔍 Encontrados %d códigos de paraderos únicos en HTML", len(stopCodes))
	
	// Si tenemos la parada de inicio, asegurar que esté primera
	if startStopCode != "" && len(stopCodes) > 0 {
		// Reorganizar para que startStopCode sea la primera
		reordered := []string{startStopCode}
		for _, code := range stopCodes {
			if code != startStopCode {
				reordered = append(reordered, code)
			}
		}
		stopCodes = reordered
		log.Printf("✅ Paradas reordenadas: inicio=%s, total=%d", startStopCode, len(stopCodes))
	}
	
	// Si encontramos paraderos, geocodificarlos con GTFS y construir itinerario
	if len(stopCodes) >= 2 {
		log.Printf("✅ Usando paraderos extraídos de Moovit HTML")
		
		geocodedStops := []BusStop{}
		seenCodes := make(map[string]bool)
		
		for i, code := range stopCodes {
			if seenCodes[code] {
				continue
			}
			seenCodes[code] = true
			
			stop, err := s.getStopByCode(code)
			if err == nil && stop != nil {
				stop.Sequence = i + 1
				geocodedStops = append(geocodedStops, *stop)
				log.Printf("   ✅ [GTFS] %s: %s (%.6f, %.6f)", code, stop.Name, stop.Latitude, stop.Longitude)
			} else {
				log.Printf("   ⚠️  [GTFS] No encontrado: %s", code)
			}
			
			// Limitar a 50 paraderos máximo
			if len(geocodedStops) >= 50 {
				break
			}
		}
		
		if len(geocodedStops) >= 2 {
			log.Printf("✅ [MOOVIT-HTML] Total paraderos geocodificados: %d", len(geocodedStops))
			// Usar el método del scraper funcional
			itinerary := s.buildItineraryFromStops(routeNumber, duration, geocodedStops, originLat, originLon, destLat, destLon)
			return itinerary, nil
		} else {
			log.Printf("⚠️  [MOOVIT-HTML] Solo %d paraderos geocodificados, usando fallback", len(geocodedStops))
		}
	}
	
	// FALLBACK: Si no hay suficientes paraderos del HTML, intentar GTFS
	log.Printf("⚠️  Moovit no trajo suficientes paradas, intentando GTFS como fallback")
	itinerary := s.generateItineraryWithRoute(routeNumber, originLat, originLon, destLat, destLon)
	itinerary.TotalDuration = duration
	
	return itinerary, nil
}

// parseStopsFromHTML intenta extraer nombres de paradas del HTML de Moovit
func (s *Scraper) parseStopsFromHTML(html string) []BusStop {
	stops := []BusStop{}
	
	// Buscar patrones comunes para nombres de paradas en Moovit
	// Patrón 1: <div class="stop-name">Nombre de Parada</div>
	stopNameRegex1 := regexp.MustCompile(`(?i)<[^>]*class="[^"]*stop[^"]*name[^"]*"[^>]*>([^<]+)</`)
	matches1 := stopNameRegex1.FindAllStringSubmatch(html, -1)
	
	for i, match := range matches1 {
		if len(match) > 1 {
			stopName := strings.TrimSpace(match[1])
			if stopName != "" && len(stopName) > 3 { // Filtrar nombres muy cortos
				stops = append(stops, BusStop{
					Name:     stopName,
					Sequence: i + 1,
					// Lat/Lon no disponibles en HTML simple, se calculan después
				})
			}
		}
	}
	
	// Patrón 2: Buscar texto que empiece con "Pc" (código de parada en Santiago)
	stopCodeRegex := regexp.MustCompile(`(Pc\d+[^<]*?)(?:</|<br)`)
	matches2 := stopCodeRegex.FindAllStringSubmatch(html, -1)
	
	for _, match := range matches2 {
		if len(match) > 1 {
			stopName := strings.TrimSpace(match[1])
			// Evitar duplicados
			isDuplicate := false
			for _, existing := range stops {
				if existing.Name == stopName {
					isDuplicate = true
					break
				}
			}
			if !isDuplicate && stopName != "" {
				stops = append(stops, BusStop{
					Name:     stopName,
					Sequence: len(stops) + 1,
				})
			}
		}
	}
	
	log.Printf("🔍 Encontradas %d paradas en HTML", len(stops))
	return stops
}

// generateItineraryFromMoovitStops genera un itinerario usando SOLO datos de Moovit (NO GTFS)
func (s *Scraper) generateItineraryFromMoovitStops(routeNumber string, stops []BusStop, originLat, originLon, destLat, destLon float64, durationMinutes int) *RouteItinerary {
	log.Printf("🚌 Generando itinerario desde Moovit: Ruta %s con %d paradas", routeNumber, len(stops))
	
	now := time.Now()
	
	// Usar primera y última parada de Moovit
	departStop := stops[0]
	arriveStop := stops[len(stops)-1]
	
	// Estimar coordenadas de paradas basadas en origen/destino
	// (Moovit no siempre trae lat/lon en el HTML)
	if departStop.Latitude == 0 {
		departStop.Latitude = originLat
		departStop.Longitude = originLon
	}
	if arriveStop.Latitude == 0 {
		arriveStop.Latitude = destLat
		arriveStop.Longitude = destLon
	}
	
	// Calcular distancia entre paradas
	distance := s.calculateDistance(departStop.Latitude, departStop.Longitude, arriveStop.Latitude, arriveStop.Longitude)
	
	// Generar geometría simple (puede mejorarse con más puntos intermedios)
	geometry := [][]float64{
		{originLon, originLat},
		{departStop.Longitude, departStop.Latitude},
	}
	
	// Agregar paradas intermedias si tienen coordenadas
	for _, stop := range stops[1 : len(stops)-1] {
		if stop.Latitude != 0 && stop.Longitude != 0 {
			geometry = append(geometry, []float64{stop.Longitude, stop.Latitude})
		}
	}
	
	geometry = append(geometry, []float64{arriveStop.Longitude, arriveStop.Latitude})
	geometry = append(geometry, []float64{destLon, destLat})
	
	// Crear leg de bus
	busLeg := TripLeg{
		Type:        "bus",
		Mode:        "Red",
		RouteNumber: routeNumber,
		From:        departStop.Name,
		To:          arriveStop.Name,
		Duration:    durationMinutes,
		Distance:    distance / 1000,
		Instruction: fmt.Sprintf("Toma el bus %s en %s. Bájate en %s (%d paradas)", 
			routeNumber, departStop.Name, arriveStop.Name, len(stops)),
		Geometry:    geometry,
		DepartStop:  &departStop,
		ArriveStop:  &arriveStop,
	}
	
	itinerary := &RouteItinerary{
		Origin:        Coordinate{Latitude: originLat, Longitude: originLon},
		Destination:   Coordinate{Latitude: destLat, Longitude: destLon},
		Legs:          []TripLeg{busLeg},
		RedBusRoutes:  []string{routeNumber},
		TotalDuration: durationMinutes,
		TotalDistance: distance / 1000,
		DepartureTime: now.Format("15:04"),
		ArrivalTime:   now.Add(time.Duration(durationMinutes) * time.Minute).Format("15:04"),
	}
	
	log.Printf("✅ Itinerario creado desde Moovit: %d legs, %d paradas", len(itinerary.Legs), len(stops))
	return itinerary
}

// NOTA: Geometría de rutas ahora se obtiene de GraphHopper
// Esta función ya no es necesaria - Moovit solo provee info de Red bus
// La geometría de calles se calcula en el frontend usando GraphHopper

