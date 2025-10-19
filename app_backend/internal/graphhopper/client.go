// ============================================================================
// GraphHopper Client & Manager - WayFindCL
// ============================================================================
// Cliente Go que MANEJA el proceso de GraphHopper como subproceso
// El backend inicia GraphHopper automáticamente al arrancar
// ============================================================================

package graphhopper

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

var (
	// Proceso de GraphHopper
	ghProcess *exec.Cmd
	ghRunning = false
)

// Cliente para GraphHopper API
type Client struct {
	baseURL    string
	httpClient *http.Client
}

// NewClient crea un nuevo cliente GraphHopper
func NewClient() *Client {
	baseURL := os.Getenv("GRAPHHOPPER_URL")
	if baseURL == "" {
		baseURL = "http://localhost:8989" // Default local
	}

	return &Client{
		baseURL: strings.TrimSuffix(baseURL, "/"),
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// ============================================================================
// GESTIÓN DEL PROCESO GRAPHHOPPER
// ============================================================================

// StartGraphHopperProcess inicia GraphHopper como subproceso
func StartGraphHopperProcess() error {
	if ghRunning {
		fmt.Println("⚠️  GraphHopper ya está ejecutándose")
		return nil
	}

	// Buscar JAR en múltiples ubicaciones posibles
	possiblePaths := []string{
		"./graphhopper-web-11.0.jar",
		"./bin/graphhopper-web-11.0.jar",
		"./graphhopper/graphhopper-web-11.0.jar",
		"./lib/graphhopper-web-11.0.jar",
	}

	var jarPath string
	for _, path := range possiblePaths {
		if _, err := os.Stat(path); err == nil {
			jarPath = path
			break
		}
	}

	if jarPath == "" {
		return fmt.Errorf("❌ GraphHopper JAR no encontrado en: %v", possiblePaths)
	}

	fmt.Printf("📦 GraphHopper JAR encontrado: %s\n", jarPath)

	// Verificar configuración y caché
	configPath := "./graphhopper-config.yml"
	graphCache := "./graph-cache"

	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		return fmt.Errorf("❌ Configuración no encontrada: %s", configPath)
	}

	if _, err := os.Stat(graphCache); os.IsNotExist(err) {
		return fmt.Errorf("❌ Graph cache no encontrado. Ejecuta primero: setup-graphhopper.ps1")
	}

	fmt.Println("🚀 Iniciando GraphHopper...")

	// Preparar comando para ejecutar en ventana separada de PowerShell
	// En Windows, usamos Start-Process para abrir una nueva terminal
	psCommand := fmt.Sprintf(
		`Start-Process powershell -ArgumentList '-NoExit','-Command','java -Xmx8g -Xms2g -jar %s server %s' -WindowStyle Normal`,
		jarPath, configPath,
	)
	
	ghProcess = exec.Command("powershell", "-Command", psCommand)

	// CRÍTICO: Configurar para que el proceso hijo tenga su propia ventana
	ghProcess.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | 0x00000010, // CREATE_NEW_CONSOLE
	}

	// Iniciar proceso (esto abrirá una nueva ventana de PowerShell)
	if err := ghProcess.Start(); err != nil {
		return fmt.Errorf("error iniciando GraphHopper: %w", err)
	}

	ghRunning = true
	fmt.Printf("✅ GraphHopper iniciado en ventana separada (PID: %d)\n", ghProcess.Process.Pid)
	fmt.Println("📝 Puedes ver los logs en la ventana de GraphHopper")

	// Esperar a que esté listo
	fmt.Print("⏳ Esperando que GraphHopper esté listo (esto puede tomar 2-3 minutos)")
	client := NewClient()
	maxRetries := 180 // 3 minutos max (suficiente para cargar Chile)
	for i := 0; i < maxRetries; i++ {
		if client.HealthCheck() == nil {
			fmt.Println(" ✅")
			fmt.Println("🎉 GraphHopper listo en http://localhost:8989")
			return nil
		}
		if i%10 == 0 {
			fmt.Print(".")
		}
		time.Sleep(1 * time.Second)
	}

	fmt.Println(" ⚠️")
	fmt.Println("⚠️  GraphHopper tardó más de lo esperado, pero sigue iniciando")
	fmt.Println("⚠️  Verifica la ventana de GraphHopper para ver el progreso")
	return nil // No fallar, solo advertir
}

// StopGraphHopperProcess detiene GraphHopper de forma segura
func StopGraphHopperProcess() error {
	if !ghRunning {
		return nil
	}

	fmt.Println("🛑 Deteniendo GraphHopper...")
	
	// Buscar todos los procesos Java (GraphHopper)
	// Usar taskkill para matar el árbol de procesos completo
	cmd := exec.Command("taskkill", "/F", "/IM", "java.exe", "/T")
	if err := cmd.Run(); err != nil {
		fmt.Printf("⚠️  Advertencia al detener GraphHopper: %v\n", err)
	}
	
	// También intentar cerrar nuestra referencia si existe
	if ghProcess != nil && ghProcess.Process != nil {
		ghProcess.Process.Kill()
		ghProcess = nil
	}

	ghRunning = false
	fmt.Println("✅ GraphHopper detenido correctamente")
	return nil
}

// ============================================================================
// ESTRUCTURAS DE DATOS
// ============================================================================

// RouteRequest representa una solicitud de ruta
type RouteRequest struct {
	Points    []Point   `json:"points"`
	Profile   string    `json:"profile"`   // "foot", "car", "pt"
	Locale    string    `json:"locale"`    // "es"
	PointsEncoded bool  `json:"points_encoded"`
	Instructions bool    `json:"instructions"`
	Details   []string  `json:"details,omitempty"`
	// Para transporte público
	PTEarliestDepartureTime *time.Time `json:"pt.earliest_departure_time,omitempty"`
	PTArriveBy              bool       `json:"pt.arrive_by,omitempty"`
	PTMaxWalkDistance       int        `json:"pt.max_walk_distance_per_leg,omitempty"`
	PTLimitSolutions        int        `json:"pt.limit_solutions,omitempty"`
}

// Point representa un punto geográfico
type Point struct {
	Lat float64 `json:"lat"`
	Lon float64 `json:"lon"`
}

// RouteResponse representa la respuesta de GraphHopper
type RouteResponse struct {
	Paths []Path            `json:"paths"`
	Info  map[string]interface{} `json:"info,omitempty"`
}

// Path representa una ruta calculada
type Path struct {
	Distance     float64       `json:"distance"`      // metros
	Time         int64         `json:"time"`          // milisegundos
	Transfers    int           `json:"transfers,omitempty"`
	Points       PointList     `json:"points"`
	Instructions []Instruction `json:"instructions"`
	Legs         []Leg         `json:"legs,omitempty"` // Para PT
	Details      map[string][][]interface{} `json:"details,omitempty"`
}

// PointList puede ser encoded polyline o array de coordenadas
type PointList struct {
	Type        string      `json:"type,omitempty"`
	Coordinates [][]float64 `json:"coordinates,omitempty"`
}

// Instruction representa una instrucción de navegación
type Instruction struct {
	Distance    float64 `json:"distance"`
	Heading     float64 `json:"heading,omitempty"`
	Sign        int     `json:"sign"`
	Interval    []int   `json:"interval"`
	Text        string  `json:"text"`
	Time        int64   `json:"time"`
	StreetName  string  `json:"street_name,omitempty"`
}

// Leg representa un segmento del viaje (para transporte público)
type Leg struct {
	Type            string      `json:"type"` // "walk", "pt"
	DepartureTime   int64       `json:"departure_time,omitempty"`
	ArrivalTime     int64       `json:"arrival_time,omitempty"`
	Distance        float64     `json:"distance"`
	Geometry        PointList   `json:"geometry"`
	Instructions    []Instruction `json:"instructions,omitempty"`
	// Para PT legs
	RouteID         string      `json:"route_id,omitempty"`
	TripID          string      `json:"trip_id,omitempty"`
	RouteShortName  string      `json:"route_short_name,omitempty"`
	RouteLongName   string      `json:"route_long_name,omitempty"`
	Headsign        string      `json:"headsign,omitempty"`
	Stops           []Stop      `json:"stops,omitempty"`
	NumStops        int         `json:"num_stops,omitempty"`
}

// Stop representa una parada de transporte público
type Stop struct {
	StopID         string  `json:"stop_id"`
	StopName       string  `json:"stop_name"`
	Lat            float64 `json:"lat"`
	Lon            float64 `json:"lon"`
	ArrivalTime    int64   `json:"arrival_time,omitempty"`
	DepartureTime  int64   `json:"departure_time,omitempty"`
	StopSequence   int     `json:"stop_sequence,omitempty"`
}

// ============================================================================
// MÉTODOS PRINCIPALES
// ============================================================================

// GetRoute obtiene una ruta entre dos puntos
func (c *Client) GetRoute(req RouteRequest) (*RouteResponse, error) {
	// Construir URL con parámetros
	u, err := url.Parse(c.baseURL + "/route")
	if err != nil {
		return nil, fmt.Errorf("error parsing URL: %w", err)
	}

	q := u.Query()
	
	// Puntos
	for _, p := range req.Points {
		q.Add("point", fmt.Sprintf("%f,%f", p.Lat, p.Lon))
	}
	
	// Parámetros básicos
	q.Set("profile", req.Profile)
	q.Set("locale", req.Locale)
	q.Set("points_encoded", fmt.Sprintf("%t", req.PointsEncoded))
	q.Set("instructions", fmt.Sprintf("%t", req.Instructions))
	
	// Details
	if len(req.Details) > 0 {
		for _, d := range req.Details {
			q.Add("details", d)
		}
	}
	
	// Parámetros de transporte público
	if req.PTEarliestDepartureTime != nil {
		q.Set("pt.earliest_departure_time", req.PTEarliestDepartureTime.Format(time.RFC3339))
	}
	if req.PTArriveBy {
		q.Set("pt.arrive_by", "true")
	}
	if req.PTMaxWalkDistance > 0 {
		q.Set("pt.max_walk_distance_per_leg", fmt.Sprintf("%d", req.PTMaxWalkDistance))
	}
	if req.PTLimitSolutions > 0 {
		q.Set("pt.limit_solutions", fmt.Sprintf("%d", req.PTLimitSolutions))
	}
	
	u.RawQuery = q.Encode()
	
	// Hacer request
	resp, err := c.httpClient.Get(u.String())
	if err != nil {
		return nil, fmt.Errorf("error making request: %w", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("GraphHopper error %d: %s", resp.StatusCode, string(body))
	}
	
	// Parsear respuesta
	var routeResp RouteResponse
	if err := json.NewDecoder(resp.Body).Decode(&routeResp); err != nil {
		return nil, fmt.Errorf("error decoding response: %w", err)
	}
	
	return &routeResp, nil
}

// GetFootRoute obtiene una ruta peatonal simple
func (c *Client) GetFootRoute(fromLat, fromLon, toLat, toLon float64) (*RouteResponse, error) {
	return c.GetRoute(RouteRequest{
		Points: []Point{
			{Lat: fromLat, Lon: fromLon},
			{Lat: toLat, Lon: toLon},
		},
		Profile:       "foot",
		Locale:        "es",
		PointsEncoded: false,
		Instructions:  true,
		Details:       []string{"street_name", "time", "distance"},
	})
}

// GetPublicTransitRoute obtiene ruta con transporte público
func (c *Client) GetPublicTransitRoute(
	fromLat, fromLon, toLat, toLon float64,
	departureTime time.Time,
	maxWalkDistance int,
) (*RouteResponse, error) {
	if maxWalkDistance == 0 {
		maxWalkDistance = 1000 // Default 1km
	}
	
	return c.GetRoute(RouteRequest{
		Points: []Point{
			{Lat: fromLat, Lon: fromLon},
			{Lat: toLat, Lon: toLon},
		},
		Profile:                 "pt",
		Locale:                  "es",
		PointsEncoded:           false,
		Instructions:            true,
		PTEarliestDepartureTime: &departureTime,
		PTMaxWalkDistance:       maxWalkDistance,
		PTLimitSolutions:        5, // Hasta 5 alternativas
	})
}

// HealthCheck verifica si GraphHopper está disponible
func (c *Client) HealthCheck() error {
	resp, err := c.httpClient.Get(c.baseURL + "/health")
	if err != nil {
		return fmt.Errorf("GraphHopper no disponible: %w", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GraphHopper health check failed: %d", resp.StatusCode)
	}
	
	return nil
}
