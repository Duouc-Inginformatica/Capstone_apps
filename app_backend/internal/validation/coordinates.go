package validation

import (
	"fmt"
	"math"
)

// CoordinateError representa un error de validación de coordenadas
type CoordinateError struct {
	Field   string
	Value   float64
	Message string
}

func (e *CoordinateError) Error() string {
	return fmt.Sprintf("%s: %s (valor: %.6f)", e.Field, e.Message, e.Value)
}

// ValidateLatitude valida una coordenada de latitud
func ValidateLatitude(lat float64, fieldName string) error {
	if math.IsNaN(lat) {
		return &CoordinateError{
			Field:   fieldName,
			Value:   lat,
			Message: "valor NaN no permitido",
		}
	}
	
	if math.IsInf(lat, 0) {
		return &CoordinateError{
			Field:   fieldName,
			Value:   lat,
			Message: "valor infinito no permitido",
		}
	}
	
	if lat < -90 || lat > 90 {
		return &CoordinateError{
			Field:   fieldName,
			Value:   lat,
			Message: "debe estar entre -90 y 90",
		}
	}
	
	return nil
}

// ValidateLongitude valida una coordenada de longitud
func ValidateLongitude(lon float64, fieldName string) error {
	if math.IsNaN(lon) {
		return &CoordinateError{
			Field:   fieldName,
			Value:   lon,
			Message: "valor NaN no permitido",
		}
	}
	
	if math.IsInf(lon, 0) {
		return &CoordinateError{
			Field:   fieldName,
			Value:   lon,
			Message: "valor infinito no permitido",
		}
	}
	
	if lon < -180 || lon > 180 {
		return &CoordinateError{
			Field:   fieldName,
			Value:   lon,
			Message: "debe estar entre -180 y 180",
		}
	}
	
	return nil
}

// ValidateCoordinatePair valida un par de coordenadas (lat, lon)
func ValidateCoordinatePair(lat, lon float64, prefix string) error {
	if err := ValidateLatitude(lat, prefix+"_lat"); err != nil {
		return err
	}
	
	if err := ValidateLongitude(lon, prefix+"_lon"); err != nil {
		return err
	}
	
	return nil
}

// ValidateSantiagoRegion valida que las coordenadas estén dentro de la región de Santiago
// Aproximadamente: Lat -34.0 a -33.0, Lon -71.2 a -70.0
func ValidateSantiagoRegion(lat, lon float64) error {
	const (
		minLat = -34.0
		maxLat = -33.0
		minLon = -71.2
		maxLon = -70.0
	)
	
	if lat < minLat || lat > maxLat {
		return &CoordinateError{
			Field:   "latitude",
			Value:   lat,
			Message: fmt.Sprintf("fuera del rango de Santiago (%.1f a %.1f)", minLat, maxLat),
		}
	}
	
	if lon < minLon || lon > maxLon {
		return &CoordinateError{
			Field:   "longitude",
			Value:   lon,
			Message: fmt.Sprintf("fuera del rango de Santiago (%.1f a %.1f)", minLon, maxLon),
		}
	}
	
	return nil
}

// IsZeroCoordinate verifica si una coordenada es (0, 0)
func IsZeroCoordinate(lat, lon float64) bool {
	return lat == 0 && lon == 0
}
