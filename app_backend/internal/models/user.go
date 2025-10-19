package models

import "time"

// User represents a user record in DB (internal use only).
type User struct {
	ID           int64     `json:"id"`
	Username     string    `json:"username"`
	Email        string    `json:"email"`
	Name         string    `json:"name"`
	PasswordHash string    `json:"-"`
	BiometricID  string    `json:"-"` // SHA-256 hash del dispositivo biométrico
	AuthType     string    `json:"auth_type"` // "password" o "biometric"
	CreatedAt    time.Time `json:"created_at"`
}

// RegisterRequest holds the data for creating a new user.
type RegisterRequest struct {
	Username       string `json:"username"`
	Email          string `json:"email"`
	Password       string `json:"password"`
	Name           string `json:"name"`
	BiometricToken string `json:"biometric_token,omitempty"` // Token del dispositivo biométrico
}
