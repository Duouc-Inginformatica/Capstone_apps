package models

import "time"

// LoginRequest represents credentials provided by the client.
type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// UserDTO is a minimal user representation for responses.
type UserDTO struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
	Name     string `json:"name"`
}

// LoginResponse is returned upon successful authentication.
type LoginResponse struct {
	Token string  `json:"token"`
	User  UserDTO `json:"user"`
	ExpiresAt time.Time `json:"expires_at"`
}

// ErrorResponse is a simple error shape for API errors.
type ErrorResponse struct {
	Error string `json:"error"`
}
