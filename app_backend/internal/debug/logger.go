package debug

import (
	"log"
	"os"
	"time"
)

var (
	enabled = false
)

func init() {
	// Leer la variable de entorno LUNCH_WEB_DEBUG_DASHBOARD
	enabled = os.Getenv("LUNCH_WEB_DEBUG_DASHBOARD") == "true"
	if enabled {
		log.Println("🐛 Debug Dashboard habilitado")
	}
}

// IsEnabled retorna si el dashboard de debugging está habilitado
func IsEnabled() bool {
	return enabled
}

// LogDebug envía un log de nivel debug al dashboard
func LogDebug(message string, metadata map[string]interface{}) {
	if !enabled {
		return
	}
	SendLog("backend", "debug", message, metadata)
}

// LogInfo envía un log de nivel info al dashboard
func LogInfo(message string, metadata map[string]interface{}) {
	if !enabled {
		return
	}
	SendLog("backend", "info", message, metadata)
}

// LogWarn envía un log de nivel warn al dashboard
func LogWarn(message string, metadata map[string]interface{}) {
	if !enabled {
		return
	}
	SendLog("backend", "warn", message, metadata)
}

// LogError envía un log de nivel error al dashboard
func LogError(message string, metadata map[string]interface{}) {
	if !enabled {
		return
	}
	SendLog("backend", "error", message, metadata)
}

// UpdateMetrics envía métricas actualizadas al dashboard
func UpdateMetrics(cpuUsage, memoryUsage float64, activeUsers, apiRequests int) {
	if !enabled {
		return
	}

	metrics := []Metric{
		{Name: "CPU Usage", Value: cpuUsage, Unit: "%", Trend: getTrend(cpuUsage, 70)},
		{Name: "Memory", Value: memoryUsage, Unit: "MB", Trend: getTrend(memoryUsage, 1024)},
		{Name: "Active Users", Value: activeUsers, Trend: "stable"},
		{Name: "API Requests/min", Value: apiRequests, Trend: "stable"},
	}

	SendMetrics(metrics)
}

func getTrend(value, threshold float64) string {
	if value > threshold {
		return "up"
	} else if value < threshold*0.5 {
		return "down"
	}
	return "stable"
}

// UpdateApiStatus envía el estado de las APIs al dashboard
func UpdateApiStatus(backendStatus, graphhopperStatus, dbStatus string, ghResponseTime float64, dbConnections, dbMaxConnections int, version string) {
	if !enabled {
		return
	}

	var status ApiStatus
	status.Backend.Status = backendStatus
	status.Backend.ResponseTime = 0 // Se calcula automáticamente
	status.Backend.Version = version

	status.GraphHopper.Status = graphhopperStatus
	status.GraphHopper.ResponseTime = ghResponseTime

	status.Database.Status = dbStatus
	status.Database.Connections = dbConnections
	status.Database.MaxConnections = dbMaxConnections

	SendApiStatus(status)
}

// UpdateScrapingStatus envía el estado del scraping al dashboard
func UpdateScrapingStatus(moovitStatus, redCLStatus string, moovitLastRun, redCLLastRun time.Time, moovitProcessed, moovitErrors, redCLProcessed, redCLErrors int) {
	if !enabled {
		return
	}

	var status ScrapingStatus
	status.Moovit.Status = moovitStatus
	status.Moovit.LastRun = moovitLastRun.UnixMilli()
	status.Moovit.ItemsProcessed = moovitProcessed
	status.Moovit.Errors = moovitErrors

	status.RedCL.Status = redCLStatus
	status.RedCL.LastRun = redCLLastRun.UnixMilli()
	status.RedCL.ItemsProcessed = redCLProcessed
	status.RedCL.Errors = redCLErrors

	SendScrapingStatus(status)
}
