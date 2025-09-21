package handlers

import (
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/yourorg/wayfindcl/internal/models"

	"golang.org/x/crypto/bcrypt"
)

// package-level dependencies
var (
	dbConn     *sql.DB
	jwtSecret  []byte
)

// Setup wires shared dependencies for handlers. Call this during app bootstrap.
func Setup(db *sql.DB) {
	dbConn = db
	secret := os.Getenv("JWT_SECRET")
	if secret == "" {
		// fallback dev-secret (not for production)
		secret = "dev-secret-change-me"
	}
	jwtSecret = []byte(secret)
}

// simple JWT-like token for demo purposes (HMAC SHA256 without external deps)
func issueToken(userID int64, username string) string {
	// Minimal JWT-like token generation (HS256) without third-party deps.
	// For production, prefer a mature JWT library.
	header := map[string]string{"alg": "HS256", "typ": "JWT"}
	payload := map[string]any{
		"sub": userID,
		"name": username,
		"iat": time.Now().Unix(),
	}
	hJSON, _ := json.Marshal(header)
	pJSON, _ := json.Marshal(payload)
	enc := base64.RawURLEncoding
	unsigned := enc.EncodeToString(hJSON) + "." + enc.EncodeToString(pJSON)
	mac := hmac.New(sha256.New, jwtSecret)
	mac.Write([]byte(unsigned))
	sig := enc.EncodeToString(mac.Sum(nil))
	return unsigned + "." + sig
}

// Register handles POST /api/register.
func Register(c *fiber.Ctx) error {
	if dbConn == nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "server not ready"})
	}
	var req models.RegisterRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "invalid json"})
	}
	req.Username = strings.TrimSpace(req.Username)
	req.Email = strings.TrimSpace(strings.ToLower(req.Email))
	req.Name = strings.TrimSpace(req.Name)
	if req.Username == "" || req.Email == "" || req.Password == "" {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "username, email and password required"})
	}
	if !strings.Contains(req.Email, "@") {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "invalid email"})
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "failed to secure password"})
	}

	res, err := dbConn.Exec(`INSERT INTO users (username,email,name,password_hash) VALUES (?,?,?,?)`, req.Username, req.Email, req.Name, string(hash))
	if err != nil {
		// naive duplicate detection
		if strings.Contains(err.Error(), "Duplicate entry") {
			return c.Status(fiber.StatusConflict).JSON(models.ErrorResponse{Error: "username or email already exists"})
		}
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}
	userID, _ := res.LastInsertId()

	token := issueToken(userID, req.Username)
	c.Set("Cache-Control", "no-store")
	return c.Status(fiber.StatusCreated).JSON(models.LoginResponse{
		Token: token,
		User:  models.UserDTO{ID: userID, Username: req.Username, Name: req.Name},
	})
}

// Login handles POST /api/login.
func Login(c *fiber.Ctx) error {
	if dbConn == nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "server not ready"})
	}
	var req models.LoginRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "invalid json"})
	}
	req.Username = strings.TrimSpace(req.Username)
	if req.Username == "" || strings.TrimSpace(req.Password) == "" {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "username and password required"})
	}

	var (
		id int64
		username, name, passwordHash string
	)
	err := dbConn.QueryRow(`SELECT id, username, name, password_hash FROM users WHERE username = ?`, req.Username).Scan(&id, &username, &name, &passwordHash)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return c.Status(fiber.StatusUnauthorized).JSON(models.ErrorResponse{Error: "invalid credentials"})
		}
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}
	if err := bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(req.Password)); err != nil {
		return c.Status(fiber.StatusUnauthorized).JSON(models.ErrorResponse{Error: "invalid credentials"})
	}
	token := issueToken(id, username)
	c.Set("Cache-Control", "no-store")
	return c.Status(fiber.StatusOK).JSON(models.LoginResponse{
		Token: token,
		User:  models.UserDTO{ID: id, Username: username, Name: name},
	})
}
