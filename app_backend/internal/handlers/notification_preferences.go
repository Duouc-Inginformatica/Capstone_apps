package handlers

import (
	"database/sql"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/models"
)

type NotificationPreferencesHandler struct {
	db *sql.DB
}

func NewNotificationPreferencesHandler(db *sql.DB) *NotificationPreferencesHandler {
	return &NotificationPreferencesHandler{db: db}
}

// GetNotificationPreferences obtiene las preferencias del usuario
func (h *NotificationPreferencesHandler) GetNotificationPreferences(c *fiber.Ctx) error {
	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	query := `
		SELECT 
			id, user_id, approaching_distance, near_distance,
			very_near_distance, enable_audio, enable_vibration,
			enable_visual, audio_volume, vibration_intensity,
			minimum_priority, created_at, updated_at
		FROM notification_preferences
		WHERE user_id = ?
	`

	var prefs models.NotificationPreferences
	err := h.db.QueryRow(query, userID).Scan(
		&prefs.ID,
		&prefs.UserID,
		&prefs.ApproachingDistance,
		&prefs.NearDistance,
		&prefs.VeryNearDistance,
		&prefs.EnableAudio,
		&prefs.EnableVibration,
		&prefs.EnableVisual,
		&prefs.AudioVolume,
		&prefs.VibrationIntensity,
		&prefs.MinimumPriority,
		&prefs.CreatedAt,
		&prefs.UpdatedAt,
	)

	if err == sql.ErrNoRows {
		// Retornar preferencias por defecto
		return c.JSON(models.NotificationPreferences{
			ApproachingDistance: 300,
			NearDistance:        100,
			VeryNearDistance:    30,
			EnableAudio:         true,
			EnableVibration:     true,
			EnableVisual:        true,
			AudioVolume:         0.8,
			VibrationIntensity:  0.7,
			MinimumPriority:     "medium",
		})
	}

	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to fetch preferences",
		})
	}

	return c.JSON(prefs)
}

// UpdateNotificationPreferences actualiza las preferencias del usuario
func (h *NotificationPreferencesHandler) UpdateNotificationPreferences(c *fiber.Ctx) error {
	userID := c.Locals("userID")
	if userID == nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Authentication required",
		})
	}

	var req models.NotificationPreferencesUpdateRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "Invalid request body",
		})
	}

	// Construir query dinámicamente según campos presentes
	updates := []string{}
	args := []interface{}{}

	if req.ApproachingDistance != nil {
		updates = append(updates, "approaching_distance = ?")
		args = append(args, *req.ApproachingDistance)
	}
	if req.NearDistance != nil {
		updates = append(updates, "near_distance = ?")
		args = append(args, *req.NearDistance)
	}
	if req.VeryNearDistance != nil {
		updates = append(updates, "very_near_distance = ?")
		args = append(args, *req.VeryNearDistance)
	}
	if req.EnableAudio != nil {
		updates = append(updates, "enable_audio = ?")
		args = append(args, *req.EnableAudio)
	}
	if req.EnableVibration != nil {
		updates = append(updates, "enable_vibration = ?")
		args = append(args, *req.EnableVibration)
	}
	if req.EnableVisual != nil {
		updates = append(updates, "enable_visual = ?")
		args = append(args, *req.EnableVisual)
	}
	if req.AudioVolume != nil {
		updates = append(updates, "audio_volume = ?")
		args = append(args, *req.AudioVolume)
	}
	if req.VibrationIntensity != nil {
		updates = append(updates, "vibration_intensity = ?")
		args = append(args, *req.VibrationIntensity)
	}
	if req.MinimumPriority != nil {
		updates = append(updates, "minimum_priority = ?")
		args = append(args, *req.MinimumPriority)
	}

	if len(updates) == 0 {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "No fields to update",
		})
	}

	updates = append(updates, "updated_at = NOW()")

	// Intentar actualizar, si no existe insertar
	query := `
		INSERT INTO notification_preferences (
			user_id, approaching_distance, near_distance,
			very_near_distance, enable_audio, enable_vibration,
			enable_visual, audio_volume, vibration_intensity,
			minimum_priority, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
		ON DUPLICATE KEY UPDATE ` + buildUpdateClause(updates)

	args = append([]interface{}{
		userID,
		getOrDefault(req.ApproachingDistance, 300.0),
		getOrDefault(req.NearDistance, 100.0),
		getOrDefault(req.VeryNearDistance, 30.0),
		getOrDefault(req.EnableAudio, true),
		getOrDefault(req.EnableVibration, true),
		getOrDefault(req.EnableVisual, true),
		getOrDefault(req.AudioVolume, 0.8),
		getOrDefault(req.VibrationIntensity, 0.7),
		getOrDefault(req.MinimumPriority, "medium"),
	}, args...)

	_, err := h.db.Exec(query, args...)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Failed to update preferences",
		})
	}

	return c.JSON(fiber.Map{
		"message": "Preferences updated successfully",
	})
}

// buildUpdateClause construye la cláusula UPDATE para ON DUPLICATE KEY UPDATE
func buildUpdateClause(updates []string) string {
	result := ""
	for i, update := range updates {
		if i > 0 {
			result += ", "
		}
		result += update
	}
	return result
}

// getOrDefault retorna el valor del puntero o el valor por defecto
func getOrDefault[T any](ptr *T, defaultValue T) T {
	if ptr != nil {
		return *ptr
	}
	return defaultValue
}
