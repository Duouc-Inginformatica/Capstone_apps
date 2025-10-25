package handlers

import (
	"database/sql"
	"time"

	"github.com/gofiber/fiber/v2"
)

// StatusHandler maneja el estado completo del sistema
type StatusHandler struct {
	db        *sql.DB
	startTime time.Time
}

// NewStatusHandler crea un nuevo handler de status
func NewStatusHandler(db *sql.DB) *StatusHandler {
	return &StatusHandler{
		db:        db,
		startTime: time.Now(),
	}
}

// SystemStatus representa el estado completo del sistema
type SystemStatus struct {
	Backend     BackendStatus     `json:"backend"`
	GraphHopper GraphHopperStatus `json:"graphhopper"`
	Database    DatabaseStatus    `json:"database"`
}

// BackendStatus representa el estado del backend
type BackendStatus struct {
	Status       string  `json:"status"`
	ResponseTime int     `json:"responseTime"`
	Uptime       int64   `json:"uptime"`
	Version      string  `json:"version"`
}

// GraphHopperStatus representa el estado de GraphHopper
type GraphHopperStatus struct {
	Status       string `json:"status"`
	ResponseTime int    `json:"responseTime"`
}

// DatabaseStatus representa el estado de la base de datos
type DatabaseStatus struct {
	Status         string `json:"status"`
	Connections    int    `json:"connections"`
	MaxConnections int    `json:"maxConnections"`
}

// GetStatus obtiene el estado completo del sistema
func (h *StatusHandler) GetStatus(c *fiber.Ctx) error {
	startRequest := time.Now()
	
	status := SystemStatus{
		Backend: BackendStatus{
			Status:       "online",
			ResponseTime: 0,
			Uptime:       int64(time.Since(h.startTime).Seconds()),
			Version:      "1.0.0",
		},
		GraphHopper: GraphHopperStatus{
			Status:       "unknown",
			ResponseTime: 0,
		},
		Database: DatabaseStatus{
			Status:         "unknown",
			Connections:    0,
			MaxConnections: 100,
		},
	}

	// Verificar conexión a la base de datos
	if h.db != nil {
		err := h.db.Ping()
		if err == nil {
			status.Database.Status = "online"
			
			// Obtener estadísticas de conexión
			stats := h.db.Stats()
			status.Database.Connections = stats.InUse
			status.Database.MaxConnections = stats.MaxOpenConnections
		} else {
			status.Database.Status = "offline"
		}
	} else {
		status.Database.Status = "offline"
	}

	// Verificar GraphHopper
	ghStart := time.Now()
	if ghClient != nil {
		err := ghClient.HealthCheck()
		if err == nil {
			status.GraphHopper.Status = "online"
			status.GraphHopper.ResponseTime = int(time.Since(ghStart).Milliseconds())
		} else {
			status.GraphHopper.Status = "offline"
		}
	} else {
		status.GraphHopper.Status = "offline"
	}

	// Calcular tiempo de respuesta del backend
	status.Backend.ResponseTime = int(time.Since(startRequest).Milliseconds())

	return c.JSON(status)
}
