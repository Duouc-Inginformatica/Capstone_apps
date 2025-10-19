package models

import (
	"encoding/json"
	"fmt"
	"time"
)

// BusRoute representa una ruta de bus del sistema GTFS
type BusRoute struct {
	RouteID        string `json:"route_id" db:"route_id"`
	RouteShortName string `json:"route_short_name" db:"route_short_name"`
	RouteLongName  string `json:"route_long_name" db:"route_long_name"`
	RouteType      int    `json:"route_type" db:"route_type"`
}

// TransitLeg representa un segmento de viaje en transporte público
type TransitLeg struct {
	Type        string `json:"type"`                 // "walk", "pt" (public transport)
	Distance    int    `json:"distance"`             // en metros
	Time        int    `json:"time"`                 // en milisegundos
	Instruction string `json:"instruction"`          // instrucciones para el usuario
	RouteDesc   string `json:"route_desc,omitempty"` // descripción de la ruta (para buses)
}

// TransitPath representa una ruta completa de transporte público
type TransitPath struct {
	Time     int          `json:"time"`     // tiempo total en milisegundos
	Distance int          `json:"distance"` // distancia total en metros
	Legs     []TransitLeg `json:"legs"`     // segmentos del viaje
}

// FlexibleTime es un tipo personalizado que puede parsear múltiples formatos de fecha
type FlexibleTime struct {
	time.Time
}

// UnmarshalJSON implementa la interfaz json.Unmarshaler para parsing flexible de fechas
func (ft *FlexibleTime) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}

	// Lista de formatos de fecha a intentar
	formats := []string{
		time.RFC3339,                    // "2006-01-02T15:04:05Z07:00"
		time.RFC3339Nano,                // "2006-01-02T15:04:05.999999999Z07:00"
		"2006-01-02T15:04:05",           // Sin zona horaria
		"2006-01-02T15:04:05.999999",    // Con microsegundos sin zona horaria
		"2006-01-02T15:04:05.999999999", // Con nanosegundos sin zona horaria
		"2006-01-02T15:04:05Z",          // UTC sin offset
		"2006-01-02T15:04:05.999999Z",   // UTC con microsegundos
		"2006-01-02 15:04:05",           // Formato simple
	}

	var parseErr error
	for _, format := range formats {
		if t, err := time.Parse(format, s); err == nil {
			ft.Time = t
			// Si no tiene zona horaria, asumir UTC
			if ft.Time.Location() == time.UTC && !hasTimezone(s) {
				ft.Time = ft.Time.UTC()
			}
			return nil
		} else {
			parseErr = err
		}
	}

	return fmt.Errorf("unable to parse time %q with any known format: %v", s, parseErr)
}

// hasTimezone verifica si la cadena de tiempo incluye información de zona horaria
func hasTimezone(s string) bool {
	return len(s) > 19 && (s[len(s)-1:] == "Z" || s[len(s)-6:len(s)-3] == "+" || s[len(s)-6:len(s)-3] == "-")
}

// Coordinate represents a geographic coordinate in WGS84.
type Coordinate struct {
	Lat float64 `json:"lat"`
	Lon float64 `json:"lon"`
}

// TransitRouteRequest is the payload accepted by the routing endpoint.
type TransitRouteRequest struct {
	Origin          Coordinate    `json:"origin"`
	Destination     Coordinate    `json:"destination"`
	DepartureTime   *FlexibleTime `json:"departure_time,omitempty"`
	ArriveBy        bool          `json:"arrive_by,omitempty"`
	IncludeGeometry bool          `json:"include_geometry,omitempty"`
}

// TransitInstruction represents a single step within a transit route.
type TransitInstruction struct {
	Text            string  `json:"text"`
	DistanceMeters  float64 `json:"distance_meters"`
	DurationSeconds float64 `json:"duration_seconds"`
	Sign            int     `json:"sign"`
	StreetName      string  `json:"street_name,omitempty"`
	Interval        []int   `json:"interval,omitempty"`
}

// TransitRouteResponse is a simplified view of the GraphHopper response.
type TransitRouteResponse struct {
	DistanceMeters  float64              `json:"distance_meters"`
	DurationSeconds float64              `json:"duration_seconds"`
	Instructions    []TransitInstruction `json:"instructions"`
	Geometry        [][]float64          `json:"geometry,omitempty"`
	Raw             map[string]any       `json:"raw,omitempty"`
	Paths           []TransitPath        `json:"paths,omitempty"` // Para compatibilidad con GraphHopper
}
