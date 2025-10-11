package handlers

import (
	"context"
	"errors"
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
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "json inválido"})
	}

	if err := validateCoordinate(req.Origin); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "origen inválido"})
	}
	if err := validateCoordinate(req.Destination); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "destino inválido"})
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	route, err := hopperClient.PlanTransit(ctx, req)
	if err != nil {
		return c.Status(fiber.StatusBadGateway).JSON(models.ErrorResponse{Error: err.Error()})
	}
	return c.Status(fiber.StatusOK).JSON(route)
}

func validateCoordinate(c models.Coordinate) error {
	if math.IsNaN(c.Lat) || math.IsNaN(c.Lon) {
		return errors.New("invalid coordinate")
	}
	if c.Lat < -90 || c.Lat > 90 || c.Lon < -180 || c.Lon > 180 {
		return errors.New("coordinate out of range")
	}
	return nil
}
