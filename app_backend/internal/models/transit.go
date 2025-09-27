package models

import "time"

// Coordinate represents a geographic coordinate in WGS84.
type Coordinate struct {
	Lat float64 `json:"lat"`
	Lon float64 `json:"lon"`
}

// TransitRouteRequest is the payload accepted by the routing endpoint.
type TransitRouteRequest struct {
	Origin          Coordinate `json:"origin"`
	Destination     Coordinate `json:"destination"`
	DepartureTime   *time.Time `json:"departure_time,omitempty"`
	ArriveBy        bool       `json:"arrive_by,omitempty"`
	IncludeGeometry bool       `json:"include_geometry,omitempty"`
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
}
