package models

import "time"

// NotificationPreferences representa las preferencias de notificaciones del usuario
type NotificationPreferences struct {
	ID                  int64     `json:"id" db:"id"`
	UserID              int64     `json:"user_id" db:"user_id"`
	ApproachingDistance float64   `json:"approaching_distance" db:"approaching_distance"`
	NearDistance        float64   `json:"near_distance" db:"near_distance"`
	VeryNearDistance    float64   `json:"very_near_distance" db:"very_near_distance"`
	EnableAudio         bool      `json:"enable_audio" db:"enable_audio"`
	EnableVibration     bool      `json:"enable_vibration" db:"enable_vibration"`
	EnableVisual        bool      `json:"enable_visual" db:"enable_visual"`
	AudioVolume         float64   `json:"audio_volume" db:"audio_volume"`
	VibrationIntensity  float64   `json:"vibration_intensity" db:"vibration_intensity"`
	MinimumPriority     string    `json:"minimum_priority" db:"minimum_priority"` // low, medium, high, critical
	CreatedAt           time.Time `json:"created_at" db:"created_at"`
	UpdatedAt           time.Time `json:"updated_at" db:"updated_at"`
}

// NotificationPreferencesUpdateRequest representa la actualización de preferencias
type NotificationPreferencesUpdateRequest struct {
	ApproachingDistance *float64 `json:"approaching_distance,omitempty" validate:"omitempty,min=0"`
	NearDistance        *float64 `json:"near_distance,omitempty" validate:"omitempty,min=0"`
	VeryNearDistance    *float64 `json:"very_near_distance,omitempty" validate:"omitempty,min=0"`
	EnableAudio         *bool    `json:"enable_audio,omitempty"`
	EnableVibration     *bool    `json:"enable_vibration,omitempty"`
	EnableVisual        *bool    `json:"enable_visual,omitempty"`
	AudioVolume         *float64 `json:"audio_volume,omitempty" validate:"omitempty,min=0,max=1"`
	VibrationIntensity  *float64 `json:"vibration_intensity,omitempty" validate:"omitempty,min=0,max=1"`
	MinimumPriority     *string  `json:"minimum_priority,omitempty" validate:"omitempty,oneof=low medium high critical"`
}
