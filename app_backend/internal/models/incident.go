package models

import "time"

// IncidentType representa el tipo de incidente reportado
type IncidentType string

const (
	IncidentBusFull          IncidentType = "bus_full"
	IncidentBusDelayed       IncidentType = "bus_delayed"
	IncidentBusNotRunning    IncidentType = "bus_not_running"
	IncidentStopOutOfService IncidentType = "stop_out_of_service"
	IncidentStopDamaged      IncidentType = "stop_damaged"
	IncidentUnsafeArea       IncidentType = "unsafe_area"
	IncidentAccessibility    IncidentType = "accessibility"
	IncidentOther            IncidentType = "other"
)

// IncidentSeverity representa la severidad del incidente
type IncidentSeverity string

const (
	SeverityLow      IncidentSeverity = "low"
	SeverityMedium   IncidentSeverity = "medium"
	SeverityHigh     IncidentSeverity = "high"
	SeverityCritical IncidentSeverity = "critical"
)

// Incident representa un incidente reportado por un usuario
type Incident struct {
	ID          int64            `json:"id" db:"id"`
	Type        IncidentType     `json:"type" db:"type"`
	Latitude    float64          `json:"latitude" db:"latitude"`
	Longitude   float64          `json:"longitude" db:"longitude"`
	Severity    IncidentSeverity `json:"severity" db:"severity"`
	ReporterID  string           `json:"reporter_id" db:"reporter_id"`
	RouteName   *string          `json:"route_name,omitempty" db:"route_name"`
	StopName    *string          `json:"stop_name,omitempty" db:"stop_name"`
	Description *string          `json:"description,omitempty" db:"description"`
	IsVerified  bool             `json:"is_verified" db:"is_verified"`
	Upvotes     int              `json:"upvotes" db:"upvotes"`
	Downvotes   int              `json:"downvotes" db:"downvotes"`
	CreatedAt   time.Time        `json:"created_at" db:"created_at"`
	UpdatedAt   time.Time        `json:"updated_at" db:"updated_at"`
}

// IncidentCreateRequest representa la solicitud para crear un incidente
type IncidentCreateRequest struct {
	Type        IncidentType     `json:"type" validate:"required"`
	Latitude    float64          `json:"latitude" validate:"required,latitude"`
	Longitude   float64          `json:"longitude" validate:"required,longitude"`
	Severity    IncidentSeverity `json:"severity" validate:"required"`
	RouteName   *string          `json:"route_name,omitempty"`
	StopName    *string          `json:"stop_name,omitempty"`
	Description *string          `json:"description,omitempty"`
}

// IncidentVoteRequest representa una votación en un incidente
type IncidentVoteRequest struct {
	VoteType string `json:"vote_type" validate:"required,oneof=upvote downvote"`
}

// IncidentStats representa estadísticas de incidentes
type IncidentStats struct {
	TotalIncidents  int                      `json:"total_incidents"`
	ByType          map[IncidentType]int     `json:"by_type"`
	BySeverity      map[IncidentSeverity]int `json:"by_severity"`
	VerifiedCount   int                      `json:"verified_count"`
	Last24Hours     int                      `json:"last_24_hours"`
	MostReportedRoute *string                `json:"most_reported_route,omitempty"`
}
