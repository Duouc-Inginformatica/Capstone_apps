package handlers

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/models"
)

// PlanTransit handles POST /api/route/transit to fetch a route from GraphHopper.
func PlanTransit(c *fiber.Ctx) error {
	fmt.Printf("DEBUG: PlanTransit llamado, hopperClient es nil: %t\n", hopperClient == nil)

	if hopperClient == nil {
		return c.Status(fiber.StatusServiceUnavailable).JSON(models.ErrorResponse{Error: "GraphHopper no configurado"})
	}

	var req models.TransitRouteRequest
	if err := c.BodyParser(&req); err != nil {
		fmt.Printf("DEBUG: Error parsing JSON body: %v\n", err)
		fmt.Printf("DEBUG: Raw body: %s\n", string(c.Body()))
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "json inválido: " + err.Error()})
	}

	fmt.Printf("DEBUG: Request parsed successfully: %+v\n", req)

	// Logging específico para la fecha
	if req.DepartureTime != nil {
		fmt.Printf("DEBUG: DepartureTime parsed successfully: %s (UTC: %s)\n",
			req.DepartureTime.Time.Format(time.RFC3339),
			req.DepartureTime.Time.UTC().Format(time.RFC3339))
	} else {
		fmt.Printf("DEBUG: No departure time provided\n")
	}

	if err := validateCoordinate(req.Origin); err != nil {
		fmt.Printf("DEBUG: Invalid origin coordinate: %+v, error: %v\n", req.Origin, err)
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "origen inválido: " + err.Error()})
	}
	if err := validateCoordinate(req.Destination); err != nil {
		fmt.Printf("DEBUG: Invalid destination coordinate: %+v, error: %v\n", req.Destination, err)
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "destino inválido: " + err.Error()})
	}

	fmt.Printf("DEBUG: Coordinates validated successfully\n")

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	route, err := hopperClient.PlanTransit(ctx, req)
	if err != nil {
		fmt.Printf("DEBUG: GraphHopper error: %v\n", err)
		return c.Status(fiber.StatusBadGateway).JSON(models.ErrorResponse{Error: err.Error()})
	}

	fmt.Printf("DEBUG: Route found successfully\n")
	return c.Status(fiber.StatusOK).JSON(route)
}

func validateCoordinate(c models.Coordinate) error {
	if math.IsNaN(c.Lat) || math.IsNaN(c.Lon) {
		return fmt.Errorf("coordinate contains NaN values: lat=%f, lon=%f", c.Lat, c.Lon)
	}
	if c.Lat < -90 || c.Lat > 90 {
		return fmt.Errorf("latitude out of range: %f (must be between -90 and 90)", c.Lat)
	}
	if c.Lon < -180 || c.Lon > 180 {
		return fmt.Errorf("longitude out of range: %f (must be between -180 and 180)", c.Lon)
	}
	return nil
}
