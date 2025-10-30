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
	
	// Buscar todos los archivos necesarios
	stopsFile, err := findFile(zr, "stops.txt")
	if err != nil {
		return nil, err
	}
	
	routesFile, err := findFile(zr, "routes.txt")
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: routes.txt not found: %w", err)
	}
	
	tripsFile, err := findFile(zr, "trips.txt")
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: trips.txt not found: %w", err)
	}
	
	stopTimesFile, err := findFile(zr, "stop_times.txt")
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: stop_times.txt not found: %w", err)
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("gtfs loader: begin tx: %w", err)
	}
	defer tx.Rollback()

	// Limpiar tablas en orden (respetando foreign keys)
	fmt.Println("gtfs loader: clearing old data...")
	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_frequencies"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear frequencies: %w", err)
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_transfers"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear transfers: %w", err)
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_calendar_dates"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear calendar_dates: %w", err)
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_calendar"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear calendar: %w", err)
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_shapes"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear shapes: %w", err)
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_stop_times"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear stop_times: %w", err)
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_trips"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear trips: %w", err)
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_routes"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear routes: %w", err)
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_stops"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear stops: %w", err)
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM gtfs_agencies"); err != nil {
		return nil, fmt.Errorf("gtfs loader: clear agencies: %w", err)
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

	// Importar en orden (respetando foreign keys)
	fmt.Println("🏢 Importing agencies...")
	agenciesCount := 0
	if agenciesFile, err := findFile(zr, "agency.txt"); err == nil {
		agenciesCount, err = importAgencies(ctx, tx, feedID, agenciesFile)
		if err != nil {
			fmt.Printf("⚠️ Warning importing agencies: %v\n", err)
		}
	} else {
		fmt.Println("⚠️ agency.txt not found (optional)")
	}
	
	fmt.Println("📍 Importing stops...")
	stopsCount, err := importStops(ctx, tx, feedID, stopsFile)
	if err != nil {
		return nil, err
	}
	
	fmt.Println("🚌 Importing routes...")
	routesCount, err := importRoutes(ctx, tx, feedID, routesFile)
	if err != nil {
		return nil, err
	}
	
	fmt.Println("🗺️ Importing shapes...")
	shapesCount := 0
	if shapesFile, err := findFile(zr, "shapes.txt"); err == nil {
		shapesCount, err = importShapes(ctx, tx, feedID, shapesFile)
		if err != nil {
			fmt.Printf("⚠️ Warning importing shapes: %v\n", err)
		}
	} else {
		fmt.Println("⚠️ shapes.txt not found (optional but recommended)")
	}
	
	fmt.Println("🚏 Importing trips...")
	tripsCount, err := importTrips(ctx, tx, feedID, tripsFile)
	if err != nil {
		return nil, err
	}
	
	fmt.Println("⏰ Importing stop times (this may take several minutes)...")
	stopTimesCount, err := importStopTimes(ctx, tx, feedID, stopTimesFile)
	if err != nil {
		return nil, err
	}
	
	fmt.Println("📅 Importing calendar...")
	calendarCount := 0
	if calendarFile, err := findFile(zr, "calendar.txt"); err == nil {
		calendarCount, err = importCalendar(ctx, tx, feedID, calendarFile)
		if err != nil {
			fmt.Printf("⚠️ Warning importing calendar: %v\n", err)
		}
	} else {
		fmt.Println("⚠️ calendar.txt not found (optional)")
	}
	
	fmt.Println("📆 Importing calendar dates...")
	calendarDatesCount := 0
	if calendarDatesFile, err := findFile(zr, "calendar_dates.txt"); err == nil {
		calendarDatesCount, err = importCalendarDates(ctx, tx, feedID, calendarDatesFile)
		if err != nil {
			fmt.Printf("⚠️ Warning importing calendar_dates: %v\n", err)
		}
	} else {
		fmt.Println("⚠️ calendar_dates.txt not found (optional)")
	}
	
	fmt.Println("🔄 Importing transfers...")
	transfersCount := 0
	if transfersFile, err := findFile(zr, "transfers.txt"); err == nil {
		transfersCount, err = importTransfers(ctx, tx, feedID, transfersFile)
		if err != nil {
			fmt.Printf("⚠️ Warning importing transfers: %v\n", err)
		}
	} else {
		fmt.Println("⚠️ transfers.txt not found (optional)")
	}
	
	fmt.Println("⏱️ Importing frequencies...")
	frequenciesCount := 0
	if frequenciesFile, err := findFile(zr, "frequencies.txt"); err == nil {
		frequenciesCount, err = importFrequencies(ctx, tx, feedID, frequenciesFile)
		if err != nil {
			fmt.Printf("⚠️ Warning importing frequencies: %v\n", err)
		}
	} else {
		fmt.Println("⚠️ frequencies.txt not found (optional)")
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("gtfs loader: commit: %w", err)
	}

	fmt.Printf("✅ GTFS import complete:\n")
	fmt.Printf("   - Agencies: %d\n", agenciesCount)
	fmt.Printf("   - Stops: %d\n", stopsCount)
	fmt.Printf("   - Routes: %d\n", routesCount)
	fmt.Printf("   - Shapes: %d\n", shapesCount)
	fmt.Printf("   - Trips: %d\n", tripsCount)
	fmt.Printf("   - Stop Times: %d\n", stopTimesCount)
	fmt.Printf("   - Calendar: %d\n", calendarCount)
	fmt.Printf("   - Calendar Dates: %d\n", calendarDatesCount)
	fmt.Printf("   - Transfers: %d\n", transfersCount)
	fmt.Printf("   - Frequencies: %d\n", frequenciesCount)

	summary := &Summary{
		FeedVersion:   feedVersion,
		StopsImported: stopsCount,
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

// importRoutes imports routes.txt into gtfs_routes table
func importRoutes(ctx context.Context, tx *sql.Tx, feedID int64, file *zip.File) (int, error) {
	rc, err := file.Open()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: open routes.txt: %w", err)
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true

	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: read routes header: %w", err)
	}
	idx := headerIndex(header)

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO gtfs_routes 
        (route_id, feed_id, short_name, long_name, type, color, text_color)
        VALUES (?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: prepare insert route: %w", err)
	}
	defer stmt.Close()

	count := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			continue
		}

		routeID := safeField(record, idx, "route_id")
		if routeID == "" {
			continue
		}

		shortName := safeField(record, idx, "route_short_name")
		longName := safeField(record, idx, "route_long_name")
		routeType := 0
		if v := safeField(record, idx, "route_type"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil {
				routeType = parsed
			}
		}
		color := safeField(record, idx, "route_color")
		textColor := safeField(record, idx, "route_text_color")

		if _, err := stmt.ExecContext(ctx, routeID, feedID, shortName, longName, routeType, color, textColor); err != nil {
			continue
		}
		count++

		if count%1000 == 0 {
			fmt.Printf("   imported %d routes...\n", count)
		}
	}

	fmt.Printf("   routes import complete: %d routes\n", count)
	return count, nil
}

// importTrips imports trips.txt into gtfs_trips table
func importTrips(ctx context.Context, tx *sql.Tx, feedID int64, file *zip.File) (int, error) {
	rc, err := file.Open()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: open trips.txt: %w", err)
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true

	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: read trips header: %w", err)
	}
	idx := headerIndex(header)

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO gtfs_trips 
        (trip_id, feed_id, route_id, service_id, headsign, direction_id, shape_id)
        VALUES (?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: prepare insert trip: %w", err)
	}
	defer stmt.Close()

	count := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			continue
		}

		tripID := safeField(record, idx, "trip_id")
		routeID := safeField(record, idx, "route_id")
		if tripID == "" || routeID == "" {
			continue
		}

		serviceID := safeField(record, idx, "service_id")
		headsign := safeField(record, idx, "trip_headsign")
		directionID := 0
		if v := safeField(record, idx, "direction_id"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil {
				directionID = parsed
			}
		}
		shapeID := safeField(record, idx, "shape_id")

		if _, err := stmt.ExecContext(ctx, tripID, feedID, routeID, serviceID, headsign, directionID, shapeID); err != nil {
			continue
		}
		count++

		if count%10000 == 0 {
			fmt.Printf("   imported %d trips...\n", count)
		}
	}

	fmt.Printf("   trips import complete: %d trips\n", count)
	return count, nil
}

// importStopTimes imports stop_times.txt into gtfs_stop_times table
func importStopTimes(ctx context.Context, tx *sql.Tx, feedID int64, file *zip.File) (int, error) {
	rc, err := file.Open()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: open stop_times.txt: %w", err)
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true

	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: read stop_times header: %w", err)
	}
	idx := headerIndex(header)

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO gtfs_stop_times 
        (feed_id, trip_id, arrival_time, departure_time, stop_id, stop_sequence)
        VALUES (?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: prepare insert stop_time: %w", err)
	}
	defer stmt.Close()

	count := 0
	skipped := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			skipped++
			continue
		}

		tripID := safeField(record, idx, "trip_id")
		stopID := safeField(record, idx, "stop_id")
		if tripID == "" || stopID == "" {
			skipped++
			continue
		}

		arrivalTime := safeField(record, idx, "arrival_time")
		departureTime := safeField(record, idx, "departure_time")
		stopSeq := 0
		if v := safeField(record, idx, "stop_sequence"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil {
				stopSeq = parsed
			}
		}

		if _, err := stmt.ExecContext(ctx, feedID, tripID, arrivalTime, departureTime, stopID, stopSeq); err != nil {
			skipped++
			continue
		}
		count++

		if count%100000 == 0 {
			fmt.Printf("   imported %d stop times...\n", count)
		}
	}

	fmt.Printf("   stop_times import complete: %d records (skipped: %d)\n", count, skipped)
	return count, nil
}

// importAgencies imports agency.txt into gtfs_agencies table
func importAgencies(ctx context.Context, tx *sql.Tx, feedID int64, file *zip.File) (int, error) {
	rc, err := file.Open()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: open agency.txt: %w", err)
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true

	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: read agency header: %w", err)
	}
	idx := headerIndex(header)

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO gtfs_agencies 
        (agency_id, feed_id, agency_name, agency_url, agency_timezone, agency_lang, agency_phone)
        VALUES (?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: prepare insert agency: %w", err)
	}
	defer stmt.Close()

	count := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			continue
		}

		agencyID := safeField(record, idx, "agency_id")
		agencyName := safeField(record, idx, "agency_name")
		agencyURL := safeField(record, idx, "agency_url")
		agencyTimezone := safeField(record, idx, "agency_timezone")
		
		if agencyName == "" || agencyURL == "" || agencyTimezone == "" {
			continue
		}

		agencyLang := safeField(record, idx, "agency_lang")
		agencyPhone := safeField(record, idx, "agency_phone")

		if _, err := stmt.ExecContext(ctx, agencyID, feedID, agencyName, agencyURL, agencyTimezone, agencyLang, agencyPhone); err != nil {
			continue
		}
		count++
	}

	fmt.Printf("   agencies import complete: %d agencies\n", count)
	return count, nil
}

// importShapes imports shapes.txt into gtfs_shapes table
func importShapes(ctx context.Context, tx *sql.Tx, feedID int64, file *zip.File) (int, error) {
	rc, err := file.Open()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: open shapes.txt: %w", err)
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true

	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: read shapes header: %w", err)
	}
	idx := headerIndex(header)

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO gtfs_shapes 
        (feed_id, shape_id, shape_pt_lat, shape_pt_lon, shape_pt_sequence, shape_dist_traveled)
        VALUES (?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: prepare insert shape: %w", err)
	}
	defer stmt.Close()

	count := 0
	skipped := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			skipped++
			continue
		}

		shapeID := safeField(record, idx, "shape_id")
		latStr := safeField(record, idx, "shape_pt_lat")
		lonStr := safeField(record, idx, "shape_pt_lon")
		seqStr := safeField(record, idx, "shape_pt_sequence")

		if shapeID == "" || latStr == "" || lonStr == "" || seqStr == "" {
			skipped++
			continue
		}

		lat, err := strconv.ParseFloat(latStr, 64)
		if err != nil {
			skipped++
			continue
		}
		lon, err := strconv.ParseFloat(lonStr, 64)
		if err != nil {
			skipped++
			continue
		}
		seq, err := strconv.Atoi(seqStr)
		if err != nil {
			skipped++
			continue
		}

		var distTraveled *float64
		if distStr := safeField(record, idx, "shape_dist_traveled"); distStr != "" {
			if dist, err := strconv.ParseFloat(distStr, 32); err == nil {
				d := float64(dist)
				distTraveled = &d
			}
		}

		if _, err := stmt.ExecContext(ctx, feedID, shapeID, lat, lon, seq, distTraveled); err != nil {
			skipped++
			continue
		}
		count++

		if count%50000 == 0 {
			fmt.Printf("   imported %d shape points...\n", count)
		}
	}

	fmt.Printf("   shapes import complete: %d points (skipped: %d)\n", count, skipped)
	return count, nil
}

// importCalendar imports calendar.txt into gtfs_calendar table
func importCalendar(ctx context.Context, tx *sql.Tx, feedID int64, file *zip.File) (int, error) {
	rc, err := file.Open()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: open calendar.txt: %w", err)
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true

	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: read calendar header: %w", err)
	}
	idx := headerIndex(header)

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO gtfs_calendar 
        (service_id, feed_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: prepare insert calendar: %w", err)
	}
	defer stmt.Close()

	count := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			continue
		}

		serviceID := safeField(record, idx, "service_id")
		if serviceID == "" {
			continue
		}

		monday := safeField(record, idx, "monday") == "1"
		tuesday := safeField(record, idx, "tuesday") == "1"
		wednesday := safeField(record, idx, "wednesday") == "1"
		thursday := safeField(record, idx, "thursday") == "1"
		friday := safeField(record, idx, "friday") == "1"
		saturday := safeField(record, idx, "saturday") == "1"
		sunday := safeField(record, idx, "sunday") == "1"
		startDate := safeField(record, idx, "start_date")
		endDate := safeField(record, idx, "end_date")

		if _, err := stmt.ExecContext(ctx, serviceID, feedID, monday, tuesday, wednesday, thursday, friday, saturday, sunday, startDate, endDate); err != nil {
			continue
		}
		count++
	}

	fmt.Printf("   calendar import complete: %d services\n", count)
	return count, nil
}

// importCalendarDates imports calendar_dates.txt into gtfs_calendar_dates table
func importCalendarDates(ctx context.Context, tx *sql.Tx, feedID int64, file *zip.File) (int, error) {
	rc, err := file.Open()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: open calendar_dates.txt: %w", err)
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true

	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: read calendar_dates header: %w", err)
	}
	idx := headerIndex(header)

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO gtfs_calendar_dates 
        (service_id, feed_id, date, exception_type)
        VALUES (?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: prepare insert calendar_date: %w", err)
	}
	defer stmt.Close()

	count := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			continue
		}

		serviceID := safeField(record, idx, "service_id")
		date := safeField(record, idx, "date")
		exceptionTypeStr := safeField(record, idx, "exception_type")

		if serviceID == "" || date == "" || exceptionTypeStr == "" {
			continue
		}

		exceptionType, err := strconv.Atoi(exceptionTypeStr)
		if err != nil {
			continue
		}

		if _, err := stmt.ExecContext(ctx, serviceID, feedID, date, exceptionType); err != nil {
			continue
		}
		count++
	}

	fmt.Printf("   calendar_dates import complete: %d exceptions\n", count)
	return count, nil
}

// importTransfers imports transfers.txt into gtfs_transfers table
func importTransfers(ctx context.Context, tx *sql.Tx, feedID int64, file *zip.File) (int, error) {
	rc, err := file.Open()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: open transfers.txt: %w", err)
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true

	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: read transfers header: %w", err)
	}
	idx := headerIndex(header)

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO gtfs_transfers 
        (feed_id, from_stop_id, to_stop_id, transfer_type, min_transfer_time)
        VALUES (?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: prepare insert transfer: %w", err)
	}
	defer stmt.Close()

	count := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			continue
		}

		fromStopID := safeField(record, idx, "from_stop_id")
		toStopID := safeField(record, idx, "to_stop_id")

		if fromStopID == "" || toStopID == "" {
			continue
		}

		transferType := 0
		if v := safeField(record, idx, "transfer_type"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil {
				transferType = parsed
			}
		}

		var minTransferTime *int
		if v := safeField(record, idx, "min_transfer_time"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil {
				minTransferTime = &parsed
			}
		}

		if _, err := stmt.ExecContext(ctx, feedID, fromStopID, toStopID, transferType, minTransferTime); err != nil {
			continue
		}
		count++
	}

	fmt.Printf("   transfers import complete: %d transfers\n", count)
	return count, nil
}

// importFrequencies imports frequencies.txt into gtfs_frequencies table
func importFrequencies(ctx context.Context, tx *sql.Tx, feedID int64, file *zip.File) (int, error) {
	rc, err := file.Open()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: open frequencies.txt: %w", err)
	}
	defer rc.Close()

	reader := csv.NewReader(rc)
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true

	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: read frequencies header: %w", err)
	}
	idx := headerIndex(header)

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO gtfs_frequencies 
        (trip_id, feed_id, start_time, end_time, headway_secs, exact_times)
        VALUES (?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("gtfs loader: prepare insert frequency: %w", err)
	}
	defer stmt.Close()

	count := 0
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			continue
		}

		tripID := safeField(record, idx, "trip_id")
		startTime := safeField(record, idx, "start_time")
		endTime := safeField(record, idx, "end_time")
		headwaySecsStr := safeField(record, idx, "headway_secs")

		if tripID == "" || startTime == "" || endTime == "" || headwaySecsStr == "" {
			continue
		}

		headwaySecs, err := strconv.Atoi(headwaySecsStr)
		if err != nil {
			continue
		}

		exactTimes := 0
		if v := safeField(record, idx, "exact_times"); v == "1" {
			exactTimes = 1
		}

		if _, err := stmt.ExecContext(ctx, tripID, feedID, startTime, endTime, headwaySecs, exactTimes); err != nil {
			continue
		}
		count++
	}

	fmt.Printf("   frequencies import complete: %d frequency rules\n", count)
	return count, nil
}
