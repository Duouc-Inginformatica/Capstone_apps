package redcl

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/chromedp"
)

// BusArrival representa un bus próximo a llegar a un paradero
type BusArrival struct {
	RouteNumber string  `json:"route_number"` // Número de ruta (ej: "430", "C01")
	DistanceKm  float64 `json:"distance_km"`  //距ancia en km
	JustPassed  bool    `json:"just_passed,omitempty"` // Indica si el bus acaba de pasar (desapareció)
}

// StopArrivals representa todos los buses que llegarán a un paradero
type StopArrivals struct {
	StopCode    string       `json:"stop_code"`      // Código del paradero (ej: "PC615")
	StopName    string       `json:"stop_name"`      // Nombre del paradero
	Arrivals    []BusArrival `json:"arrivals"`       // Lista de buses próximos
	BussesPassed []string    `json:"busses_passed,omitempty"` // Buses que pasaron recientemente
	LastUpdated time.Time    `json:"last_updated"`   // Timestamp de actualización
}

// busCache almacena el estado anterior de buses para detectar si pasaron
type busCache struct {
	RouteNumber string
	DistanceKm  float64
	LastSeen    time.Time
}

// Scraper obtiene información de llegadas desde Red.cl
type Scraper struct {
	db    *sql.DB
	cache map[string][]busCache // stopCode -> lista de buses vistos
	mu    sync.RWMutex
}

// NewScraper crea una nueva instancia del scraper de Red.cl
func NewScraper(db *sql.DB) *Scraper {
	return &Scraper{
		db:    db,
		cache: make(map[string][]busCache),
	}
}

// GetBusArrivals obtiene los buses próximos a llegar a un paradero específico
func (s *Scraper) GetBusArrivals(stopCode string) (*StopArrivals, error) {
	log.Printf("🚌 [RED.CL] Obteniendo llegadas para paradero %s", stopCode)

	// Limpiar código de paradero (quitar espacios, mayúsculas)
	stopCode = strings.ToUpper(strings.TrimSpace(stopCode))
	
	// URL CORRECTA de Red.cl para búsqueda de paradero
	url := fmt.Sprintf("https://www.red.cl/planifica-tu-viaje/cuando-llega/?codsimt=%s", stopCode)
	
	log.Printf("🌐 [RED.CL] URL: %s", url)

	// Detectar navegadores instalados (Chrome, Edge, Brave, Chromium)
	browserPaths := []struct {
		name string
		path string
	}{
		// Microsoft Edge (incluido por defecto en Windows 10/11)
		{"Edge", "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"},
		{"Edge", "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe"},
		
		// Google Chrome
		{"Chrome", "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"},
		{"Chrome", "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe"},
		{"Chrome", "C:\\Users\\" + getCurrentUser() + "\\AppData\\Local\\Google\\Chrome\\Application\\chrome.exe"},
		
		// Brave Browser
		{"Brave", "C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe"},
		{"Brave", "C:\\Program Files (x86)\\BraveSoftware\\Brave-Browser\\Application\\brave.exe"},
		{"Brave", "C:\\Users\\" + getCurrentUser() + "\\AppData\\Local\\BraveSoftware\\Brave-Browser\\Application\\brave.exe"},
		
		// Chromium
		{"Chromium", "C:\\Program Files\\Chromium\\Application\\chrome.exe"},
		{"Chromium", "C:\\Program Files (x86)\\Chromium\\Application\\chrome.exe"},
		{"Chromium", "C:\\Users\\" + getCurrentUser() + "\\AppData\\Local\\Chromium\\Application\\chrome.exe"},
	}

	// Configurar opciones headless (sin ventana visible)
	opts := []chromedp.ExecAllocatorOption{
		chromedp.NoFirstRun,
		chromedp.NoDefaultBrowserCheck,
		chromedp.Flag("headless", true),                    // HEADLESS: sin interfaz gráfica
		chromedp.Flag("disable-gpu", true),                 // Deshabilitar GPU
		chromedp.Flag("no-sandbox", true),                  // Sin sandbox (para servers)
		chromedp.Flag("disable-dev-shm-usage", true),       // Evitar problemas de memoria compartida
		chromedp.Flag("disable-extensions", true),          // Sin extensiones
		chromedp.Flag("disable-background-networking", true),
		chromedp.Flag("disable-sync", true),
		chromedp.Flag("disable-translate", true),
		chromedp.Flag("disable-plugins", true),
		chromedp.Flag("mute-audio", true),                  // Sin audio
		chromedp.Flag("disable-setuid-sandbox", true),
		chromedp.WindowSize(1920, 1080),                    // Tamaño de ventana virtual
		chromedp.UserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
	}

	// Buscar primer navegador disponible
	browserFound := false
	for _, browser := range browserPaths {
		if fileExists(browser.path) {
			opts = append([]chromedp.ExecAllocatorOption{chromedp.ExecPath(browser.path)}, opts...)
			log.Printf("✅ [BROWSER] %s detectado: %s", browser.name, browser.path)
			browserFound = true
			break
		}
	}

	if !browserFound {
		log.Printf("⚠️  [BROWSER] No se detectó navegador compatible, intentando chromedp default")
		opts = append(chromedp.DefaultExecAllocatorOptions[:], opts...)
	}

	allocCtx, cancelAlloc := chromedp.NewExecAllocator(context.Background(), opts...)
	defer cancelAlloc()

	// Crear contexto sin logging excesivo (modo silencioso)
	ctx, cancel := chromedp.NewContext(allocCtx)
	defer cancel()

	ctx, cancel = context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	var htmlContent string
	var stopName string

	log.Printf("🔄 [RED.CL] Iniciando scraping headless (sin ventana visible)...")

	err := chromedp.Run(ctx,
		chromedp.Navigate(url),
		chromedp.WaitVisible(`body`, chromedp.ByQuery),
		chromedp.Sleep(4*time.Second), // Esperar a que cargue JavaScript dinámico y datos AJAX
		chromedp.WaitReady(`table`, chromedp.ByQuery), // Esperar a que cargue la tabla de recorridos
		chromedp.OuterHTML(`html`, &htmlContent, chromedp.ByQuery),
	)

	if err != nil {
		log.Printf("❌ [RED.CL] Error navegando: %v", err)
		
		// Si el error es por navegador no encontrado, dar más detalles
		if strings.Contains(err.Error(), "executable file not found") {
			return nil, fmt.Errorf("no se encontró navegador compatible (Chrome/Edge/Brave). Instala uno de estos navegadores")
		}
		
		return nil, fmt.Errorf("error obteniendo datos de Red.cl: %w", err)
	}

	log.Printf("📄 [RED.CL] HTML obtenido: %d bytes", len(htmlContent))

	// Parsear HTML para extraer información
	arrivals := s.parseArrivals(htmlContent, stopCode)
	
	// Detectar buses que pasaron comparando con caché
	bussesPassed := s.detectPassedBuses(stopCode, arrivals)
	
	// Actualizar caché con buses actuales
	s.updateCache(stopCode, arrivals)
	
	// Intentar obtener nombre del paradero desde GTFS si está disponible
	if s.db != nil {
		stopName = s.getStopNameFromGTFS(stopCode)
	}
	
	if stopName == "" {
		stopName = s.extractStopNameFromHTML(htmlContent)
	}

	result := &StopArrivals{
		StopCode:     stopCode,
		StopName:     stopName,
		Arrivals:     arrivals,
		BussesPassed: bussesPassed,
		LastUpdated:  time.Now(),
	}

	if len(bussesPassed) > 0 {
		log.Printf("🚌 [PASSED] Buses que pasaron: %v", bussesPassed)
	}
	log.Printf("✅ [RED.CL] Encontradas %d llegadas para %s", len(arrivals), stopCode)
	
	return result, nil
}

// parseArrivals extrae información de buses desde el HTML de Red.cl
func (s *Scraper) parseArrivals(html, stopCode string) []BusArrival {
	arrivals := []BusArrival{}
	seenRoutes := make(map[string]bool) // Para evitar duplicados

	log.Printf("🔍 [PARSER] Iniciando parseo del HTML")

	// ESTRUCTURA HTML DE RED.CL:
	// <td class="td-dividido recorrido no-icon"><a class="bus">C01</a></td>
	// <td class="td-right tiempo-llegada">"0.3km <span>(Llegando.)</span>"</td>

	// Patrón para extraer filas completas de la tabla
	rowPattern := regexp.MustCompile(`(?s)<tr[^>]*>(.*?)</tr>`)
	rows := rowPattern.FindAllStringSubmatch(html, -1)

	log.Printf("🔍 [PARSER] Filas de tabla encontradas: %d", len(rows))

	for _, rowMatch := range rows {
		if len(rowMatch) < 2 {
			continue
		}
		rowHTML := rowMatch[1]

		// Extraer número de ruta (C01, C05, 409, etc.)
		routePattern := regexp.MustCompile(`class="bus[^"]*"[^>]*>([A-Z]?\d{2,3}[A-Z]?)</`)
		routeMatch := routePattern.FindStringSubmatch(rowHTML)
		if len(routeMatch) < 2 {
			continue
		}
		routeNumber := strings.TrimSpace(routeMatch[1])

		// Extraer distancia (0.3km, 7.4km, etc.)
		distancePattern := regexp.MustCompile(`(\d+\.?\d*)\s*km`)
		distanceMatch := distancePattern.FindStringSubmatch(rowHTML)
		
		var distanceKm float64
		if len(distanceMatch) >= 2 {
			distanceKm, _ = strconv.ParseFloat(distanceMatch[1], 64)
		}

		// Crear clave única para evitar duplicados
		routeKey := fmt.Sprintf("%s_%.1f", routeNumber, distanceKm)
		
		// Saltar si ya existe esta combinación exacta
		if seenRoutes[routeKey] {
			continue
		}
		seenRoutes[routeKey] = true

		// Saltar entradas sin datos válidos
		if routeNumber == "" || distanceKm == 0 {
			continue
		}

		arrival := BusArrival{
			RouteNumber: routeNumber,
			DistanceKm:  distanceKm,
		}

		arrivals = append(arrivals, arrival)
		log.Printf("  ✓ Bus: %s (%.1fkm)", routeNumber, distanceKm)
	}

	log.Printf("📊 [PARSER] Total parseado: %d llegadas únicas", len(arrivals))
	
	return arrivals
}

// tryExtractFromJSON intenta extraer datos de JSON embebido en el HTML (ya no usado)
func (s *Scraper) tryExtractFromJSON(html string) []BusArrival {
	arrivals := []BusArrival{}
	
	// Buscar datos JSON que puedan estar embebidos
	jsonPattern := regexp.MustCompile(`(?s)\{[^{}]*"route"[^{}]*\}`)
	matches := jsonPattern.FindAllString(html, -1)
	
	for _, match := range matches {
		var data map[string]interface{}
		if err := json.Unmarshal([]byte(match), &data); err == nil {
			// Intentar extraer información del JSON
			if route, ok := data["route"].(string); ok {
				arrival := BusArrival{
					RouteNumber: route,
				}
				
				if dist, ok := data["distance"].(float64); ok {
					arrival.DistanceKm = dist
				}
				
				arrivals = append(arrivals, arrival)
			}
		}
	}
	
	return arrivals
}

// extractStopNameFromHTML extrae el nombre del paradero desde el HTML
func (s *Scraper) extractStopNameFromHTML(html string) string {
	// Patrón para: "Paradero PC615" seguido del nombre
	// Ejemplo: <h2>Paradero PC615</h2> <p>Avenida Las Condes / esq. La Cabaña</p>
	namePattern := regexp.MustCompile(`(?s)Paradero\s+([A-Z]+\d+).*?<.*?>([^<]+)</`)
	if matches := namePattern.FindStringSubmatch(html); len(matches) > 2 {
		return strings.TrimSpace(matches[2])
	}
	
	// Patrón alternativo: buscar directamente en elementos que siguen al código
	codePattern := regexp.MustCompile(`(?i)` + regexp.QuoteMeta("PC615") + `.*?(?:esq\.|/)?\s*([^<]+)</`)
	if matches := codePattern.FindStringSubmatch(html); len(matches) > 1 {
		return strings.TrimSpace(matches[1])
	}
	
	return ""
}

// getStopNameFromGTFS obtiene el nombre del paradero desde la base GTFS
func (s *Scraper) getStopNameFromGTFS(stopCode string) string {
	if s.db == nil {
		return ""
	}

	var stopName string
	query := `SELECT stop_name FROM stops WHERE stop_code = ? LIMIT 1`
	
	err := s.db.QueryRow(query, stopCode).Scan(&stopName)
	if err != nil {
		if err != sql.ErrNoRows {
			log.Printf("⚠️ [GTFS] Error obteniendo nombre: %v", err)
		}
		return ""
	}

	return stopName
}

// detectPassedBuses detecta buses que desaparecieron (pasaron por el paradero)
func (s *Scraper) detectPassedBuses(stopCode string, currentArrivals []BusArrival) []string {
	s.mu.RLock()
	previousBuses := s.cache[stopCode]
	s.mu.RUnlock()

	if len(previousBuses) == 0 {
		return nil // Primera consulta, no hay comparación
	}

	passed := []string{}
	now := time.Now()

	// Crear mapa de buses actuales para búsqueda rápida
	currentBusMap := make(map[string]float64)
	for _, arrival := range currentArrivals {
		key := arrival.RouteNumber
		currentBusMap[key] = arrival.DistanceKm
	}

	// Verificar buses que estaban cerca y ahora desaparecieron
	for _, prevBus := range previousBuses {
		// Si el bus fue visto hace menos de 10 minutos
		if now.Sub(prevBus.LastSeen) > 10*time.Minute {
			continue
		}

		currentDistance, exists := currentBusMap[prevBus.RouteNumber]

		// CASO 1: Bus desapareció completamente (estaba a ≤ 2km)
		if !exists && prevBus.DistanceKm <= 2.0 {
			log.Printf("🚌 [PASSED] Bus %s desapareció (estaba a %.1fkm)", prevBus.RouteNumber, prevBus.DistanceKm)
			passed = append(passed, prevBus.RouteNumber)
			continue
		}

		// CASO 2: Bus ahora está mucho más lejos (reinició ruta o es otro bus)
		if exists && prevBus.DistanceKm <= 1.0 && currentDistance > 5.0 {
			log.Printf("🚌 [PASSED] Bus %s reinició (estaba a %.1fkm, ahora %.1fkm)", 
				prevBus.RouteNumber, prevBus.DistanceKm, currentDistance)
			passed = append(passed, prevBus.RouteNumber)
		}
	}

	return passed
}

// updateCache actualiza el caché de buses para un paradero
func (s *Scraper) updateCache(stopCode string, arrivals []BusArrival) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	newCache := make([]busCache, 0, len(arrivals))

	for _, arrival := range arrivals {
		newCache = append(newCache, busCache{
			RouteNumber: arrival.RouteNumber,
			DistanceKm:  arrival.DistanceKm,
			LastSeen:    now,
		})
	}

	s.cache[stopCode] = newCache

	// Limpiar caché viejo (> 15 minutos)
	s.cleanOldCache()
}

// cleanOldCache elimina entradas de caché antiguas
func (s *Scraper) cleanOldCache() {
	now := time.Now()
	for stopCode, buses := range s.cache {
		if len(buses) == 0 {
			continue
		}

		// Si todos los buses tienen más de 15 minutos, limpiar el paradero
		allOld := true
		for _, bus := range buses {
			if now.Sub(bus.LastSeen) <= 15*time.Minute {
				allOld = false
				break
			}
		}

		if allOld {
			delete(s.cache, stopCode)
			log.Printf("🧹 [CACHE] Limpiado caché antiguo de %s", stopCode)
		}
	}
}

// getCurrentUser obtiene el nombre del usuario actual
func getCurrentUser() string {
	user := os.Getenv("USERNAME")
	if user == "" {
		user = os.Getenv("USER") // Fallback para Linux/Mac
	}
	if user == "" {
		user = "user"
	}
	return user
}

// fileExists verifica si un archivo existe
func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// getEnv obtiene una variable de entorno con valor por defecto
func getEnv(key, defaultValue string) string {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	return value
}
