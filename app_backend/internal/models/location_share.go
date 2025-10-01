package models

import "time"

// LocationShare representa un compartir de ubicación en tiempo real
type LocationShare struct {
	ID            string    `json:"id" db:"id"`
	UserID        int64     `json:"user_id" db:"user_id"`
	Latitude      float64   `json:"latitude" db:"latitude"`
	Longitude     float64   `json:"longitude" db:"longitude"`
	RecipientName *string   `json:"recipient_name,omitempty" db:"recipient_name"`
	Message       *string   `json:"message,omitempty" db:"message"`
	CreatedAt     time.Time `json:"created_at" db:"created_at"`
	ExpiresAt     time.Time `json:"expires_at" db:"expires_at"`
	IsActive      bool      `json:"is_active" db:"is_active"`
	LastUpdatedAt time.Time `json:"last_updated_at" db:"last_updated_at"`
}

// LocationShareCreateRequest representa la solicitud para crear un share
type LocationShareCreateRequest struct {
	Latitude      float64 `json:"latitude" validate:"required,latitude"`
	Longitude     float64 `json:"longitude" validate:"required,longitude"`
	RecipientName *string `json:"recipient_name,omitempty"`
	Message       *string `json:"message,omitempty"`
	DurationHours int     `json:"duration_hours" validate:"required,min=1,max=24"`
}

// LocationShareUpdateRequest representa la actualización de ubicación
type LocationShareUpdateRequest struct {
	Latitude  float64 `json:"latitude" validate:"required,latitude"`
	Longitude float64 `json:"longitude" validate:"required,longitude"`
}

// LocationShareResponse representa la respuesta con datos del share
type LocationShareResponse struct {
	*LocationShare
	ShareURL      string `json:"share_url"`
	TimeRemaining int64  `json:"time_remaining_seconds"`
}
