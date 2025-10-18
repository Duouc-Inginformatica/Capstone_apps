package gtfs

import (
	"archive/zip"
	"bytes"
	"context"
	"database/sql"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Loader downloads and imports GTFS feeds into the database.
type Loader struct {
	feedURL     string
	fallbackURL string
	httpClient  *http.Client
}

// Summary describes the result of a GTFS sync.
type Summary struct {
	FeedVersion   string    `json:"feed_version"`
	StopsImported int       `json:"stops_imported"`
	DownloadedAt  time.Time `json:"downloaded_at"`
	SourceURL     string    `json:"source_url"`
}

// NewLoader builds a loader for the provided GTFS feed URL. Optionally accepts a fallback URL that will
// be attempted when the primary feed returns a non-success status (e.g. 404).
func NewLoader(feedURL, fallbackURL string, client *http.Client) *Loader {
	if client == nil {
		client = &http.Client{Timeout: 120 * time.Second}
	}
	return &Loader{
		feedURL:     strings.TrimSpace(feedURL),
		fallbackURL: strings.TrimSpace(fallbackURL),
		httpClient:  client,
	}
}

// Sync downloads the GTFS feed and refreshes the stops table.
func (l *Loader) Sync(ctx context.Context, db *sql.DB) (*Summary, error) {
	if l.feedURL == "" {
		return nil, errors.New("gtfs loader: feed url is empty")
	}

	data, sourceURL, err := l.obtainFeed(ctx)
	if err != nil {
		return nil, err
	}
	readerAt := bytes.NewReader(data)
	zr, err := zip.NewReader(readerAt, int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: open zip: %w", err)
	}

	feedVersion := extractFeedVersion(zr)
	stopsFile, err := findFile(zr, "stops.txt")
	if err != nil {
		return nil, err
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: begin tx: %w", err)
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_stops"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear stops: %w", err)
	}

	res, err := tx.ExecContext(ctx,
		"INSERT INTO gtfs_feeds (source_url, feed_version) VALUES (?, ?)",
		sourceURL, feedVersion,
	)
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: insert feed: %w", err)
	}
	feedID, err := res.LastInsertId()
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: fetch feed id: %w", err)
	}

	count, err := importStops(ctx, tx, feedID, stopsFile)
	if err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("gtfs loader: commit: %w", err)
	}

	summary := &Summary{
		FeedVersion:   feedVersion,
		StopsImported: count,
		DownloadedAt:  time.Now().UTC(),
		SourceURL:     sourceURL,
	}
	return summary, nil
}

func (l *Loader) obtainFeed(ctx context.Context) ([]byte, string, error) {
	primaryData, err := l.download(ctx, l.feedURL)
	if err == nil {
		return primaryData, l.feedURL, nil
	}

	fallback := l.fallbackURL
	if fallback != "" && !strings.EqualFold(fallback, l.feedURL) {
		fallbackData, fbErr := l.download(ctx, fallback)
		if fbErr == nil {
			return fallbackData, fallback, nil
		}
		return nil, "", fmt.Errorf("%w; fallback %s failed: %v", err, fallback, fbErr)
	}

	return nil, "", err
}

func (l *Loader) download(ctx context.Context, url string) ([]byte, error) {
	if strings.TrimSpace(url) == "" {
		return nil, errors.New("gtfs loader: feed url is empty")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: build request for %s: %w", url, err)
	}
	resp, err := l.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: download feed %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("gtfs loader: download feed %s: status %d", url, resp.StatusCode)
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: read feed %s: %w", url, err)
	}
	return data, nil
}

func findFile(zr *zip.Reader, name string) (*zip.File, error) {
	for _, f := range zr.File {
		if strings.EqualFold(f.Name, name) {
			return f, nil
		}
	}
	return nil, fmt.Errorf("gtfs loader: file %s not found in archive", name)
}

func extractFeedVersion(zr *zip.Reader) string {
	file, err := findFile(zr, "feed_info.txt")
	if err != nil {
		return ""
	}
	rc, err := file.Open()
	if err != nil {
		return ""
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1
	header, err := reader.Read()
	if err != nil {
		return ""
	}
	idx := headerIndex(header)
	if versionIdx, ok := idx["feed_version"]; ok {
		record, err := reader.Read()
		if err == nil && versionIdx < len(record) {
			return record[versionIdx]
		}
	}
	return ""
}

func importStops(ctx context.Context, tx *sql.Tx, feedID int64, file *zip.File) (int, error) {
	rc, err := file.Open()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: open stops.txt: %w", err)
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1      // Permitir registros con diferente número de campos
	reader.LazyQuotes = true         // Permitir comillas no escapadas
	reader.TrimLeadingSpace = true   // Remover espacios al inicio
	
	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: read stops header: %w", err)
	}
	idx := headerIndex(header)
	required := []string{"stop_id", "stop_name", "stop_lat", "stop_lon"}
	for _, field := range required {
		if _, ok := idx[field]; !ok {
			return 0, fmt.Errorf("gtfs loader: missing column %s in stops.txt", field)
		}
	}

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO gtfs_stops 
        (stop_id, feed_id, code, name, description, latitude, longitude, zone_id, wheelchair_boarding)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: prepare insert stop: %w", err)
	}
	defer stmt.Close()

	count := 0
	skipped := 0
	errorCount := 0
	lineNum := 1 // Header es línea 1
	
	for {
		lineNum++
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			errorCount++
			// Log solo los primeros 20 errores de parsing
			if errorCount <= 20 {
				fmt.Printf("gtfs loader: error reading line %d: %v\n", lineNum, err)
			}
			// NO retornar error, continuar con la siguiente línea
			continue
		}
		
		stopID := safeField(record, idx, "stop_id")
		if stopID == "" {
			skipped++
			continue
		}
		name := safeField(record, idx, "stop_name")
		latStr := safeField(record, idx, "stop_lat")
		lonStr := safeField(record, idx, "stop_lon")
		lat, err := strconv.ParseFloat(latStr, 64)
		if err != nil {
			skipped++
			if skipped <= 20 {
				fmt.Printf("gtfs loader: line %d - invalid latitude '%s' for stop %s\n", lineNum, latStr, stopID)
			}
			continue
		}
		lon, err := strconv.ParseFloat(lonStr, 64)
		if err != nil {
			skipped++
			if skipped <= 20 {
				fmt.Printf("gtfs loader: line %d - invalid longitude '%s' for stop %s\n", lineNum, lonStr, stopID)
			}
			continue
		}
		desc := safeField(record, idx, "stop_desc")
		code := safeField(record, idx, "stop_code")
		zone := safeField(record, idx, "zone_id")
		wheelchair := 0
		if v := safeField(record, idx, "wheelchair_boarding"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil {
				wheelchair = parsed
			}
		}

		if _, err := stmt.ExecContext(ctx, stopID, feedID, code, name, desc, lat, lon, zone, wheelchair); err != nil {
			errorCount++
			// Log solo los primeros 10 errores de inserción
			if errorCount <= 30 {
				fmt.Printf("gtfs loader: line %d - error inserting stop %s: %v\n", lineNum, stopID, err)
			}
			// No retornar error, continuar con el siguiente
			continue
		}
		count++
		
		// Log progreso cada 50,000 registros para feeds grandes
		if count%50000 == 0 {
			fmt.Printf("gtfs loader: imported %d stops so far (line %d)...\n", count, lineNum)
		} else if count%10000 == 0 {
			fmt.Printf("gtfs loader: imported %d stops so far...\n", count)
		}
	}
	
	fmt.Printf("gtfs loader: import complete - success: %d, skipped: %d, errors: %d, total lines: %d\n", count, skipped, errorCount, lineNum)
	return count, nil
}

func headerIndex(header []string) map[string]int {
	idx := make(map[string]int, len(header))
	for i, field := range header {
		idx[strings.TrimSpace(strings.ToLower(field))] = i
	}
	return idx
}

func safeField(record []string, idx map[string]int, key string) string {
	if pos, ok := idx[key]; ok && pos < len(record) {
		return record[pos]
	}
	return ""
}
