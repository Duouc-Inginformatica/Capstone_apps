package handlers

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"
)

// CachedRoute representa una ruta en caché
type CachedRoute struct {
	Data      interface{}
	Timestamp time.Time
	ExpiresAt time.Time
}

// RouteCache maneja el almacenamiento en caché de rutas
type RouteCache struct {
	cache    map[string]*CachedRoute
	mu       sync.RWMutex
	ttl      time.Duration // Time to live para las rutas
	maxSize  int           // Máximo número de rutas en caché
}

// NewRouteCache crea una nueva instancia de caché de rutas
func NewRouteCache(ttl time.Duration, maxSize int) *RouteCache {
	cache := &RouteCache{
		cache:   make(map[string]*CachedRoute),
		ttl:     ttl,
		maxSize: maxSize,
	}
	
	// Iniciar limpieza periódica de rutas expiradas
	go cache.cleanupExpired()
	
	return cache
}

// generateKey crea una clave única para origen-destino
// Redondea las coordenadas a 4 decimales (~11 metros de precisión)
// para permitir hits de caché incluso con pequeñas variaciones GPS
func (rc *RouteCache) generateKey(originLat, originLon, destLat, destLon float64) string {
	// Redondear a 4 decimales
	key := fmt.Sprintf("%.4f,%.4f->%.4f,%.4f", originLat, originLon, destLat, destLon)
	
	// Usar hash para mantener las claves cortas
	hash := sha256.Sum256([]byte(key))
	return fmt.Sprintf("%x", hash[:16]) // Usar solo los primeros 16 bytes
}

// Get obtiene una ruta del caché si existe y no ha expirado
func (rc *RouteCache) Get(originLat, originLon, destLat, destLon float64) (interface{}, bool) {
	rc.mu.RLock()
	defer rc.mu.RUnlock()
	
	key := rc.generateKey(originLat, originLon, destLat, destLon)
	
	cached, exists := rc.cache[key]
	if !exists {
		return nil, false
	}
	
	// Verificar si ha expirado
	if time.Now().After(cached.ExpiresAt) {
		return nil, false
	}
	
	log.Printf("🎯 CACHE HIT: Ruta encontrada en caché (edad: %v)", time.Since(cached.Timestamp))
	return cached.Data, true
}

// Set almacena una ruta en el caché
func (rc *RouteCache) Set(originLat, originLon, destLat, destLon float64, data interface{}) {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	
	// Si el caché está lleno, eliminar la ruta más antigua
	if len(rc.cache) >= rc.maxSize {
		rc.evictOldest()
	}
	
	key := rc.generateKey(originLat, originLon, destLat, destLon)
	now := time.Now()
	
	rc.cache[key] = &CachedRoute{
		Data:      data,
		Timestamp: now,
		ExpiresAt: now.Add(rc.ttl),
	}
	
	log.Printf("💾 CACHE STORE: Ruta guardada en caché (TTL: %v, total en caché: %d)", rc.ttl, len(rc.cache))
}

// evictOldest elimina la ruta más antigua del caché
func (rc *RouteCache) evictOldest() {
	var oldestKey string
	var oldestTime time.Time
	
	for key, cached := range rc.cache {
		if oldestKey == "" || cached.Timestamp.Before(oldestTime) {
			oldestKey = key
			oldestTime = cached.Timestamp
		}
	}
	
	if oldestKey != "" {
		delete(rc.cache, oldestKey)
		log.Printf("🗑️  CACHE EVICT: Ruta más antigua eliminada del caché")
	}
}

// cleanupExpired limpia periódicamente las rutas expiradas
func (rc *RouteCache) cleanupExpired() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	
	for range ticker.C {
		rc.mu.Lock()
		
		now := time.Now()
		expiredKeys := []string{}
		
		for key, cached := range rc.cache {
			if now.After(cached.ExpiresAt) {
				expiredKeys = append(expiredKeys, key)
			}
		}
		
		for _, key := range expiredKeys {
			delete(rc.cache, key)
		}
		
		if len(expiredKeys) > 0 {
			log.Printf("🧹 CACHE CLEANUP: %d rutas expiradas eliminadas", len(expiredKeys))
		}
		
		rc.mu.Unlock()
	}
}

// Clear limpia todo el caché
func (rc *RouteCache) Clear() {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	
	rc.cache = make(map[string]*CachedRoute)
	log.Printf("🗑️  CACHE CLEAR: Todo el caché ha sido limpiado")
}

// Stats devuelve estadísticas del caché
func (rc *RouteCache) Stats() map[string]interface{} {
	rc.mu.RLock()
	defer rc.mu.RUnlock()
	
	totalSize := 0
	activeCount := 0
	now := time.Now()
	
	for _, cached := range rc.cache {
		// Calcular tamaño aproximado
		data, _ := json.Marshal(cached.Data)
		totalSize += len(data)
		
		if now.Before(cached.ExpiresAt) {
			activeCount++
		}
	}
	
	return map[string]interface{}{
		"total_entries":  len(rc.cache),
		"active_entries": activeCount,
		"size_bytes":     totalSize,
		"max_size":       rc.maxSize,
		"ttl_minutes":    rc.ttl.Minutes(),
	}
}
