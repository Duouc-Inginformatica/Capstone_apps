package db

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"strings"

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
	return sql.Open("mysql", dsn)
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
