# ============================================================================
# Script de Inicio Automatico del Backend - WayFindCL
# ============================================================================
# Verifica configuracion de GraphHopper y limpia cache si es necesario
# ============================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  WayFindCL Backend - Inicio Automatico" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Verificar que estamos en el directorio correcto
if (-not (Test-Path "go.mod")) {
    Write-Host "[ERROR] Ejecuta este script desde el directorio app_backend" -ForegroundColor Red
    exit 1
}

# ============================================================================
# 1. VERIFICAR CONFIGURACION DE GRAPHHOPPER
# ============================================================================
Write-Host "[VERIFICACION] Verificando configuracion de GraphHopper..." -ForegroundColor Yellow

if (-not (Test-Path "graphhopper-config.yml")) {
    Write-Host "[ERROR] No se encuentra graphhopper-config.yml" -ForegroundColor Red
    exit 1
}

# Leer perfiles configurados
$configContent = Get-Content "graphhopper-config.yml" -Raw
$profilesMatch = [regex]::Matches($configContent, '^\s*-\s*name:\s*(\w+)', [System.Text.RegularExpressions.RegexOptions]::Multiline)

$configuredProfiles = @()
foreach ($match in $profilesMatch) {
    $profileName = $match.Groups[1].Value
    $configuredProfiles += $profileName
}

Write-Host "   Perfiles configurados: $($configuredProfiles -join ', ')" -ForegroundColor White

# ============================================================================
# 2. VERIFICAR CACHÉ DE GRAPHHOPPER
# ============================================================================
$graphCachePath = "graph-cache"
$needsCleanup = $false

if (Test-Path $graphCachePath) {
    Write-Host "[VERIFICACION] Verificando cache existente..." -ForegroundColor Yellow
    
    # Buscar archivo properties para verificar perfiles en cache
    $propertiesFile = Get-ChildItem -Path $graphCachePath -Filter "properties" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if ($propertiesFile) {
        $propertiesContent = Get-Content $propertiesFile.FullName -Raw -ErrorAction SilentlyContinue
        
        if ($propertiesContent) {
            # Buscar perfiles en el cache
            if ($propertiesContent -match "profiles=([^\r\n]+)") {
                $cachedProfilesRaw = $matches[1]
                Write-Host "   Perfiles en cache: $cachedProfilesRaw" -ForegroundColor White
                
                # Extraer nombres de perfiles del formato "foot|123,car|456,pt|789"
                $cachedProfiles = @()
                $profileMatches = [regex]::Matches($cachedProfilesRaw, '(\w+)\|[^,]+')
                foreach ($match in $profileMatches) {
                    $cachedProfiles += $match.Groups[1].Value
                }
                
                # Comparar perfiles
                $profilesMatch = $true
                foreach ($profile in $configuredProfiles) {
                    if ($profile -notin $cachedProfiles) {
                        $profilesMatch = $false
                        Write-Host "   [ADVERTENCIA] Perfil '$profile' en config pero no en cache" -ForegroundColor Yellow
                    }
                }
                
                foreach ($profile in $cachedProfiles) {
                    if ($profile -notin $configuredProfiles) {
                        $profilesMatch = $false
                        Write-Host "   [ADVERTENCIA] Perfil '$profile' en cache pero no en config" -ForegroundColor Yellow
                    }
                }
                
                if (-not $profilesMatch) {
                    $needsCleanup = $true
                }
            }
        }
    } else {
        Write-Host "   [ADVERTENCIA] No se encontro archivo properties, asumiendo cache corrupto" -ForegroundColor Yellow
        $needsCleanup = $true
    }
} else {
    Write-Host "   [INFO] No existe cache, se creara uno nuevo" -ForegroundColor Cyan
}

# ============================================================================
# 3. LIMPIAR CACHE SI ES NECESARIO
# ============================================================================
if ($needsCleanup) {
    Write-Host ""
    Write-Host "[LIMPIEZA] Limpiando cache incompatible..." -ForegroundColor Yellow
    
    try {
        if (Test-Path $graphCachePath) {
            Remove-Item -Path $graphCachePath -Recurse -Force -ErrorAction Stop
            Write-Host "   [OK] Cache eliminado correctamente" -ForegroundColor Green
        }
    } catch {
        Write-Host "   [ERROR] Error al eliminar cache: $_" -ForegroundColor Red
        Write-Host "   [INFO] Intenta eliminar manualmente: rm -r -fo graph-cache" -ForegroundColor Yellow
        exit 1
    }
    
    Write-Host "   [INFO] GraphHopper regenerara el cache al iniciar" -ForegroundColor Cyan
    Write-Host "   [ESPERA] Esto puede tomar varios minutos..." -ForegroundColor Cyan
} else {
    Write-Host "   [OK] Cache compatible con configuracion actual" -ForegroundColor Green
}

# ============================================================================
# 4. VERIFICAR DATOS OSM Y GTFS
# ============================================================================
Write-Host ""
Write-Host "[VERIFICACION] Verificando archivos de datos..." -ForegroundColor Yellow

$osmFile = "data/santiago.osm.pbf"
$gtfsFile = "data/gtfs-santiago.zip"

if (-not (Test-Path $osmFile)) {
    Write-Host "   [ADVERTENCIA] No se encuentra $osmFile" -ForegroundColor Yellow
    Write-Host "   [INFO] Descargalo desde: https://download.geofabrik.de/south-america/chile.html" -ForegroundColor Cyan
}

if (-not (Test-Path $gtfsFile)) {
    Write-Host "   [ADVERTENCIA] No se encuentra $gtfsFile" -ForegroundColor Yellow
    Write-Host "   [INFO] Descarga los datos GTFS de Red Metropolitana de Movilidad" -ForegroundColor Cyan
}

# ============================================================================
# 5. VERIFICAR GRAPHHOPPER JAR
# ============================================================================
$ghJar = "graphhopper-web-11.0.jar"
if (-not (Test-Path $ghJar)) {
    Write-Host ""
    Write-Host "[ADVERTENCIA] No se encuentra $ghJar" -ForegroundColor Yellow
    Write-Host "   El servidor Go intentara iniciarlo pero puede fallar" -ForegroundColor Yellow
}

# ============================================================================
# 6. INICIAR BACKEND
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  [INICIO] Iniciando Backend..." -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Iniciar servidor Go
try {
    go run .\cmd\server\
} catch {
    Write-Host ""
    Write-Host "[ERROR] Error al iniciar el backend: $_" -ForegroundColor Red
    exit 1
}
