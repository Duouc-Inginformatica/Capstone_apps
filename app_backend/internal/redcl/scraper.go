package redcl

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

// BusArrival representa un bus próximo a llegar a un paradero
type BusArrival struct {
	RouteNumber      string  `json:"route_number"`       // Número de ruta (ej: "430", "C01")
	Direction        string  `json:"direction"`          // Dirección/destino del bus
	DistanceKm       float64 `json:"distance_km"`        // Distancia en km
	EstimatedMinutes int     `json:"estimated_minutes"`  // Minutos estimados
	EstimatedTime    string  `json:"estimated_time"`     // Hora estimada (ej: "21:35")
	Status           string  `json:"status"`             // "Llegando", "En camino", etc.
}

// StopArrivals representa todos los buses que llegarán a un paradero
type StopArrivals struct {
	StopCode string       `json:"stop_code"`  // Código del paradero (ej: "PC615")
	StopName string       `json:"stop_name"`  // Nombre del paradero
	Arrivals []BusArrival `json:"arrivals"`   // Lista de buses próximos
	LastUpdated time.Time `json:"last_updated"` // Timestamp de actualización
}

// Scraper obtiene información de llegadas desde Red.cl
type Scraper struct {
	db *sql.DB
}

// NewScraper crea una nueva instancia del scraper de Red.cl
func NewScraper(db *sql.DB) *Scraper {
	return &Scraper{
		db: db,
	}
}

// GetBusArrivals obtiene los buses próximos a llegar a un paradero específico
func (s *Scraper) GetBusArrivals(stopCode string) (*StopArrivals, error) {
	log.Printf("🚌 [RED.CL] Obteniendo llegadas para paradero %s", stopCode)

	// Limpiar código de paradero (quitar espacios, mayúsculas)
	stopCode = strings.ToUpper(strings.TrimSpace(stopCode))
	
	// URL de Red.cl para búsqueda de paradero
	url := fmt.Sprintf("https://www.red.cl/planifica-tu-viaje/cuando-llega/paradero/%s", stopCode)
	
	log.Printf("🌐 [RED.CL] URL: %s", url)

	// Configurar Chrome headless
	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.Flag("headless", true),
		chromedp.Flag("disable-gpu", true),
		chromedp.Flag("no-sandbox", true),
		chromedp.Flag("disable-dev-shm-usage", true),
		chromedp.UserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
	)

	allocCtx, cancelAlloc := chromedp.NewExecAllocator(context.Background(), opts...)
	defer cancelAlloc()

	ctx, cancel := chromedp.NewContext(allocCtx)
	defer cancel()

	ctx, cancel = context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	var htmlContent string
	var stopName string

	err := chromedp.Run(ctx,
		chromedp.Navigate(url),
		chromedp.WaitVisible(`body`, chromedp.ByQuery),
		chromedp.Sleep(2*time.Second), // Esperar a que cargue JavaScript
		chromedp.OuterHTML(`html`, &htmlContent, chromedp.ByQuery),
	)

	if err != nil {
		log.Printf("❌ [RED.CL] Error navegando: %v", err)
		return nil, fmt.Errorf("error obteniendo datos de Red.cl: %w", err)
	}

	log.Printf("📄 [RED.CL] HTML obtenido: %d bytes", len(htmlContent))

	// Parsear HTML para extraer información
	arrivals := s.parseArrivals(htmlContent, stopCode)
	
	// Intentar obtener nombre del paradero desde GTFS si está disponible
	if s.db != nil {
		stopName = s.getStopNameFromGTFS(stopCode)
	}
	
	if stopName == "" {
		stopName = s.extractStopNameFromHTML(htmlContent)
	}

	result := &StopArrivals{
		StopCode:    stopCode,
		StopName:    stopName,
		Arrivals:    arrivals,
		LastUpdated: time.Now(),
	}

	log.Printf("✅ [RED.CL] Encontradas %d llegadas para %s", len(arrivals), stopCode)
	
	return result, nil
}

// parseArrivals extrae información de buses desde el HTML de Red.cl
func (s *Scraper) parseArrivals(html, stopCode string) []BusArrival {
	arrivals := []BusArrival{}

	// PATRÓN 1: Extraer filas de recorridos
	// Buscar patrones como: C01, C05, 430, etc. con distancia y tiempo
	
	// Regex para capturar número de ruta
	routePattern := regexp.MustCompile(`(?i)([A-Z]?\d{2,3}[A-Z]?)`)
	
	// Regex para capturar distancia: "5.1km", "0.1km"
	distancePattern := regexp.MustCompile(`(\d+\.?\d*)\s*km`)
	
	// Regex para capturar tiempo: "Entre 13 y 17 min.", "05 y 07 min."
	timePattern := regexp.MustCompile(`(?i)Entre\s+(\d+)\s+y\s+(\d+)\s+min`)
	timePattern2 := regexp.MustCompile(`(?i)(\d+)\s+min`)
	
	// Regex para capturar dirección: "Hacia XXX"
	directionPattern := regexp.MustCompile(`(?i)Hacia\s+([^<]+?)(?:\s*</|\s*$)`)

	// Dividir HTML en secciones por recorrido
	// Buscar elementos que contengan información de buses
	recorridoSections := regexp.MustCompile(`(?s)<div[^>]*recorrido[^>]*>.*?</div>`).FindAllString(html, -1)
	
	if len(recorridoSections) == 0 {
		// Intentar otro patrón: buscar por bloques de información
		log.Printf("⚠️ [RED.CL] No se encontraron secciones con clase 'recorrido', buscando patrones alternativos")
		
		// Buscar todo el contenido y extraer información de forma más liberal
		lines := strings.Split(html, "\n")
		
		var currentRoute string
		var currentDistance float64
		var currentTime int
		var currentDirection string
		
		for _, line := range lines {
			// Buscar número de ruta
			if routeMatches := routePattern.FindStringSubmatch(line); len(routeMatches) > 0 {
				currentRoute = routeMatches[1]
			}
			
			// Buscar distancia
			if distMatches := distancePattern.FindStringSubmatch(line); len(distMatches) > 0 {
				if dist, err := strconv.ParseFloat(distMatches[1], 64); err == nil {
					currentDistance = dist
				}
			}
			
			// Buscar tiempo
			if timeMatches := timePattern.FindStringSubmatch(line); len(timeMatches) > 0 {
				// Tomar promedio entre min y max
				minTime, _ := strconv.Atoi(timeMatches[1])
				maxTime, _ := strconv.Atoi(timeMatches[2])
				currentTime = (minTime + maxTime) / 2
			} else if timeMatches2 := timePattern2.FindStringSubmatch(line); len(timeMatches2) > 0 {
				currentTime, _ = strconv.Atoi(timeMatches2[1])
			}
			
			// Buscar dirección
			if dirMatches := directionPattern.FindStringSubmatch(line); len(dirMatches) > 0 {
				currentDirection = strings.TrimSpace(dirMatches[1])
			}
			
			// Si tenemos ruta y al menos distancia o tiempo, crear entrada
			if currentRoute != "" && (currentDistance > 0 || currentTime > 0) {
				arrival := BusArrival{
					RouteNumber:      currentRoute,
					Direction:        currentDirection,
					DistanceKm:       currentDistance,
					EstimatedMinutes: currentTime,
					Status:           s.getStatusFromTime(currentTime),
				}
				
				arrivals = append(arrivals, arrival)
				
				// Reset para siguiente bus
				currentRoute = ""
				currentDistance = 0
				currentTime = 0
				currentDirection = ""
			}
		}
	}

	log.Printf("📊 [RED.CL] Parseadas %d llegadas", len(arrivals))
	
	// Si no se encontró nada, intentar con patrón JSON embebido
	if len(arrivals) == 0 {
		arrivals = s.tryExtractFromJSON(html)
	}

	return arrivals
}

// tryExtractFromJSON intenta extraer datos de JSON embebido en el HTML
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
				
				if time, ok := data["time"].(float64); ok {
					arrival.EstimatedMinutes = int(time)
					arrival.Status = s.getStatusFromTime(int(time))
				}
				
				arrivals = append(arrivals, arrival)
			}
		}
	}
	
	return arrivals
}

// extractStopNameFromHTML extrae el nombre del paradero desde el HTML
func (s *Scraper) extractStopNameFromHTML(html string) string {
	// Buscar patrón: "Paradero PCXXX - Nombre del paradero"
	namePattern := regexp.MustCompile(`(?i)Paradero\s+[A-Z]+\d+\s*[-/]\s*([^<]+)`)
	if matches := namePattern.FindStringSubmatch(html); len(matches) > 1 {
		return strings.TrimSpace(matches[1])
	}
	
	// Patrón alternativo
	namePattern2 := regexp.MustCompile(`(?i)<h1[^>]*>([^<]+)</h1>`)
	if matches := namePattern2.FindStringSubmatch(html); len(matches) > 1 {
		name := strings.TrimSpace(matches[1])
		// Limpiar "Paradero" del inicio si existe
		name = strings.TrimPrefix(name, "Paradero ")
		return name
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

// getStatusFromTime determina el estado basado en minutos estimados
func (s *Scraper) getStatusFromTime(minutes int) string {
	if minutes <= 2 {
		return "Llegando"
	} else if minutes <= 5 {
		return "Muy cerca"
	} else if minutes <= 10 {
		return "En camino"
	} else {
		return "Distante"
	}
}
