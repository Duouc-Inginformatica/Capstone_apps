package models

import "time"

// ScraperMetrics representa métricas de un proceso de scraping
type ScraperMetrics struct {
	ID              int64     `json:"id"`
	Source          string    `json:"source"`           // "moovit" o "redcl"
	StartedAt       time.Time `json:"startedAt"`
	CompletedAt     *time.Time `json:"completedAt,omitempty"`
	Status          string    `json:"status"`           // "running", "completed", "failed"
	LinksGenerated  int       `json:"linksGenerated"`   // Número de URLs generadas
	LinksProcessed  int       `json:"linksProcessed"`   // URLs procesadas exitosamente
	LinksFailed     int       `json:"linksFailed"`      // URLs que fallaron
	DataObtained    int       `json:"dataObtained"`     // Registros de datos obtenidos
	DataSaved       int       `json:"dataSaved"`        // Registros guardados en DB
	DurationSeconds int       `json:"durationSeconds"`  // Duración total en segundos
	ErrorMessage    *string   `json:"errorMessage,omitempty"`
	Metadata        *string   `json:"metadata,omitempty"` // JSON con datos adicionales
}

// ScraperLink representa un link procesado por el scraper
type ScraperLink struct {
	ID              int64     `json:"id"`
	MetricsID       int64     `json:"metricsId"`       // FK a ScraperMetrics
	URL             string    `json:"url"`
	Status          string    `json:"status"`          // "pending", "processing", "completed", "failed"
	AttemptCount    int       `json:"attemptCount"`
	DataExtracted   int       `json:"dataExtracted"`   // Cantidad de datos extraídos de este link
	ProcessedAt     *time.Time `json:"processedAt,omitempty"`
	ErrorMessage    *string   `json:"errorMessage,omitempty"`
	ResponseTime    int       `json:"responseTime"`    // Tiempo de respuesta en ms
}

// ScraperData representa un dato individual obtenido del scraping
type ScraperData struct {
	ID          int64     `json:"id"`
	LinkID      int64     `json:"linkId"`          // FK a ScraperLink
	DataType    string    `json:"dataType"`        // "route", "stop", "schedule", etc.
	RawData     string    `json:"rawData"`         // JSON crudo extraído
	ParsedData  *string   `json:"parsedData,omitempty"` // JSON parseado y validado
	IsSaved     bool      `json:"isSaved"`         // Si fue guardado en la tabla final
	CreatedAt   time.Time `json:"createdAt"`
}

// ScraperSummary representa un resumen agregado de métricas de scraping
type ScraperSummary struct {
	Source              string    `json:"source"`
	TotalRuns           int       `json:"totalRuns"`
	SuccessfulRuns      int       `json:"successfulRuns"`
	FailedRuns          int       `json:"failedRuns"`
	TotalLinksGenerated int       `json:"totalLinksGenerated"`
	TotalLinksProcessed int       `json:"totalLinksProcessed"`
	TotalDataObtained   int       `json:"totalDataObtained"`
	TotalDataSaved      int       `json:"totalDataSaved"`
	AverageDuration     float64   `json:"averageDuration"`     // Segundos
	LastRun             *time.Time `json:"lastRun,omitempty"`
	SuccessRate         float64   `json:"successRate"`         // Porcentaje
}

// ScraperPerformance representa métricas de rendimiento del scraper
type ScraperPerformance struct {
	Hour              int     `json:"hour"`              // 0-23
	LinksProcessed    int     `json:"linksProcessed"`
	AverageResponseMs int     `json:"averageResponseMs"`
	SuccessRate       float64 `json:"successRate"`
}
