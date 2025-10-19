package models

import "time"

// Stop represents a public transport stop imported from GTFS.
type Stop struct {
	StopID             string  `json:"stop_id"`
	Code               string  `json:"code,omitempty"`
	Name               string  `json:"name"`
	Description        string  `json:"description,omitempty"`
	Latitude           float64 `json:"latitude"`
	Longitude          float64 `json:"longitude"`
	ZoneID             string  `json:"zone_id,omitempty"`
	WheelchairBoarding int     `json:"wheelchair_boarding"`
	DistanceMeters     float64 `json:"distance_meters,omitempty"`
}

// GTFSStop is an alias for Stop to match naming convention
type GTFSStop = Stop

// GTFSSummary contains metadata about the last imported feed.
type GTFSSummary struct {
	FeedVersion   string    `json:"feed_version,omitempty"`
	StopsImported int       `json:"stops_imported"`
	DownloadedAt  time.Time `json:"downloaded_at"`
	SourceURL     string    `json:"source_url"`
}

// GTFSSyncResponse is returned by the sync endpoint.
type GTFSSyncResponse struct {
	Message string      `json:"message"`
	Summary GTFSSummary `json:"summary"`
}

// NearbyStopsResponse wraps a list of stops around a coordinate.
type NearbyStopsResponse struct {
	Count      int        `json:"count"`
	Radius     float64    `json:"radius_meters"`
	Stops      []Stop     `json:"stops"`
	LastUpdate *time.Time `json:"last_update,omitempty"`
}
