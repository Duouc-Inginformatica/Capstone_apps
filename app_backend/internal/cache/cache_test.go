package cache

import (
	"testing"
	"time"
)

func TestCacheBasicOperations(t *testing.T) {
	cache := NewCache(5*time.Minute, 10*time.Minute)
	defer cache.Stop()

	// Test Set y Get
	cache.Set("key1", "value1")
	
	value, found := cache.Get("key1")
	if !found {
		t.Error("Expected to find key1")
	}
	if value != "value1" {
		t.Errorf("Expected 'value1', got %v", value)
	}

	// Test Get de key inexistente
	_, found = cache.Get("nonexistent")
	if found {
		t.Error("Expected not to find nonexistent key")
	}
}

func TestCacheExpiration(t *testing.T) {
	cache := NewCache(5*time.Minute, 10*time.Minute)
	defer cache.Stop()

	// Configurar item con TTL corto
	cache.SetWithTTL("expiring", "value", 100*time.Millisecond)

	// Debería encontrarse inmediatamente
	_, found := cache.Get("expiring")
	if !found {
		t.Error("Expected to find item before expiration")
	}

	// Esperar a que expire
	time.Sleep(150 * time.Millisecond)

	// No debería encontrarse después de expirar
	_, found = cache.Get("expiring")
	if found {
		t.Error("Expected item to be expired")
	}
}

func TestCacheDelete(t *testing.T) {
	cache := NewCache(5*time.Minute, 10*time.Minute)
	defer cache.Stop()

	cache.Set("key1", "value1")
	cache.Delete("key1")

	_, found := cache.Get("key1")
	if found {
		t.Error("Expected key to be deleted")
	}
}

func TestCacheDeletePrefix(t *testing.T) {
	cache := NewCache(5*time.Minute, 10*time.Minute)
	defer cache.Stop()

	cache.Set("stop:PA123", "data1")
	cache.Set("stop:PA456", "data2")
	cache.Set("route:506", "data3")

	// Eliminar todas las keys con prefijo "stop:"
	deleted := cache.DeletePrefix("stop:")
	
	if deleted != 2 {
		t.Errorf("Expected to delete 2 items, got %d", deleted)
	}

	_, found := cache.Get("stop:PA123")
	if found {
		t.Error("Expected stop:PA123 to be deleted")
	}

	// route:506 no debería eliminarse
	_, found = cache.Get("route:506")
	if !found {
		t.Error("Expected route:506 to remain")
	}
}

func TestCacheClear(t *testing.T) {
	cache := NewCache(5*time.Minute, 10*time.Minute)
	defer cache.Stop()

	cache.Set("key1", "value1")
	cache.Set("key2", "value2")

	if cache.Count() != 2 {
		t.Errorf("Expected count 2, got %d", cache.Count())
	}

	cache.Clear()

	if cache.Count() != 0 {
		t.Errorf("Expected count 0 after clear, got %d", cache.Count())
	}
}

func TestCacheStats(t *testing.T) {
	cache := NewCache(5*time.Minute, 10*time.Minute)
	defer cache.Stop()

	cache.Set("key1", "value1")
	cache.SetWithTTL("key2", "value2", 50*time.Millisecond)

	stats := cache.GetStats()
	if stats.TotalItems != 2 {
		t.Errorf("Expected 2 total items, got %d", stats.TotalItems)
	}

	// Esperar a que expire key2
	time.Sleep(100 * time.Millisecond)

	stats = cache.GetStats()
	if stats.ExpiredItems != 1 {
		t.Errorf("Expected 1 expired item, got %d", stats.ExpiredItems)
	}
	if stats.ValidItems != 1 {
		t.Errorf("Expected 1 valid item, got %d", stats.ValidItems)
	}
}

func TestCacheConcurrency(t *testing.T) {
	cache := NewCache(5*time.Minute, 10*time.Minute)
	defer cache.Stop()

	done := make(chan bool)

	// Escritura concurrente
	for i := 0; i < 10; i++ {
		go func(n int) {
			for j := 0; j < 100; j++ {
				cache.Set(string(rune(n)), j)
			}
			done <- true
		}(i)
	}

	// Lectura concurrente
	for i := 0; i < 10; i++ {
		go func(n int) {
			for j := 0; j < 100; j++ {
				cache.Get(string(rune(n)))
			}
			done <- true
		}(i)
	}

	// Esperar a que terminen todas las goroutines
	for i := 0; i < 20; i++ {
		<-done
	}

	// Si llegamos aquí sin race conditions, el test pasa
}

func BenchmarkCacheSet(b *testing.B) {
	cache := NewCache(5*time.Minute, 10*time.Minute)
	defer cache.Stop()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		cache.Set("key", "value")
	}
}

func BenchmarkCacheGet(b *testing.B) {
	cache := NewCache(5*time.Minute, 10*time.Minute)
	defer cache.Stop()

	cache.Set("key", "value")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		cache.Get("key")
	}
}

func BenchmarkCacheGetMiss(b *testing.B) {
	cache := NewCache(5*time.Minute, 10*time.Minute)
	defer cache.Stop()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		cache.Get("nonexistent")
	}
}
