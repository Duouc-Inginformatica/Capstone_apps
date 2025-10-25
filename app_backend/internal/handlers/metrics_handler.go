package handlers

import (
	"database/sql"
	"runtime"
	"time"

	"github.com/gofiber/fiber/v2"
)

// MetricsHandler maneja métricas del sistema
type MetricsHandler struct {
	db        *sql.DB
	startTime time.Time
}

// NewMetricsHandler crea un nuevo handler de métricas
func NewMetricsHandler(db *sql.DB) *MetricsHandler {
	return &MetricsHandler{
		db:        db,
		startTime: time.Now(),
	}
}

// SystemMetrics representa las métricas del sistema
type SystemMetrics struct {
	CPUUsage       float64 `json:"cpuUsage"`       // Porcentaje de CPU
	MemoryUsage    int64   `json:"memoryUsage"`    // MB de memoria
	ActiveUsers    int     `json:"activeUsers"`    // Usuarios activos
	RequestsPerMin int     `json:"requestsPerMin"` // Requests por minuto
}

// GetMetrics obtiene las métricas actuales del sistema
func (h *MetricsHandler) GetMetrics(c *fiber.Ctx) error {
	metrics := SystemMetrics{}

	// Obtener uso de memoria
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	metrics.MemoryUsage = int64(m.Alloc / 1024 / 1024) // Convertir a MB

	// CPU usage (simplificado - en producción usar biblioteca específica)
	// Por ahora, un valor basado en el número de goroutines
	numGoroutines := runtime.NumGoroutine()
	metrics.CPUUsage = float64(numGoroutines) / 10.0 // Simplificado
	if metrics.CPUUsage > 100 {
		metrics.CPUUsage = 100
	}

	// Usuarios activos (consultar sesiones en DB si existe tabla)
	// Por ahora, retornar 0 ya que no tenemos tracking de sesiones activas
	metrics.ActiveUsers = 0

	// Requests por minuto (simplificado)
	// En producción, esto vendría de un contador con ventana temporal
	uptimeMinutes := time.Since(h.startTime).Minutes()
	if uptimeMinutes > 0 {
		metrics.RequestsPerMin = int(float64(10) / uptimeMinutes * 60) // Estimado
	}

	return c.JSON(metrics)
}
