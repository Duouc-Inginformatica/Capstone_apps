package models

import "time"

// LoginRequest represents credentials provided by the client.
type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// BiometricRegisterRequest represents biometric registration data
type BiometricRegisterRequest struct {
	BiometricID string `json:"biometric_id"` // SHA-256 hash from device
	Username    string `json:"username"`
	Email       string `json:"email,omitempty"` // Opcional
	DeviceInfo  string `json:"device_info,omitempty"`
}

// BiometricLoginRequest represents biometric authentication data
type BiometricLoginRequest struct {
	BiometricID string `json:"biometric_id"` // SHA-256 hash from device
	DeviceInfo  string `json:"device_info,omitempty"`
}

// UserDTO is a minimal user representation for responses.
type UserDTO struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
	Name     string `json:"name"`
	Email    string `json:"email,omitempty"`
}

// LoginResponse is returned upon successful authentication.
type LoginResponse struct {
	Token     string    `json:"token"`
	User      UserDTO   `json:"user"`
	ExpiresAt time.Time `json:"expires_at"`
}

// ErrorResponse is a simple error shape for API errors.
type ErrorResponse struct {
	Error string `json:"error"`
}
