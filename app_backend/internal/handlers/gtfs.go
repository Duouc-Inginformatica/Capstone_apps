package handlers

import (
	"context"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/models"
)

const (
	defaultRadiusMeters = 400.0
	maxRadiusMeters     = 2000.0
	defaultStopsLimit   = 20
	maxStopsLimit       = 100
)

// SyncGTFS triggers a GTFS feed download and import.
func SyncGTFS(c *fiber.Ctx) error {
	if dbConn == nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "database not ready"})
	}
	if gtfsLoader == nil {
		return c.Status(fiber.StatusServiceUnavailable).JSON(models.ErrorResponse{Error: "GTFS loader not configured"})
	}

	gtfsSyncMu.Lock()
	defer gtfsSyncMu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute) // Aumentado a 30 minutos
	defer cancel()

	summary, err := gtfsLoader.Sync(ctx, dbConn)
	if err != nil {
		return c.Status(fiber.StatusBadGateway).JSON(models.ErrorResponse{Error: err.Error()})
	}

	gtfsSummaryMu.Lock()
	gtfsLastSummary = summary
	gtfsSummaryMu.Unlock()

	resp := models.GTFSSyncResponse{
		Message: "GTFS actualizado",
		Summary: models.GTFSSummary{
			FeedVersion:   summary.FeedVersion,
			StopsImported: summary.StopsImported,
			DownloadedAt:  summary.DownloadedAt,
			SourceURL:     summary.SourceURL,
		},
	}
	return c.Status(fiber.StatusOK).JSON(resp)
}

// GetNearbyStops returns stops close to a coordinate using the imported GTFS data.
func GetNearbyStops(c *fiber.Ctx) error {
	if dbConn == nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "database not ready"})
	}

	lat, err := strconv.ParseFloat(strings.TrimSpace(c.Query("lat")), 64)
	if err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "lat inválido"})
	}
	lon, err := strconv.ParseFloat(strings.TrimSpace(c.Query("lon")), 64)
	if err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "lon inválido"})
	}

	radius := defaultRadiusMeters
	if rStr := strings.TrimSpace(c.Query("radius")); rStr != "" {
		if r, err := strconv.ParseFloat(rStr, 64); err == nil && r > 0 {
			radius = math.Min(r, maxRadiusMeters)
		}
	}

	limit := defaultStopsLimit
	if lStr := strings.TrimSpace(c.Query("limit")); lStr != "" {
		if l, err := strconv.Atoi(lStr); err == nil && l > 0 {
			if l > maxStopsLimit {
				l = maxStopsLimit
			}
			limit = l
		}
	}

	minLat, maxLat, minLon, maxLon := boundingBox(lat, lon, radius)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := dbConn.QueryContext(ctx, `
        SELECT stop_id, code, name, description, latitude, longitude, zone_id, wheelchair_boarding
        FROM gtfs_stops
        WHERE latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?
    `, minLat, maxLat, minLon, maxLon)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "no se pudo consultar las paradas"})
	}
	defer rows.Close()

	stops := make([]models.Stop, 0)
	for rows.Next() {
		var stop models.Stop
		if err := rows.Scan(&stop.StopID, &stop.Code, &stop.Name, &stop.Description, &stop.Latitude, &stop.Longitude, &stop.ZoneID, &stop.WheelchairBoarding); err != nil {
			return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "error leyendo resultados"})
		}
		distance := haversineMeters(lat, lon, stop.Latitude, stop.Longitude)
		if distance <= radius {
			stop.DistanceMeters = distance
			stops = append(stops, stop)
		}
	}

	sort.Slice(stops, func(i, j int) bool {
		return stops[i].DistanceMeters < stops[j].DistanceMeters
	})
	if len(stops) > limit {
		stops = stops[:limit]
	}

	var lastUpdate *time.Time
	gtfsSummaryMu.RLock()
	if gtfsLastSummary != nil {
		lastUpdate = &gtfsLastSummary.DownloadedAt
	}
	gtfsSummaryMu.RUnlock()

	resp := models.NearbyStopsResponse{
		Count:      len(stops),
		Radius:     radius,
		Stops:      stops,
		LastUpdate: lastUpdate,
	}
	return c.Status(fiber.StatusOK).JSON(resp)
}

func boundingBox(lat, lon, radius float64) (minLat float64, maxLat float64, minLon float64, maxLon float64) {
	latDelta := radius / 111320.0
	latRad := lat * math.Pi / 180.0
	lonDelta := radius / (111320.0 * math.Cos(latRad))
	return lat - latDelta, lat + latDelta, lon - lonDelta, lon + lonDelta
}

func haversineMeters(lat1, lon1, lat2, lon2 float64) float64 {
	const earthRadius = 6371000.0
	dLat := degreesToRadians(lat2 - lat1)
	dLon := degreesToRadians(lon2 - lon1)
	a := math.Sin(dLat/2)*math.Sin(dLat/2) + math.Cos(degreesToRadians(lat1))*math.Cos(degreesToRadians(lat2))*math.Sin(dLon/2)*math.Sin(dLon/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
	return earthRadius * c
}

func degreesToRadians(deg float64) float64 {
	return deg * math.Pi / 180.0
}

// GetStopByCode busca un paradero por su código (ej: "PC1237")
func GetStopByCode(c *fiber.Ctx) error {
	if dbConn == nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "database not ready"})
	}

	code := strings.ToUpper(strings.TrimSpace(c.Params("code")))
	if code == "" {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "código de paradero requerido"})
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	var stop models.Stop
	err := dbConn.QueryRowContext(ctx, `
		SELECT stop_id, code, name, description, latitude, longitude, zone_id, wheelchair_boarding
		FROM gtfs_stops
		WHERE UPPER(stop_id) = ? OR UPPER(code) = ?
		LIMIT 1
	`, code, code).Scan(&stop.StopID, &stop.Code, &stop.Name, &stop.Description, 
		&stop.Latitude, &stop.Longitude, &stop.ZoneID, &stop.WheelchairBoarding)

	if err != nil {
		return c.Status(fiber.StatusNotFound).JSON(models.ErrorResponse{
			Error: "paradero no encontrado con código: " + code,
		})
	}

	return c.Status(fiber.StatusOK).JSON(stop)
}
