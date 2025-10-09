package main

import (
	"bufio"
	"context"
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	appdb "github.com/yourorg/wayfindcl/internal/db"
	"github.com/yourorg/wayfindcl/internal/gtfs"
	"golang.org/x/crypto/bcrypt"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Println("==== WayFindCL CLI ====")
		fmt.Println("1) Health check API")
		fmt.Println("2) Seed database (create sample user)")
		fmt.Println("3) Sync GTFS feed")
		fmt.Println("4) Exit")
		fmt.Print("Select option: ")
		choice, _ := reader.ReadString('\n')
		choice = strings.TrimSpace(choice)
		switch choice {
		case "1":
			doHealthCheck()
		case "2":
			doSeed()
		case "3":
			doSyncGTFS()
		case "4":
			fmt.Println("Bye")
			return
		default:
			fmt.Println("Invalid option")
		}
		fmt.Println()
	}
}

func doHealthCheck() {
	base := os.Getenv("BASE_URL")
	if base == "" {
		base = "http://127.0.0.1:8080"
	}
	url := strings.TrimRight(base, "/") + "/api/health"
	resp, err := http.Get(url)
	if err != nil {
		fmt.Println("Health: ERROR:", err)
		return
	}
	defer resp.Body.Close()
	fmt.Println("Health status:", resp.Status)
}

func doSeed() {
	db, err := appdb.Connect()
	if err != nil {
		log.Println("DB connect error:", err)
		return
	}
	if err := appdb.EnsureSchema(db); err != nil {
		log.Println("Ensure schema error:", err)
		return
	}
	seedUser(db)
}

func doSyncGTFS() {
	feedURL := strings.TrimSpace(os.Getenv("GTFS_FEED_URL"))
	if feedURL == "" {
		feedURL = "https://www.dtpm.cl/descarga.php?file=gtfs/gtfs.zip"
		fmt.Println("GTFS_FEED_URL no definido, usando feed por defecto de DTPM.")
	}
	fallbackURL := strings.TrimSpace(os.Getenv("GTFS_FALLBACK_URL"))
	if fallbackURL == "" {
		fallbackURL = "https://www.dtpm.cl/descarga.php?file=gtfs/gtfs.zip"
	}
	loader := gtfs.NewLoader(feedURL, fallbackURL, nil)

	db, err := appdb.Connect()
	if err != nil {
		log.Println("GTFS sync: db connect error:", err)
		return
	}
	defer db.Close()
	if err := appdb.EnsureSchema(db); err != nil {
		log.Println("GTFS sync: ensure schema error:", err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	summary, err := loader.Sync(ctx, db)
	if err != nil {
		log.Println("GTFS sync: error:", err)
		return
	}
	fmt.Printf("GTFS sync OK: %d paradas (versión %s) [%s]\n", summary.StopsImported, summary.FeedVersion, summary.DownloadedAt.Format(time.RFC3339))
}

func seedUser(db *sql.DB) {
	// Creates a sample user if not exists
	username := "demo"
	email := "demo@example.com"
	name := "Demo"
	password := "demo1234"
	var exists int
	_ = db.QueryRow("SELECT 1 FROM users WHERE username = ?", username).Scan(&exists)
	if exists == 1 {
		fmt.Println("Seed: user 'demo' already exists")
		return
	}
	// Store bcrypt hash using the same logic as handler (quick inline)
	hash, err := bcryptHash(password)
	if err != nil {
		fmt.Println("Seed: bcrypt error:", err)
		return
	}
	_, err = db.Exec("INSERT INTO users (username,email,name,password_hash) VALUES (?,?,?,?)", username, email, name, hash)
	if err != nil {
		fmt.Println("Seed: insert error:", err)
		return
	}
	fmt.Println("Seed: created user 'demo' with password 'demo1234'")
}

func bcryptHash(pw string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.DefaultCost)
	return string(b), err
}
