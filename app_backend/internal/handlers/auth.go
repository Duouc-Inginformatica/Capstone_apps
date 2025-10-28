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
	"github.com/yourorg/wayfindcl/internal/gtfs"
	"github.com/yourorg/wayfindcl/internal/models"

	"golang.org/x/crypto/bcrypt"
)

// package-level dependencies
var (
	setupOnce       sync.Once     // Garantiza inicialización única
	setupMu         sync.RWMutex  // Protege acceso a variables globales
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
	setupOnce.Do(func() {
		setupMu.Lock()
		defer setupMu.Unlock()

		dbConn = db
		secret := os.Getenv("JWT_SECRET")
		if secret == "" {
			// Verificar si estamos en producción
			if os.Getenv("ENV") == "production" || os.Getenv("ENVIRONMENT") == "production" {
				log.Fatal("❌ CRITICAL: JWT_SECRET must be set in production environment")
			}
			log.Println("⚠️ WARNING: Using default JWT secret (development only)")
			secret = "dev-secret-change-me"
		}

		// Validar longitud mínima del secret
		if len(secret) < 32 {
			log.Fatalf("❌ CRITICAL: JWT_SECRET must be at least 32 characters long (current: %d)", len(secret))
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
			// Iniciar sincronización inicial y programar actualizaciones mensuales
			go startGTFSAutoSync(dbConn)
		}
	})
}

// getDBConn retorna la conexión de base de datos de forma segura
func getDBConn() *sql.DB {
	setupMu.RLock()
	defer setupMu.RUnlock()
	return dbConn
}

// getJWTSecret retorna el secret JWT de forma segura
func getJWTSecret() []byte {
	setupMu.RLock()
	defer setupMu.RUnlock()
	return jwtSecret
}

// startGTFSAutoSync inicia la sincronización automática de GTFS y verifica mensualmente
func startGTFSAutoSync(db *sql.DB) {
	// Primera sincronización: verificar si los datos son recientes
	shouldSync, lastSync := checkIfSyncNeeded(db)
	
	if shouldSync {
		log.Printf("🔄 [GTFS-SYNC] Iniciando sincronización automática...")
		log.Printf("📅 [GTFS-SYNC] Última sincronización: %v", lastSync)
		performGTFSSync(db)
	} else {
		log.Printf("✅ [GTFS-SYNC] Datos GTFS actualizados (última sincronización: %v)", lastSync)
		log.Printf("📅 [GTFS-SYNC] Próxima verificación en 30 días")
	}
	
	// Programar verificaciones mensuales (cada 30 días)
	ticker := time.NewTicker(30 * 24 * time.Hour)
	defer ticker.Stop()
	
	for range ticker.C {
		log.Printf("🔍 [GTFS-SYNC] Verificación mensual automática...")
		
		shouldSync, lastSync := checkIfSyncNeeded(db)
		if shouldSync {
			log.Printf("🔄 [GTFS-SYNC] Los datos tienen más de 30 días, actualizando...")
			performGTFSSync(db)
		} else {
			log.Printf("✅ [GTFS-SYNC] Datos aún actualizados (última sincronización: %v)", lastSync)
		}
	}
}

// checkIfSyncNeeded verifica si los datos GTFS necesitan actualización (>30 días)
func checkIfSyncNeeded(db *sql.DB) (bool, time.Time) {
	var lastDownload time.Time
	
	err := db.QueryRow(`
		SELECT MAX(downloaded_at) 
		FROM gtfs_feeds 
		WHERE downloaded_at IS NOT NULL
	`).Scan(&lastDownload)
	
	if err != nil {
		if err == sql.ErrNoRows {
			log.Printf("⚠️  [GTFS-SYNC] No hay registros de sincronización previa")
			return true, time.Time{} // Forzar sincronización
		}
		log.Printf("⚠️  [GTFS-SYNC] Error verificando última sincronización: %v", err)
		return true, time.Time{} // Por seguridad, forzar sincronización
	}
	
	daysSinceLastSync := time.Since(lastDownload).Hours() / 24
	log.Printf("📊 [GTFS-SYNC] Días desde última sincronización: %.1f", daysSinceLastSync)
	
	// Sincronizar si han pasado más de 30 días
	return daysSinceLastSync > 30, lastDownload
}

// performGTFSSync ejecuta la sincronización de GTFS
func performGTFSSync(db *sql.DB) {
	startTime := time.Now()
	log.Printf("🚀 [GTFS-SYNC] Iniciando sincronización (puede tomar varios minutos)...")
	
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	
	summary, err := gtfsLoader.Sync(ctx, db)
	if err != nil {
		log.Printf("❌ [GTFS-SYNC] Error en sincronización: %v", err)
		return
	}
	
	gtfsSummaryMu.Lock()
	gtfsLastSummary = summary
	gtfsSummaryMu.Unlock()
	
	elapsed := time.Since(startTime)
	log.Printf("✅ [GTFS-SYNC] Sincronización completada en %.1f minutos", elapsed.Minutes())
	log.Printf("📊 [GTFS-SYNC] Paradas importadas: %d", summary.StopsImported)
	log.Printf("📅 [GTFS-SYNC] Próxima verificación programada en 30 días")
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
	signed, err := token.SignedString(getJWTSecret())
	return signed, expires, err
}

// Register handles POST /api/register.
func Register(c *fiber.Ctx) error {
	db := getDBConn()
	if db == nil {
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
		err := db.QueryRow(`SELECT id FROM users WHERE biometric_id = ?`, req.BiometricToken).Scan(&existingID)
		if err == nil {
			log.Printf("⚠️ Token biométrico ya registrado para user_id=%d", existingID)
			return c.Status(fiber.StatusConflict).JSON(models.ErrorResponse{Error: "biometric token already registered"})
		} else if !errors.Is(err, sql.ErrNoRows) {
			log.Printf("❌ Error verificando token biométrico: %v", err)
			return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
		}

		// Insertar usuario con autenticación biométrica (sin password)
		res, err := db.Exec(`
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

		res, err := db.Exec(`
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
	db := getDBConn()
	if db == nil {
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
	err := db.QueryRow(`SELECT id, username, name, password_hash FROM users WHERE username = ?`, req.Username).Scan(&id, &username, &name, &passwordHash)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return c.Status(fiber.StatusUnauthorized).JSON(models.ErrorResponse{Error: "invalid credentials"})
		}
		log.Printf("❌ Error consultando usuario: %v", err)
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
	db := getDBConn()
	if db == nil {
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
	err := db.QueryRow(`SELECT id FROM users WHERE biometric_id = ?`, req.BiometricID).Scan(&existingID)
	if err == nil {
		return c.Status(fiber.StatusConflict).JSON(models.ErrorResponse{Error: "biometric already registered"})
	} else if !errors.Is(err, sql.ErrNoRows) {
		log.Printf("❌ Error verificando biometric_id: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}

	// Verificar si ya existe el username
	err = db.QueryRow(`SELECT id FROM users WHERE username = ?`, req.Username).Scan(&existingID)
	if err == nil {
		return c.Status(fiber.StatusConflict).JSON(models.ErrorResponse{Error: "username already exists"})
	} else if !errors.Is(err, sql.ErrNoRows) {
		log.Printf("❌ Error verificando username: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}

	// Insertar nuevo usuario biométrico
	res, err := db.Exec(
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
		Message:   fmt.Sprintf("¡Bienvenido, %s! Tu cuenta ha sido creada exitosamente", req.Username),
	})
}

// BiometricLogin handles POST /api/auth/biometric/login
// Authenticates a user using biometric ID (for blind users)
func BiometricLogin(c *fiber.Ctx) error {
	db := getDBConn()
	if db == nil {
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
	err := db.QueryRow(
		`SELECT id, username, email FROM users WHERE biometric_id = ? AND auth_type = 'biometric'`,
		req.BiometricID,
	).Scan(&id, &username, &email)

	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return c.Status(fiber.StatusUnauthorized).JSON(models.ErrorResponse{Error: "biometric not recognized"})
		}
		log.Printf("❌ Error consultando usuario biométrico: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}

	// Actualizar last_login
	_, err = db.Exec(`UPDATE users SET last_login = NOW() WHERE id = ?`, id)
	if err != nil {
		log.Printf("⚠️ Warning: failed to update last_login for user %d: %v", id, err)
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
		Message:   fmt.Sprintf("Bienvenido de nuevo, %s!", username), // Mensaje de bienvenida
	})
}

// CheckBiometricExists handles POST /api/biometric/check
// Verifica si un token biométrico ya está registrado y retorna info del usuario
func CheckBiometricExists(c *fiber.Ctx) error {
	db := getDBConn()
	if db == nil {
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

	// Verificar si existe y obtener datos del usuario
	var (
		userID   int64
		username string
		email    sql.NullString
	)
	err := db.QueryRow(
		`SELECT id, username, email FROM users WHERE biometric_id = ? AND auth_type = 'biometric'`,
		req.BiometricToken,
	).Scan(&userID, &username, &email)

	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			// No existe - cliente debe mostrar pantalla de registro
			log.Printf("🔍 Token biométrico no encontrado - usuario nuevo")
			return c.Status(fiber.StatusOK).JSON(fiber.Map{
				"exists":   false,
				"action":   "register",
				"message":  "Bienvenido! Por favor registra tu nombre de usuario",
			})
		}
		// Error real de base de datos
		log.Printf("❌ Error verificando token biométrico: %v", err)
		return c.Status(fiber.StatusInternalServerError).JSON(models.ErrorResponse{Error: "db error"})
	}

	// Usuario existe - retornar información para login automático
	log.Printf("✅ Token biométrico encontrado: user_id=%d, username=%s", userID, username)
	
	emailStr := ""
	if email.Valid {
		emailStr = email.String
	}

	return c.Status(fiber.StatusOK).JSON(fiber.Map{
		"exists":   true,
		"action":   "auto_login",
		"user_id":  userID,
		"username": username,
		"email":    emailStr,
		"message":  fmt.Sprintf("Bienvenido de nuevo, %s!", username),
	})
}
