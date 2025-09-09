package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/models"
)

// Login handles POST /api/login.
// For now, it returns a placeholder token without DB verification.
func Login(c *fiber.Ctx) error {
	var req models.LoginRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "invalid json"})
	}

	if strings.TrimSpace(req.Username) == "" || strings.TrimSpace(req.Password) == "" {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "username and password required"})
	}

	// TODO: validate credentials against DB and generate JWT
	resp := models.LoginResponse{
		Token: "dev-token-placeholder",
		User: models.UserDTO{ID: 1, Username: req.Username, Name: "Usuario"},
	}
	c.Set("Cache-Control", "no-store")
	return c.Status(fiber.StatusOK).JSON(resp)
}
