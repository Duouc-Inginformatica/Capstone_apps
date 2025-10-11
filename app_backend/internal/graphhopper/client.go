package graphhopper

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/yourorg/wayfindcl/internal/models"
)

// Options configures the GraphHopper client.
type Options struct {
	Profile         string
	Locale          string
	IncludeGeometry bool
	Timeout         time.Duration
}

// Client talks to a GraphHopper routing server.
type Client struct {
	baseURL    string
	apiKey     string
	profile    string
	locale     string
	geometry   bool
	httpClient *http.Client
}

// NewClient creates a GraphHopper client for the given base URL.
func NewClient(baseURL, apiKey string, opts Options) (*Client, error) {
	trimmed := strings.TrimSpace(baseURL)
	if trimmed == "" {
		return nil, errors.New("graphhopper: base url is required")
	}
	profile := opts.Profile
	if profile == "" {
		profile = "pt"
	}
	locale := opts.Locale
	if locale == "" {
		locale = "es"
	}
	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = 60 * time.Second
	}

	return &Client{
		baseURL:    strings.TrimRight(trimmed, "/"),
		apiKey:     strings.TrimSpace(apiKey),
		profile:    profile,
		locale:     locale,
		geometry:   opts.IncludeGeometry,
		httpClient: &http.Client{Timeout: timeout},
	}, nil
}

// PlanTransit requests a public transport route from GraphHopper.
func (c *Client) PlanTransit(ctx context.Context, req models.TransitRouteRequest) (*models.TransitRouteResponse, error) {
	fmt.Printf("DEBUG: Iniciando PlanTransit con origen: %+v, destino: %+v\n", req.Origin, req.Destination)
	fmt.Printf("DEBUG: Base URL configurada: %s\n", c.baseURL)
	fmt.Printf("DEBUG: API Key configurada: %s\n", c.apiKey)

	query := url.Values{}
	query.Add("profile", c.profile)
	query.Add("locale", c.locale)
	query.Add("calc_points", "true")
	includeGeom := c.geometry || req.IncludeGeometry
	if includeGeom {
		query.Add("points_encoded", "false")
	}
	query.Add("point", formatPoint(req.Origin))
	query.Add("point", formatPoint(req.Destination))
	if req.DepartureTime != nil {
		query.Add("earliest_departure_time", req.DepartureTime.UTC().Format("2006-01-02T15:04:05"))
	}
	if req.ArriveBy {
		query.Add("arrive_by", "true")
	}
	if c.apiKey != "" {
		query.Add("key", c.apiKey)
	}

	endpoint := fmt.Sprintf("%s/route?%s", c.baseURL, query.Encode())
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("graphhopper: build request: %w", err)
	}
	httpReq.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("graphhopper: request failed: %w", err)
	}
	defer resp.Body.Close()

	// Log para debugging
	fmt.Printf("GraphHopper Response Status: %d\n", resp.StatusCode)
	fmt.Printf("GraphHopper Request URL: %s\n", endpoint)

	decoder := json.NewDecoder(resp.Body)
	if resp.StatusCode >= 400 {
		var apiErr ghError
		if err := decoder.Decode(&apiErr); err != nil {
			return nil, fmt.Errorf("graphhopper: http %d", resp.StatusCode)
		}
		fmt.Printf("GraphHopper Error: %s\n", apiErr.Message)
		return nil, fmt.Errorf("graphhopper: %s", apiErr.Message)
	}

	var data ghResponse
	if err := decoder.Decode(&data); err != nil {
		return nil, fmt.Errorf("graphhopper: decode response: %w", err)
	}
	if len(data.Paths) == 0 {
		return nil, errors.New("graphhopper: no route found")
	}
	path := data.Paths[0]

	instructions := make([]models.TransitInstruction, len(path.Instructions))
	for i, inst := range path.Instructions {
		instructions[i] = models.TransitInstruction{
			Text:            inst.Text,
			DistanceMeters:  inst.Distance,
			DurationSeconds: inst.Time / 1000.0,
			Sign:            inst.Sign,
			StreetName:      inst.StreetName,
			Interval:        inst.Interval,
		}
	}

	respModel := &models.TransitRouteResponse{
		DistanceMeters:  path.Distance,
		DurationSeconds: float64(path.Time) / 1000.0,
		Instructions:    instructions,
	}

	if includeGeom && path.Points.Coordinates != nil {
		respModel.Geometry = path.Points.Coordinates
	}
	return respModel, nil
}

func formatPoint(p models.Coordinate) string {
	return fmt.Sprintf("%f,%f", p.Lat, p.Lon)
}

type ghError struct {
	Message string `json:"message"`
}

type ghResponse struct {
	Paths []ghPath `json:"paths"`
}

type ghPath struct {
	Distance     float64         `json:"distance"`
	Time         float64         `json:"time"`
	Points       ghPoints        `json:"points"`
	Instructions []ghInstruction `json:"instructions"`
}

type ghPoints struct {
	Type        string      `json:"type"`
	Coordinates [][]float64 `json:"coordinates"`
}

type ghInstruction struct {
	Text       string  `json:"text"`
	Distance   float64 `json:"distance"`
	Time       float64 `json:"time"`
	Sign       int     `json:"sign"`
	StreetName string  `json:"street_name"`
	Interval   []int   `json:"interval"`
}
