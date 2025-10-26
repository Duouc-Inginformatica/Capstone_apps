#!/usr/bin/env pwsh
# Script para probar el scraper de Red.cl

Write-Host "🧪 Test del Scraper Red.cl - WayFindCL" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Verificar que el servidor esté corriendo
$serverUrl = "http://localhost:8080"
Write-Host "🔍 Verificando servidor en $serverUrl..." -ForegroundColor Yellow

try {
    $healthCheck = Invoke-RestMethod -Uri "$serverUrl/health" -Method GET -TimeoutSec 3
    Write-Host "✅ Servidor activo" -ForegroundColor Green
    Write-Host "   Status: $($healthCheck.status)" -ForegroundColor Gray
} catch {
    Write-Host "❌ Error: El servidor no está corriendo en $serverUrl" -ForegroundColor Red
    Write-Host "   Ejecuta: go run cmd/server/main.go" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n" + "="*60 -ForegroundColor Cyan

# Test 1: Paradero PC615 (ejemplo común en Santiago)
Write-Host "`n📍 TEST 1: Consultar paradero PC615" -ForegroundColor Cyan
Write-Host "   Endpoint: GET /api/bus-arrivals/PC615`n" -ForegroundColor Gray

try {
    $response = Invoke-RestMethod -Uri "$serverUrl/api/bus-arrivals/PC615" -Method GET -TimeoutSec 45
    
    Write-Host "✅ Respuesta recibida" -ForegroundColor Green
    Write-Host "   Paradero: $($response.stop_code) - $($response.stop_name)" -ForegroundColor White
    Write-Host "   Última actualización: $($response.last_updated)" -ForegroundColor Gray
    Write-Host "   Buses encontrados: $($response.arrivals.Count)`n" -ForegroundColor Yellow
    
    if ($response.arrivals.Count -gt 0) {
        Write-Host "   🚌 Próximas llegadas:" -ForegroundColor White
        Write-Host "   " + ("-"*56) -ForegroundColor Gray
        Write-Host "   Ruta    | Destino              | Distancia | Tiempo  | Estado" -ForegroundColor Gray
        Write-Host "   " + ("-"*56) -ForegroundColor Gray
        
        foreach ($bus in $response.arrivals | Select-Object -First 5) {
            $route = $bus.route_number.PadRight(7)
            $direction = $bus.direction.Substring(0, [Math]::Min(20, $bus.direction.Length)).PadRight(20)
            $distance = "$($bus.distance_km) km".PadRight(9)
            $time = "$($bus.estimated_minutes) min".PadRight(7)
            $status = $bus.status
            
            Write-Host "   $route | $direction | $distance | $time | $status" -ForegroundColor Cyan
        }
        
        if ($response.arrivals.Count -gt 5) {
            Write-Host "   ... y $($response.arrivals.Count - 5) buses más" -ForegroundColor Gray
        }
    } else {
        Write-Host "   ⚠️  No se encontraron buses próximos" -ForegroundColor Yellow
    }
    
    # Mostrar JSON completo
    Write-Host "`n   📄 JSON completo:" -ForegroundColor Gray
    $jsonOutput = $response | ConvertTo-Json -Depth 5
    Write-Host $jsonOutput -ForegroundColor DarkGray
    
} catch {
    Write-Host "❌ Error en la consulta:" -ForegroundColor Red
    Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) {
        Write-Host "   Detalles: $($_.ErrorDetails.Message)" -ForegroundColor Red
    }
}

Write-Host "`n" + "="*60 -ForegroundColor Cyan

# Test 2: Paradero PA421 (otro ejemplo común)
Write-Host "`n📍 TEST 2: Consultar paradero PA421" -ForegroundColor Cyan
Write-Host "   Endpoint: GET /api/bus-arrivals/PA421`n" -ForegroundColor Gray

try {
    $response2 = Invoke-RestMethod -Uri "$serverUrl/api/bus-arrivals/PA421" -Method GET -TimeoutSec 45
    
    Write-Host "✅ Respuesta recibida" -ForegroundColor Green
    Write-Host "   Paradero: $($response2.stop_code) - $($response2.stop_name)" -ForegroundColor White
    Write-Host "   Buses encontrados: $($response2.arrivals.Count)" -ForegroundColor Yellow
    
    if ($response2.arrivals.Count -gt 0) {
        Write-Host "`n   🚌 Primeros 3 buses:" -ForegroundColor White
        foreach ($bus in $response2.arrivals | Select-Object -First 3) {
            Write-Host "      • Ruta $($bus.route_number): $($bus.direction)" -ForegroundColor Cyan
            Write-Host "        $($bus.distance_km) km, $($bus.estimated_minutes) min - $($bus.status)" -ForegroundColor Gray
        }
    }
    
} catch {
    Write-Host "❌ Error en la consulta:" -ForegroundColor Red
    Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n" + "="*60 -ForegroundColor Cyan

# Test 3: Paradero inválido (para probar manejo de errores)
Write-Host "`n📍 TEST 3: Consultar paradero inválido (XXXXX)" -ForegroundColor Cyan
Write-Host "   Endpoint: GET /api/bus-arrivals/XXXXX`n" -ForegroundColor Gray

try {
    $response3 = Invoke-RestMethod -Uri "$serverUrl/api/bus-arrivals/XXXXX" -Method GET -TimeoutSec 45
    Write-Host "   Respuesta: $($response3 | ConvertTo-Json)" -ForegroundColor Yellow
} catch {
    $statusCode = $_.Exception.Response.StatusCode.Value__
    Write-Host "✅ Error esperado (código $statusCode)" -ForegroundColor Green
    if ($_.ErrorDetails.Message) {
        $errorJson = $_.ErrorDetails.Message | ConvertFrom-Json
        Write-Host "   Mensaje: $($errorJson.error)" -ForegroundColor Gray
        if ($errorJson.message) {
            Write-Host "   Detalle: $($errorJson.message)" -ForegroundColor Gray
        }
    }
}

Write-Host "`n" + "="*60 -ForegroundColor Cyan
Write-Host "`n✅ Tests completados`n" -ForegroundColor Green

# Información adicional
Write-Host "💡 Paraderos de ejemplo en Santiago:" -ForegroundColor Yellow
Write-Host "   • PC615 - Providencia" -ForegroundColor Gray
Write-Host "   • PA421 - Las Condes" -ForegroundColor Gray
Write-Host "   • PI407 - Estación Metro" -ForegroundColor Gray
Write-Host "   • PB108 - Bellavista" -ForegroundColor Gray
Write-Host "   • PJ501 - Plaza de Armas`n" -ForegroundColor Gray

Write-Host "📝 Uso desde curl:" -ForegroundColor Yellow
Write-Host '   curl "http://localhost:8080/api/bus-arrivals/PC615"' -ForegroundColor Gray
Write-Host "`n"
