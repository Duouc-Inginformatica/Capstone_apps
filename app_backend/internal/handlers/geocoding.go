// ============================================================================
// Geocoding Handler - WayFindCL
// ============================================================================
// Endpoint para buscar lugares por nombre usando Nominatim (OpenStreetMap)
// ============================================================================

package handlers

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
)

// NominatimResult representa un resultado de búsqueda de Nominatim
type NominatimResult struct {
	PlaceID     int      `json:"place_id"`
	Lat         string   `json:"lat"`
	Lon         string   `json:"lon"`
	DisplayName string   `json:"display_name"`
	Type        string   `json:"type"`
	Importance  float64  `json:"importance"`
	BoundingBox []string `json:"boundingbox"`
}

// GeocodeResult es el formato que retornamos al frontend
type GeocodeResult struct {
	Lat         float64 `json:"lat"`
	Lon         float64 `json:"lon"`
	DisplayName string  `json:"display_name"`
	Type        string  `json:"type"`
	Importance  float64 `json:"importance"`
}

var (
	nominatimClient = &http.Client{
		Timeout: 10 * time.Second,
	}
)

// ============================================================================
// ENDPOINT: GET /api/geocode/search
// ============================================================================
// Busca un lugar por nombre usando Nominatim
// Query params:
//   - q: texto de búsqueda (ej: "costanera center")
//   - limit: máximo resultados (default: 5)
//   - bounded: limitar a Santiago (default: true)
// ============================================================================
func GeocodeSearch(c *fiber.Ctx) error {
	query := c.Query("q")
	if query == "" {
		return c.Status(400).JSON(fiber.Map{
			"error": "Parámetro 'q' requerido",
		})
	}

	// Límite de resultados
	limit := c.QueryInt("limit", 5)
	if limit > 10 {
		limit = 10 // Máximo 10 resultados
	}

	// Si bounded=true, limitar búsqueda a región de Santiago
	bounded := c.Query("bounded", "true") == "true"

	// Construir URL de Nominatim
	baseURL := "https://nominatim.openstreetmap.org/search"
	params := url.Values{}
	params.Add("q", query)
	params.Add("format", "json")
	params.Add("limit", fmt.Sprintf("%d", limit))
	params.Add("addressdetails", "1")
	params.Add("countrycodes", "cl") // Solo Chile

	// Si bounded=true, limitar a bounding box de Santiago
	if bounded {
		// Bounding box de Santiago: aproximadamente
		// South: -33.65, West: -70.85, North: -33.35, East: -70.45
		params.Add("bounded", "1")
		params.Add("viewbox", "-70.85,-33.35,-70.45,-33.65")
	}

	fullURL := fmt.Sprintf("%s?%s", baseURL, params.Encode())

	// Crear request con User-Agent (requerido por Nominatim)
	req, err := http.NewRequest("GET", fullURL, nil)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "Error creando request",
		})
	}
	req.Header.Set("User-Agent", "WayFindCL/1.0 (Accessible Navigation App)")

	// Ejecutar request
	resp, err := nominatimClient.Do(req)
	if err != nil {
		return c.Status(503).JSON(fiber.Map{
			"error": "Error conectando a servicio de geocoding",
			"details": err.Error(),
		})
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return c.Status(resp.StatusCode).JSON(fiber.Map{
			"error": fmt.Sprintf("Geocoding service retornó status %d", resp.StatusCode),
		})
	}

	// Leer respuesta
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "Error leyendo respuesta",
		})
	}

	// Parsear JSON
	var nominatimResults []NominatimResult
	if err := json.Unmarshal(body, &nominatimResults); err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "Error parseando respuesta de geocoding",
		})
	}

	// Convertir a formato interno
	results := make([]GeocodeResult, 0, len(nominatimResults))
	for _, nr := range nominatimResults {
		// Parsear lat/lon (vienen como strings)
		var lat, lon float64
		fmt.Sscanf(nr.Lat, "%f", &lat)
		fmt.Sscanf(nr.Lon, "%f", &lon)

		results = append(results, GeocodeResult{
			Lat:         lat,
			Lon:         lon,
			DisplayName: nr.DisplayName,
			Type:        nr.Type,
			Importance:  nr.Importance,
		})
	}

	// Si no hay resultados
	if len(results) == 0 {
		return c.JSON(fiber.Map{
			"results": []GeocodeResult{},
			"message": fmt.Sprintf("No se encontraron resultados para '%s'", query),
		})
	}

	return c.JSON(fiber.Map{
		"results": results,
		"query":   query,
		"count":   len(results),
	})
}

// ============================================================================
// ENDPOINT: GET /api/geocode/reverse
// ============================================================================
// Geocoding inverso: convierte lat/lon a nombre de lugar
// Query params:
//   - lat: latitud
//   - lon: longitud
// ============================================================================
func GeocodeReverse(c *fiber.Ctx) error {
	lat := c.QueryFloat("lat", 0)
	lon := c.QueryFloat("lon", 0)

	if lat == 0 || lon == 0 {
		return c.Status(400).JSON(fiber.Map{
			"error": "Parámetros 'lat' y 'lon' requeridos",
		})
	}

	// Construir URL de Nominatim para reverse geocoding
	baseURL := "https://nominatim.openstreetmap.org/reverse"
	params := url.Values{}
	params.Add("lat", fmt.Sprintf("%.6f", lat))
	params.Add("lon", fmt.Sprintf("%.6f", lon))
	params.Add("format", "json")
	params.Add("addressdetails", "1")

	fullURL := fmt.Sprintf("%s?%s", baseURL, params.Encode())

	// Crear request con User-Agent
	req, err := http.NewRequest("GET", fullURL, nil)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "Error creando request",
		})
	}
	req.Header.Set("User-Agent", "WayFindCL/1.0 (Accessible Navigation App)")

	// Ejecutar request
	resp, err := nominatimClient.Do(req)
	if err != nil {
		return c.Status(503).JSON(fiber.Map{
			"error": "Error conectando a servicio de geocoding",
			"details": err.Error(),
		})
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return c.Status(resp.StatusCode).JSON(fiber.Map{
			"error": fmt.Sprintf("Geocoding service retornó status %d", resp.StatusCode),
		})
	}

	// Leer y parsear respuesta
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "Error leyendo respuesta",
		})
	}

	var result map[string]interface{}
	if err := json.Unmarshal(body, &result); err != nil {
		return c.Status(500).JSON(fiber.Map{
			"error": "Error parseando respuesta",
		})
	}

	return c.JSON(fiber.Map{
		"display_name": result["display_name"],
		"address":      result["address"],
		"lat":          lat,
		"lon":          lon,
	})
}

// ============================================================================
// HELPER: Normalizar nombre de lugar para mejor búsqueda
// ============================================================================
func normalizeSearchQuery(query string) string {
	// Agregar "Santiago, Chile" si no está presente
	query = strings.TrimSpace(query)
	lowerQuery := strings.ToLower(query)

	if !strings.Contains(lowerQuery, "santiago") && !strings.Contains(lowerQuery, "chile") {
		query = fmt.Sprintf("%s, Santiago, Chile", query)
	}

	return query
}
