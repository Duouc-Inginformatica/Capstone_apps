package debug

import (
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/gofiber/websocket/v2"
)

// WebSocketHub maneja las conexiones WebSocket del dashboard de debugging
type WebSocketHub struct {
	clients    map[*websocket.Conn]bool
	broadcast  chan []byte
	register   chan *websocket.Conn
	unregister chan *websocket.Conn
	mu         sync.RWMutex
}

var (
	Hub *WebSocketHub
)

func init() {
	Hub = &WebSocketHub{
		broadcast:  make(chan []byte, 256),
		register:   make(chan *websocket.Conn),
		unregister: make(chan *websocket.Conn),
		clients:    make(map[*websocket.Conn]bool),
	}
	go Hub.run()
}

func (h *WebSocketHub) run() {
	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			h.clients[client] = true
			h.mu.Unlock()
			log.Printf("🔌 Dashboard conectado. Total clientes: %d", len(h.clients))

		case client := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[client]; ok {
				delete(h.clients, client)
				client.Close()
			}
			h.mu.Unlock()
			log.Printf("🔌 Dashboard desconectado. Total clientes: %d", len(h.clients))

		case message := <-h.broadcast:
			h.mu.RLock()
			for client := range h.clients {
				err := client.WriteMessage(websocket.TextMessage, message)
				if err != nil {
					log.Printf("Error enviando mensaje al dashboard: %v", err)
					client.Close()
					delete(h.clients, client)
				}
			}
			h.mu.RUnlock()
		}
	}
}

// HandleWebSocketFiber maneja las conexiones WebSocket de Fiber
func HandleWebSocketFiber(conn *websocket.Conn) {
	Hub.register <- conn

	// Leer mensajes del cliente (para comandos futuros)
	defer func() {
		Hub.unregister <- conn
	}()
	
	for {
		_, _, err := conn.ReadMessage()
		if err != nil {
			break
		}
	}
}

// LogMessage representa un mensaje de log para el dashboard
type LogMessage struct {
	Type     string                 `json:"type"`
	Source   string                 `json:"source"`
	Level    string                 `json:"level"`
	Message  string                 `json:"message"`
	Metadata map[string]interface{} `json:"metadata,omitempty"`
}

// SendLog envía un log al dashboard
func SendLog(source, level, message string, metadata map[string]interface{}) {
	if Hub == nil || len(Hub.clients) == 0 {
		return // No hay clientes conectados
	}

	msg := LogMessage{
		Type:     "log",
		Source:   source,
		Level:    level,
		Message:  message,
		Metadata: metadata,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Error al serializar log para dashboard: %v", err)
		return
	}

	select {
	case Hub.broadcast <- data:
	default:
		// Canal lleno, saltar mensaje
	}
}

// MetricsMessage representa métricas del sistema
type MetricsMessage struct {
	Type    string   `json:"type"`
	Metrics []Metric `json:"metrics"`
}

type Metric struct {
	Name  string      `json:"name"`
	Value interface{} `json:"value"`
	Unit  string      `json:"unit,omitempty"`
	Trend string      `json:"trend,omitempty"`
}

// SendMetrics envía métricas al dashboard
func SendMetrics(metrics []Metric) {
	if Hub == nil || len(Hub.clients) == 0 {
		return
	}

	msg := MetricsMessage{
		Type:    "metrics",
		Metrics: metrics,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Error al serializar métricas para dashboard: %v", err)
		return
	}

	select {
	case Hub.broadcast <- data:
	default:
	}
}

// ApiStatusMessage representa el estado de las APIs
type ApiStatusMessage struct {
	Type   string    `json:"type"`
	Status ApiStatus `json:"status"`
}

type ApiStatus struct {
	Backend struct {
		Status       string  `json:"status"`
		ResponseTime float64 `json:"responseTime"`
		Uptime       int64   `json:"uptime"`
		Version      string  `json:"version"`
	} `json:"backend"`
	GraphHopper struct {
		Status       string  `json:"status"`
		ResponseTime float64 `json:"responseTime"`
	} `json:"graphhopper"`
	Database struct {
		Status         string `json:"status"`
		Connections    int    `json:"connections"`
		MaxConnections int    `json:"maxConnections"`
	} `json:"database"`
}

var startTime = time.Now()

// SendApiStatus envía el estado de las APIs al dashboard
func SendApiStatus(status ApiStatus) {
	if Hub == nil || len(Hub.clients) == 0 {
		return
	}

	// Calcular uptime
	status.Backend.Uptime = int64(time.Since(startTime).Seconds())

	msg := ApiStatusMessage{
		Type:   "api_status",
		Status: status,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Error al serializar estado de API para dashboard: %v", err)
		return
	}

	select {
	case Hub.broadcast <- data:
	default:
	}
}

// ScrapingStatusMessage representa el estado del scraping
type ScrapingStatusMessage struct {
	Type   string          `json:"type"`
	Status ScrapingStatus `json:"status"`
}

type ScrapingStatus struct {
	Moovit struct {
		LastRun        int64  `json:"lastRun"`
		Status         string `json:"status"`
		ItemsProcessed int    `json:"itemsProcessed"`
		Errors         int    `json:"errors"`
	} `json:"moovit"`
	RedCL struct {
		LastRun        int64  `json:"lastRun"`
		Status         string `json:"status"`
		ItemsProcessed int    `json:"itemsProcessed"`
		Errors         int    `json:"errors"`
	} `json:"redCL"`
}

// SendScrapingStatus envía el estado del scraping al dashboard
func SendScrapingStatus(status ScrapingStatus) {
	if Hub == nil || len(Hub.clients) == 0 {
		return
	}

	msg := ScrapingStatusMessage{
		Type:   "scraping_status",
		Status: status,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Error al serializar estado de scraping para dashboard: %v", err)
		return
	}

	select {
	case Hub.broadcast <- data:
	default:
	}
}
