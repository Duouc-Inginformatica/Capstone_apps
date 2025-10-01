package models

import "time"

// TripHistory representa el historial de un viaje
type TripHistory struct {
	ID              int64      `json:"id" db:"id"`
	UserID          int64      `json:"user_id" db:"user_id"`
	OriginLat       float64    `json:"origin_lat" db:"origin_lat"`
	OriginLon       float64    `json:"origin_lon" db:"origin_lon"`
	DestinationLat  float64    `json:"destination_lat" db:"destination_lat"`
	DestinationLon  float64    `json:"destination_lon" db:"destination_lon"`
	DestinationName string     `json:"destination_name" db:"destination_name"`
	DistanceMeters  float64    `json:"distance_meters" db:"distance_meters"`
	DurationSeconds int        `json:"duration_seconds" db:"duration_seconds"`
	BusRoute        *string    `json:"bus_route,omitempty" db:"bus_route"`
	RouteGeometry   *string    `json:"route_geometry,omitempty" db:"route_geometry"` // JSON encoded
	StartedAt       time.Time  `json:"started_at" db:"started_at"`
	CompletedAt     *time.Time `json:"completed_at,omitempty" db:"completed_at"`
	CreatedAt       time.Time  `json:"created_at" db:"created_at"`
}

// TripHistoryCreateRequest representa la solicitud para guardar un viaje
type TripHistoryCreateRequest struct {
	OriginLat       float64  `json:"origin_lat" validate:"required,latitude"`
	OriginLon       float64  `json:"origin_lon" validate:"required,longitude"`
	DestinationLat  float64  `json:"destination_lat" validate:"required,latitude"`
	DestinationLon  float64  `json:"destination_lon" validate:"required,longitude"`
	DestinationName string   `json:"destination_name" validate:"required"`
	DistanceMeters  float64  `json:"distance_meters" validate:"required,min=0"`
	DurationSeconds int      `json:"duration_seconds" validate:"required,min=0"`
	BusRoute        *string  `json:"bus_route,omitempty"`
	RouteGeometry   *string  `json:"route_geometry,omitempty"`
	StartedAt       string   `json:"started_at" validate:"required"`
	CompletedAt     *string  `json:"completed_at,omitempty"`
}

// FrequentLocation representa una ubicación visitada frecuentemente
type FrequentLocation struct {
	Name       string    `json:"name"`
	Latitude   float64   `json:"latitude"`
	Longitude  float64   `json:"longitude"`
	VisitCount int       `json:"visit_count"`
	FirstVisit time.Time `json:"first_visit"`
	LastVisit  time.Time `json:"last_visit"`
}

// TripStatistics representa estadísticas de viajes del usuario
type TripStatistics struct {
	TotalTrips          int                 `json:"total_trips"`
	TotalDistanceMeters float64             `json:"total_distance_meters"`
	TotalDurationSeconds int64              `json:"total_duration_seconds"`
	AverageDistanceMeters float64           `json:"average_distance_meters"`
	AverageDurationSeconds int              `json:"average_duration_seconds"`
	MostVisitedLocation *FrequentLocation   `json:"most_visited_location,omitempty"`
	FavoriteTimeOfDay   string              `json:"favorite_time_of_day"`
	FrequentLocations   []FrequentLocation  `json:"frequent_locations"`
}

// TripSuggestion representa una sugerencia de destino
type TripSuggestion struct {
	DestinationName string  `json:"destination_name"`
	Latitude        float64 `json:"latitude"`
	Longitude       float64 `json:"longitude"`
	Confidence      float64 `json:"confidence"` // 0.0 - 1.0
	Reason          string  `json:"reason"`
}
