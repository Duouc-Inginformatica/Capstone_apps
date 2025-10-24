package handlers

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/golang-jwt/jwt/v5"
	"github.com/yourorg/wayfindcl/internal/gtfs"
	"github.com/yourorg/wayfindcl/internal/models"

	"golang.org/x/crypto/bcrypt"
)

// package-level dependencies
var (
	dbConn          *sql.DB
	jwtSecret       []byte
	tokenTTL        = 24 * time.Hour
	gtfsLoader      *gtfs.Loader
	gtfsSyncMu      sync.Mutex
	gtfsSummaryMu   sync.RWMutex
	gtfsLastSummary *gtfs.Summary
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

	if ttl := os.Getenv("JWT_TTL"); ttl != "" {
		dur, err := time.ParseDuration(ttl)
		if err != nil || dur <= 0 {
			log.Printf("invalid JWT_TTL=%q, using default %s", ttl, tokenTTL)
		} else {
			tokenTTL = dur
		}
	}

	feedURL := strings.TrimSpace(os.Getenv("GTFS_FEED_URL"))
	if feedURL == "" {
		feedURL = "https://www.dtpm.cl/descarga.php?file=gtfs/gtfs.zip"
	}
	fallbackURL := strings.TrimSpace(os.Getenv("GTFS_FALLBACK_URL"))
	if fallbackURL == "" {
		fallbackURL = "https://www.dtpm.cl/descarga.php?file=gtfs/gtfs.zip"
	}
	gtfsLoader = gtfs.NewLoader(feedURL, fallbackURL, nil)

	if auto := strings.TrimSpace(os.Getenv("GTFS_AUTO_SYNC")); strings.EqualFold(auto, "true") {
		go func() {
			log.Printf("gtfs auto-sync: starting (this may take several minutes for large feeds)...")
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute) // Aumentado a 30 minutos
			defer cancel()
			summary, err := gtfsLoader.Sync(ctx, dbConn)
			if err != nil {
				log.Printf("gtfs auto-sync failed: %v", err)
				return
			}
			gtfsSummaryMu.Lock()
			gtfsLastSummary = summary
			gtfsSummaryMu.Unlock()
			log.Printf("gtfs auto-sync completed: %d stops imported from %s", summary.StopsImported, summary.SourceURL)
		}()
	}
}

type userClaims struct {
	Username string `json:"username"`
	jwt.RegisteredClaims
}

func issueToken(userID int64, username string) (string, time.Time, error) {
	now := time.Now()
	expires := now.Add(tokenTTL)
	claims := userClaims{
		Username: username,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   strconv.FormatInt(userID, 10),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(expires),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := token.SignedString(jwtSecret)
	return signed, expires, err
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
	req.BiometricToken = strings.TrimSpace(req.BiometricToken)

	// Validar que tenga username y email
	if req.Username == "" || req.Email == "" {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "username and email required"})
	}
	if !strings.Contains(req.Email, "@") {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "invalid email"})
	}

	var userID int64
	var err error

	// Determinar tipo de autenticación: biométrica o por password
	if req.BiometricToken != "" {
		// ============ REGISTRO BIOMÉTRICO ============
		log.Printf("📱 Registro biométrico para usuario: %s", req.Username)

		// Verificar que el token biométrico no esté ya registrado
		var existingID int64
		err := dbConn.QueryRow(`SELECT id FROM users WHERE biometric_id = ?`, req.BiometricToken).Scan(&existingID)
		if err == nil {
			log.Printf("⚠️ Token biométrico ya registrado para user_id=%d", existingID)
			return c.Status(fiber.StatusConflict).JSON(models.ErrorResponse{Error: "biometric token already registered"})
		} else if !errors.Is(err, sql.ErrNoRows) {
			log.Printf("❌ Error verificando token biométrico: %v", err)
			return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
		}

		// Insertar usuario con autenticación biométrica (sin password)
		res, err := dbConn.Exec(`
			INSERT INTO users (username, email, name, biometric_id, auth_type) 
			VALUES (?, ?, ?, ?, 'biometric')
		`, req.Username, req.Email, req.Name, req.BiometricToken)

		if err != nil {
			if strings.Contains(err.Error(), "Duplicate entry") {
				return c.Status(fiber.StatusConflict).JSON(models.ErrorResponse{Error: "username or email already exists"})
			}
			log.Printf("❌ Error insertando usuario biométrico: %v", err)
			return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
		}

		userID, _ = res.LastInsertId()
		log.Printf("✅ Usuario biométrico registrado: id=%d, username=%s", userID, req.Username)

	} else if req.Password != "" {
		// ============ REGISTRO CON PASSWORD ============
		log.Printf("🔑 Registro con password para usuario: %s", req.Username)

		hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
		if err != nil {
			return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "failed to secure password"})
		}

		res, err := dbConn.Exec(`
			INSERT INTO users (username, email, name, password_hash, auth_type) 
			VALUES (?, ?, ?, ?, 'password')
		`, req.Username, req.Email, req.Name, string(hash))

		if err != nil {
			if strings.Contains(err.Error(), "Duplicate entry") {
				return c.Status(fiber.StatusConflict).JSON(models.ErrorResponse{Error: "username or email already exists"})
			}
			return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
		}

		userID, _ = res.LastInsertId()
		log.Printf("✅ Usuario con password registrado: id=%d, username=%s", userID, req.Username)

	} else {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "password or biometric_token required"})
	}

	token, expiresAt, err := issueToken(userID, req.Username)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "failed to sign token"})
	}
	c.Set("Cache-Control", "no-store")
	return c.Status(fiber.StatusCreated).JSON(models.LoginResponse{
		Token:     token,
		User:      models.UserDTO{ID: userID, Username: req.Username, Name: req.Name},
		ExpiresAt: expiresAt,
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
		id                           int64
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
	token, expiresAt, err := issueToken(id, username)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "failed to sign token"})
	}
	c.Set("Cache-Control", "no-store")
	return c.Status(fiber.StatusOK).JSON(models.LoginResponse{
		Token:     token,
		User:      models.UserDTO{ID: id, Username: username, Name: name},
		ExpiresAt: expiresAt,
	})
}

// BiometricRegister handles POST /api/auth/biometric/register
// Registers a new user using biometric authentication (for blind users)
func BiometricRegister(c *fiber.Ctx) error {
	if dbConn == nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "server not ready"})
	}

	var req models.BiometricRegisterRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "invalid json"})
	}

	// Validaciones
	req.BiometricID = strings.TrimSpace(req.BiometricID)
	req.Username = strings.TrimSpace(req.Username)
	req.Email = strings.TrimSpace(strings.ToLower(req.Email))

	if req.BiometricID == "" {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "biometric_id required"})
	}
	if req.Username == "" {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "username required"})
	}
	if len(req.BiometricID) < 16 {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "invalid biometric_id format"})
	}

	// Validar email si se proporciona
	if req.Email != "" && !strings.Contains(req.Email, "@") {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "invalid email"})
	}

	// Verificar si ya existe el biometric_id
	var existingID int64
	err := dbConn.QueryRow(`SELECT id FROM users WHERE biometric_id = ?`, req.BiometricID).Scan(&existingID)
	if err == nil {
		return c.Status(fiber.StatusConflict).JSON(models.ErrorResponse{Error: "biometric already registered"})
	} else if !errors.Is(err, sql.ErrNoRows) {
		log.Printf("Error checking biometric_id: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}

	// Verificar si ya existe el username
	err = dbConn.QueryRow(`SELECT id FROM users WHERE username = ?`, req.Username).Scan(&existingID)
	if err == nil {
		return c.Status(fiber.StatusConflict).JSON(models.ErrorResponse{Error: "username already exists"})
	} else if !errors.Is(err, sql.ErrNoRows) {
		log.Printf("Error checking username: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}

	// Insertar nuevo usuario biométrico
	res, err := dbConn.Exec(
		`INSERT INTO users (biometric_id, username, name, email, device_info, auth_type, created_at, last_login) VALUES (?, ?, ?, ?, ?, 'biometric', NOW(), NOW())`,
		req.BiometricID,
		req.Username,
		req.Username,
		sql.NullString{String: req.Email, Valid: req.Email != ""},
		sql.NullString{String: req.DeviceInfo, Valid: req.DeviceInfo != ""},
	)
	if err != nil {
		log.Printf("Error inserting biometric user: %v", err)
		if strings.Contains(err.Error(), "Duplicate entry") {
			return c.Status(fiber.StatusConflict).JSON(models.ErrorResponse{Error: "username or biometric already exists"})
		}
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}

	userID, _ := res.LastInsertId()

	// Generar token JWT
	token, expiresAt, err := issueToken(userID, req.Username)
	if err != nil {
		log.Printf("Error generating token: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "failed to sign token"})
	}

	log.Printf("✅ Biometric user registered: id=%d, username=%s", userID, req.Username)

	c.Set("Cache-Control", "no-store")
	return c.Status(fiber.StatusCreated).JSON(models.LoginResponse{
		Token: token,
		User: models.UserDTO{
			ID:       userID,
			Username: req.Username,
			Name:     req.Username,
			Email:    req.Email,
		},
		ExpiresAt: expiresAt,
	})
}

// BiometricLogin handles POST /api/auth/biometric/login
// Authenticates a user using biometric ID (for blind users)
func BiometricLogin(c *fiber.Ctx) error {
	if dbConn == nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "server not ready"})
	}

	var req models.BiometricLoginRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "invalid json"})
	}

	req.BiometricID = strings.TrimSpace(req.BiometricID)
	if req.BiometricID == "" {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "biometric_id required"})
	}

	// Buscar usuario por biometric_id
	var (
		id       int64
		username string
		email    sql.NullString
	)
	err := dbConn.QueryRow(
		`SELECT id, username, email FROM users WHERE biometric_id = ? AND auth_type = 'biometric'`,
		req.BiometricID,
	).Scan(&id, &username, &email)

	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return c.Status(fiber.StatusUnauthorized).JSON(models.ErrorResponse{Error: "biometric not recognized"})
		}
		log.Printf("Error querying biometric user: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}

	// Actualizar last_login
	_, err = dbConn.Exec(`UPDATE users SET last_login = NOW() WHERE id = ?`, id)
	if err != nil {
		log.Printf("Warning: failed to update last_login for user %d: %v", id, err)
	}

	// Generar token JWT
	token, expiresAt, err := issueToken(id, username)
	if err != nil {
		log.Printf("Error generating token: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "failed to sign token"})
	}

	log.Printf("✅ Biometric login successful: id=%d, username=%s", id, username)

	emailStr := ""
	if email.Valid {
		emailStr = email.String
	}

	c.Set("Cache-Control", "no-store")
	return c.Status(fiber.StatusOK).JSON(models.LoginResponse{
		Token: token,
		User: models.UserDTO{
			ID:       id,
			Username: username,
			Name:     username,
			Email:    emailStr,
		},
		ExpiresAt: expiresAt,
	})
}

// CheckBiometricExists handles POST /api/biometric/check
// Verifica si un token biométrico ya está registrado
func CheckBiometricExists(c *fiber.Ctx) error {
	if dbConn == nil {
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "server not ready"})
	}

	var req struct {
		BiometricToken string `json:"biometric_token"`
	}

	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(models.ErrorResponse{Error: "invalid json"})
	}

	req.BiometricToken = strings.TrimSpace(req.BiometricToken)
	if req.BiometricToken == "" {
		return c.Status(fiber.StatusUnprocessableEntity).JSON(models.ErrorResponse{Error: "biometric_token required"})
	}

	// Verificar si existe
	var existingID int64
	err := dbConn.QueryRow(`SELECT id FROM users WHERE biometric_id = ?`, req.BiometricToken).Scan(&existingID)

	exists := false
	if err == nil {
		// Token encontrado
		exists = true
		log.Printf("🔍 Token biométrico encontrado: user_id=%d", existingID)
	} else if !errors.Is(err, sql.ErrNoRows) {
		// Error de BD
		log.Printf("❌ Error verificando token biométrico: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}
	// Si es ErrNoRows, exists queda en false

	return c.Status(fiber.StatusOK).JSON(fiber.Map{
		"exists": exists,
	})
}
