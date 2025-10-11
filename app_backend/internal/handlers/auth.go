package handlers

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/golang-jwt/jwt/v5"
	"github.com/yourorg/wayfindcl/internal/graphhopper"
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
	hopperClient    *graphhopper.Client
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
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer cancel()
			summary, err := gtfsLoader.Sync(ctx, dbConn)
			if err != nil {
				log.Printf("gtfs auto-sync failed: %v", err)
				return
			}
			gtfsSummaryMu.Lock()
			gtfsLastSummary = summary
			gtfsSummaryMu.Unlock()
			log.Printf("gtfs auto-sync completed: %d stops", summary.StopsImported)
		}()
	}

	if base := strings.TrimSpace(os.Getenv("GRAPHHOPPER_BASE_URL")); base != "" {
		fmt.Printf("DEBUG: Inicializando GraphHopper con base URL: %s\n", base)
		fmt.Printf("DEBUG: API Key: %s\n", strings.TrimSpace(os.Getenv("GRAPHHOPPER_API_KEY")))
		
		includeGeom := true
		if opt := strings.TrimSpace(os.Getenv("GRAPHHOPPER_INCLUDE_GEOMETRY")); opt != "" {
			includeGeom = !(strings.EqualFold(opt, "false") || opt == "0")
		}
		opts := graphhopper.Options{
			Profile:         strings.TrimSpace(os.Getenv("GRAPHHOPPER_PROFILE")),
			Locale:          strings.TrimSpace(os.Getenv("GRAPHHOPPER_LOCALE")),
			IncludeGeometry: includeGeom,
		}
		if timeoutStr := strings.TrimSpace(os.Getenv("GRAPHHOPPER_TIMEOUT")); timeoutStr != "" {
			if dur, err := time.ParseDuration(timeoutStr); err == nil && dur > 0 {
				opts.Timeout = dur
			}
		}
		client, err := graphhopper.NewClient(base, strings.TrimSpace(os.Getenv("GRAPHHOPPER_API_KEY")), opts)
		if err != nil {
			log.Printf("graphhopper init error: %v", err)
		} else {
			hopperClient = client
			fmt.Printf("DEBUG: GraphHopper client inicializado correctamente\n")
		}
	} else {
		fmt.Printf("DEBUG: GRAPHHOPPER_BASE_URL está vacío, no inicializando GraphHopper\n")
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
