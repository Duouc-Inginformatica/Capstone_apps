package handlers

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
	"github.com/yourorg/wayfindcl/internal/models"
)

type LocationShareHandler struct {
	db *sql.DB
}

func NewLocationShareHandler(db *sql.DB) *LocationShareHandler {
	return &LocationShareHandler{db: db}
}

// CreateLocationShare crea un nuevo compartir de ubicación
func (h *LocationShareHandler) CreateLocationShare(c *fiber.Ctx) error {
	var req models.LocationShareCreateRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	// Obtener ID del usuario
	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	// Generar ID único para el compartido
	shareID := uuid.New().String()
	expiresAt := time.Now().Add(time.Duration(req.DurationHours) * time.Hour)

	query := `
		INSERT INTO location_shares (
			id, user_id, latitude, longitude, recipient_name,
			message, expires_at, is_active, created_at, last_updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, true, NOW(), NOW())
	`

	_, err := h.db.Exec(
		query,
		shareID,
		userID,
		req.Latitude,
		req.Longitude,
		req.RecipientName,
		req.Message,
		expiresAt,
	)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to create location share",
		})
	}

	// Generar URL de compartido
	shareURL := fmt.Sprintf("wayfindcl://share/%s", shareID)
	timeRemaining := int64(time.Until(expiresAt).Seconds())

	return c.Status(fiber.StatusCreated).JSON(models.LocationShareResponse{
		ShareURL:      shareURL,
		TimeRemaining: timeRemaining,
	})
}

// GetLocationShare obtiene detalles de un compartido
func (h *LocationShareHandler) GetLocationShare(c *fiber.Ctx) error {
	shareID := c.Params("id")

	query := `
		SELECT 
			id, user_id, latitude, longitude, recipient_name,
			message, expires_at, is_active, created_at, last_updated_at
		FROM location_shares
		WHERE id = ? AND is_active = true AND expires_at > NOW()
	`

	var share models.LocationShare
	err := h.db.QueryRow(query, shareID).Scan(
		&share.ID,
		&share.UserID,
		&share.Latitude,
		&share.Longitude,
		&share.RecipientName,
		&share.Message,
		&share.ExpiresAt,
		&share.IsActive,
		&share.CreatedAt,
		&share.LastUpdatedAt,
	)

	if err == sql.ErrNoRows {
		return c.Status(fiber.StatusNotFound).JSON(fiber.Map{
			"error": "Share not found or expired",
		})
	}

	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch share",
		})
	}

	return c.JSON(share)
}

// UpdateLocationShare actualiza la posición de un compartido activo
func (h *LocationShareHandler) UpdateLocationShare(c *fiber.Ctx) error {
	shareID := c.Params("id")

	var req models.LocationShareUpdateRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	// Verificar que el usuario sea el propietario
	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	query := `
		UPDATE location_shares
		SET latitude = ?, longitude = ?, last_updated_at = NOW()
		WHERE id = ? AND user_id = ? AND is_active = true AND expires_at > NOW()
	`

	result, err := h.db.Exec(query, req.Latitude, req.Longitude, shareID, userID)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to update location",
		})
	}

	rowsAffected, _ := result.RowsAffected()
	if rowsAffected == 0 {
		return c.Status(fiber.StatusNotFound).JSON(fiber.Map{
			"error": "Share not found or expired",
		})
	}

	return c.JSON(fiber.Map{
		"message": "Location updated successfully",
	})
}

// StopLocationShare detiene un compartido activo
func (h *LocationShareHandler) StopLocationShare(c *fiber.Ctx) error {
	shareID := c.Params("id")

	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	query := `
		UPDATE location_shares
		SET is_active = false, last_updated_at = NOW()
		WHERE id = ? AND user_id = ?
	`

	result, err := h.db.Exec(query, shareID, userID)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to stop sharing",
		})
	}

	rowsAffected, _ := result.RowsAffected()
	if rowsAffected == 0 {
		return c.Status(fiber.StatusNotFound).JSON(fiber.Map{
			"error": "Share not found",
		})
	}

	return c.JSON(fiber.Map{
		"message": "Sharing stopped successfully",
	})
}

// GetUserShares obtiene todos los compartidos del usuario
func (h *LocationShareHandler) GetUserShares(c *fiber.Ctx) error {
	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	query := `
		SELECT 
			id, user_id, latitude, longitude, recipient_name,
			message, expires_at, is_active, created_at, last_updated_at
		FROM location_shares
		WHERE user_id = ?
		ORDER BY created_at DESC
		LIMIT 50
	`

	rows, err := h.db.Query(query, userID)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch shares",
		})
	}
	defer rows.Close()

	shares := []models.LocationShare{}
	for rows.Next() {
		var share models.LocationShare
		err := rows.Scan(
			&share.ID,
			&share.UserID,
			&share.Latitude,
			&share.Longitude,
			&share.RecipientName,
			&share.Message,
			&share.ExpiresAt,
			&share.IsActive,
			&share.CreatedAt,
			&share.LastUpdatedAt,
		)
		if err != nil {
			continue
		}
		shares = append(shares, share)
	}

	return c.JSON(fiber.Map{
		"shares": shares,
		"count":  len(shares),
	})
}
