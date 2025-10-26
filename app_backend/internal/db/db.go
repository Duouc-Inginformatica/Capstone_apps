package db

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// Connect returns a MariaDB connection using env vars.
func Connect() (*sql.DB, error) {
	user := os.Getenv("DB_USER")
	pass := os.Getenv("DB_PASS")
	host := os.Getenv("DB_HOST")
	port := os.Getenv("DB_PORT")
	name := os.Getenv("DB_NAME")
	if host == "" {
		host = "127.0.0.1"
	}
	if port == "" {
		port = "3306"
	}
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&charset=utf8mb4,utf8", user, pass, host, port, name)
	
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("error abriendo conexión: %w", err)
	}

	// ============================================================================
	// CONFIGURACIÓN DEL POOL DE CONEXIONES
	// ============================================================================
	// Configurar límites basados en variables de entorno o valores por defecto
	maxOpenConns := 25  // Máximo de conexiones abiertas simultáneas
	maxIdleConns := 10  // Conexiones idle en el pool
	
	if env := os.Getenv("DB_MAX_OPEN_CONNS"); env != "" {
		fmt.Sscanf(env, "%d", &maxOpenConns)
	}
	if env := os.Getenv("DB_MAX_IDLE_CONNS"); env != "" {
		fmt.Sscanf(env, "%d", &maxIdleConns)
	}

	db.SetMaxOpenConns(maxOpenConns)                  // Máximo de conexiones abiertas
	db.SetMaxIdleConns(maxIdleConns)                  // Conexiones idle en el pool
	db.SetConnMaxLifetime(5 * time.Minute)            // Tiempo de vida máximo de una conexión
	db.SetConnMaxIdleTime(2 * time.Minute)            // Tiempo máximo que una conexión puede estar idle

	log.Printf("📊 Pool de conexiones configurado: max_open=%d, max_idle=%d", maxOpenConns, maxIdleConns)

	// ============================================================================
	// VERIFICAR CONECTIVIDAD
	// ============================================================================
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("❌ ping a base de datos falló: %w", err)
	}

	log.Println("✅ Conexión a base de datos verificada")
	return db, nil
}

// EnsureSchema creates required tables if not exist.
func EnsureSchema(db *sql.DB) error {
	if skip := strings.TrimSpace(os.Getenv("DB_SKIP_SCHEMA")); strings.EqualFold(skip, "true") || skip == "1" {
		log.Printf("EnsureSchema: skipped (DB_SKIP_SCHEMA=%q)", skip)
		return nil
	}

	if _, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS users (
			id BIGINT AUTO_INCREMENT PRIMARY KEY,
			username VARCHAR(50) NOT NULL UNIQUE,
			email VARCHAR(255) NOT NULL UNIQUE,
			name VARCHAR(100) NOT NULL,
			password_hash VARCHAR(255) NOT NULL,
			created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
	`); err != nil {
		return err
	}

	if _, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS gtfs_feeds (
			id BIGINT AUTO_INCREMENT PRIMARY KEY,
			source_url VARCHAR(500) NOT NULL,
			feed_version VARCHAR(100) NULL,
			downloaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
	`); err != nil {
		return err
	}

	if _, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS gtfs_stops (
			stop_id VARCHAR(64) PRIMARY KEY,
			feed_id BIGINT NULL,
			code VARCHAR(64) NULL,
			name VARCHAR(255) NOT NULL,
			description VARCHAR(255) NULL,
			latitude DOUBLE NOT NULL,
			longitude DOUBLE NOT NULL,
			zone_id VARCHAR(64) NULL,
			wheelchair_boarding TINYINT NOT NULL DEFAULT 0,
			FOREIGN KEY (feed_id) REFERENCES gtfs_feeds(id) ON DELETE SET NULL
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
	`); err != nil {
		return err
	}

	if _, err := db.Exec(`
		CREATE INDEX idx_gtfs_stops_latlon ON gtfs_stops(latitude, longitude);
	`); err != nil {
		errMsg := strings.ToLower(err.Error())
		if strings.Contains(errMsg, "duplicate") {
			// index already exists, nothing to do
		} else if strings.Contains(errMsg, "permission denied") {
			log.Printf("EnsureSchema: unable to create gtfs_stops index (permission denied): %v", err)
		} else {
			return err
		}
	}

	return nil
}
