package handlers

import (
	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/debug"
)

// DebugLogRequest representa un log enviado desde la app Flutter
type DebugLogRequest struct {
	Source   string                 `json:"source"`   // "frontend" siempre para Flutter
	Level    string                 `json:"level"`    // debug, info, warn, error
	Message  string                 `json:"message"`
	Metadata map[string]interface{} `json:"metadata,omitempty"`
	UserID   *int                   `json:"userId,omitempty"`
}

// DebugEventRequest representa un evento de la app Flutter
type DebugEventRequest struct {
	EventType string                 `json:"eventType"` // navigation_start, navigation_step, bus_arrival, etc.
	Metadata  map[string]interface{} `json:"metadata"`
	UserID    *int                   `json:"userId,omitempty"`
}

// DebugErrorRequest representa un error capturado en Flutter
type DebugErrorRequest struct {
	ErrorType  string                 `json:"errorType"`  // runtime_error, network_error, etc.
	Message    string                 `json:"message"`
	StackTrace string                 `json:"stackTrace,omitempty"`
	Metadata   map[string]interface{} `json:"metadata,omitempty"`
	UserID     *int                   `json:"userId,omitempty"`
}

// DebugMetricsRequest representa métricas de la app Flutter
type DebugMetricsRequest struct {
	GPSAccuracy      float64 `json:"gpsAccuracy,omitempty"`
	TTSResponseTime  int     `json:"ttsResponseTime,omitempty"`  // ms
	APIResponseTime  int     `json:"apiResponseTime,omitempty"`  // ms
	NavigationActive bool    `json:"navigationActive"`
	UserID           *int    `json:"userId,omitempty"`
}

// ReceiveFlutterLog recibe logs desde la app Flutter y los reenvía al dashboard
func ReceiveFlutterLog(c *fiber.Ctx) error {
	if !debug.IsEnabled() {
		return c.JSON(fiber.Map{"status": "disabled"})
	}

	var req DebugLogRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	// Validar nivel de log
	validLevels := map[string]bool{"debug": true, "info": true, "warn": true, "error": true}
	if !validLevels[req.Level] {
		req.Level = "info"
	}

	// Agregar información adicional al metadata
	if req.Metadata == nil {
		req.Metadata = make(map[string]interface{})
	}
	if req.UserID != nil {
		req.Metadata["userId"] = *req.UserID
	}
	req.Metadata["platform"] = "flutter"

	// Enviar al dashboard
	debug.SendLog("frontend", req.Level, req.Message, req.Metadata)

	return c.JSON(fiber.Map{"status": "ok"})
}

// ReceiveFlutterEvent recibe eventos desde la app Flutter
func ReceiveFlutterEvent(c *fiber.Ctx) error {
	if !debug.IsEnabled() {
		return c.JSON(fiber.Map{"status": "disabled"})
	}

	var req DebugEventRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	// Agregar información adicional
	if req.Metadata == nil {
		req.Metadata = make(map[string]interface{})
	}
	if req.UserID != nil {
		req.Metadata["userId"] = *req.UserID
	}
	req.Metadata["platform"] = "flutter"
	req.Metadata["eventType"] = req.EventType

	// Determinar nivel de log basado en el tipo de evento
	level := "info"
	if req.EventType == "error" || req.EventType == "navigation_error" {
		level = "error"
	} else if req.EventType == "warning" {
		level = "warn"
	}

	message := "Event: " + req.EventType
	debug.SendLog("frontend", level, message, req.Metadata)

	return c.JSON(fiber.Map{"status": "ok"})
}

// ReceiveFlutterError recibe errores desde la app Flutter
func ReceiveFlutterError(c *fiber.Ctx) error {
	if !debug.IsEnabled() {
		return c.JSON(fiber.Map{"status": "disabled"})
	}

	var req DebugErrorRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	// Agregar información adicional
	if req.Metadata == nil {
		req.Metadata = make(map[string]interface{})
	}
	if req.UserID != nil {
		req.Metadata["userId"] = *req.UserID
	}
	req.Metadata["platform"] = "flutter"
	req.Metadata["errorType"] = req.ErrorType
	if req.StackTrace != "" {
		req.Metadata["stackTrace"] = req.StackTrace
	}

	message := "[" + req.ErrorType + "] " + req.Message
	debug.SendLog("frontend", "error", message, req.Metadata)

	return c.JSON(fiber.Map{"status": "ok"})
}

// ReceiveFlutterMetrics recibe métricas desde la app Flutter
func ReceiveFlutterMetrics(c *fiber.Ctx) error {
	if !debug.IsEnabled() {
		return c.JSON(fiber.Map{"status": "disabled"})
	}

	var req DebugMetricsRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	// Crear metadata con las métricas
	metadata := map[string]interface{}{
		"platform":         "flutter",
		"navigationActive": req.NavigationActive,
	}
	if req.UserID != nil {
		metadata["userId"] = *req.UserID
	}
	if req.GPSAccuracy > 0 {
		metadata["gpsAccuracy"] = req.GPSAccuracy
	}
	if req.TTSResponseTime > 0 {
		metadata["ttsResponseTime"] = req.TTSResponseTime
	}
	if req.APIResponseTime > 0 {
		metadata["apiResponseTime"] = req.APIResponseTime
	}

	debug.SendLog("frontend", "info", "App metrics update", metadata)

	return c.JSON(fiber.Map{"status": "ok"})
}

// NavigationEventRequest representa eventos específicos de navegación
type NavigationEventRequest struct {
	EventType       string  `json:"eventType"` // navigation_start, step_completed, arrival, etc.
	CurrentStep     int     `json:"currentStep,omitempty"`
	TotalSteps      int     `json:"totalSteps,omitempty"`
	DistanceRemain  float64 `json:"distanceRemaining,omitempty"`
	CurrentLat      float64 `json:"currentLat,omitempty"`
	CurrentLng      float64 `json:"currentLng,omitempty"`
	BusRoute        string  `json:"busRoute,omitempty"`
	StopName        string  `json:"stopName,omitempty"`
	UserID          *int    `json:"userId,omitempty"`
}

// ReceiveNavigationEvent recibe eventos de navegación desde Flutter
func ReceiveNavigationEvent(c *fiber.Ctx) error {
	if !debug.IsEnabled() {
		return c.JSON(fiber.Map{"status": "disabled"})
	}

	var req NavigationEventRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	metadata := map[string]interface{}{
		"platform":  "flutter",
		"eventType": req.EventType,
	}

	if req.UserID != nil {
		metadata["userId"] = *req.UserID
	}
	if req.CurrentStep > 0 {
		metadata["currentStep"] = req.CurrentStep
	}
	if req.TotalSteps > 0 {
		metadata["totalSteps"] = req.TotalSteps
	}
	if req.DistanceRemain > 0 {
		metadata["distanceRemaining"] = req.DistanceRemain
	}
	if req.CurrentLat != 0 && req.CurrentLng != 0 {
		metadata["currentPosition"] = map[string]float64{
			"lat": req.CurrentLat,
			"lng": req.CurrentLng,
		}
	}
	if req.BusRoute != "" {
		metadata["busRoute"] = req.BusRoute
	}
	if req.StopName != "" {
		metadata["stopName"] = req.StopName
	}

	message := "🧭 Navigation: " + req.EventType
	debug.SendLog("frontend", "info", message, metadata)

	return c.JSON(fiber.Map{"status": "ok"})
}
