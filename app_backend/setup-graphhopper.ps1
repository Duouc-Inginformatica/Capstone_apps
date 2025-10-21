# ============================================================================
# GraphHopper Setup Script for WayFindCL
# ============================================================================
# Descarga GraphHopper 11.0, configura y genera el graph-cache
# ============================================================================

Write-Host "[*] GraphHopper Setup - WayFindCL" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan
Write-Host ""

# Variables
$GRAPHHOPPER_VERSION = "11.0"
$GRAPHHOPPER_JAR = "graphhopper-web-$GRAPHHOPPER_VERSION.jar"
$GRAPHHOPPER_URL = "https://github.com/graphhopper/graphhopper/releases/download/$GRAPHHOPPER_VERSION/$GRAPHHOPPER_JAR"
$OSM_FILE = "data/santiago.osm.pbf"
$OSM_URL = "https://download.geofabrik.de/south-america/chile-latest.osm.pbf"
$GTFS_URL = "https://www.dtpm.cl/descargas/gtfs/GTFS_20250927_v3.zip"
$GTFS_FILE = "data/gtfs-santiago.zip"

# Tamaño mínimo esperado del OSM (en MB) - Chile completo debería tener al menos 100 MB
$OSM_MIN_SIZE_MB = 100

# ============================================================================
# 1. VERIFICAR/DESCARGAR ARCHIVO OSM
# ============================================================================
Write-Host "[1/7] Verificando archivo OSM..." -ForegroundColor Yellow

if (-Not (Test-Path "data")) {
    New-Item -ItemType Directory -Path "data" -Force | Out-Null
}

$needDownload = $false

if (-Not (Test-Path $OSM_FILE)) {
    Write-Host "[WARN] OSM no encontrado: $OSM_FILE" -ForegroundColor Yellow
    $needDownload = $true
} else {
    $osmSize = (Get-Item $OSM_FILE).Length / 1MB
    $osmSizeMB = [math]::Round($osmSize, 2)
    
    if ($osmSize -lt $OSM_MIN_SIZE_MB) {
        Write-Host "[WARN] OSM muy pequeno ($osmSizeMB MB, esperado >$OSM_MIN_SIZE_MB MB)" -ForegroundColor Yellow
        Write-Host "[WARN] Archivo posiblemente corrupto, re-descargando..." -ForegroundColor Yellow
        $needDownload = $true
        Remove-Item $OSM_FILE -Force
    } else {
        Write-Host "[OK] OSM encontrado: $OSM_FILE ($osmSizeMB MB)" -ForegroundColor Green
    }
}

if ($needDownload) {
    Write-Host "[1/7] Descargando OSM de Chile (~400 MB, puede tomar 5-10 minutos)..." -ForegroundColor Yellow
    Write-Host "   URL: $OSM_URL" -ForegroundColor Gray
    Write-Host "   Esto puede tardar varios minutos dependiendo de tu conexion..." -ForegroundColor Gray
    
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $OSM_URL -OutFile $OSM_FILE -UseBasicParsing
        $ProgressPreference = 'Continue'
        
        $osmSize = (Get-Item $OSM_FILE).Length / 1MB
        $osmSizeMB = [math]::Round($osmSize, 2)
        Write-Host "[OK] OSM descargado: $osmSizeMB MB" -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] Error descargando OSM:" -ForegroundColor Red
        Write-Host "   $_" -ForegroundColor Red
        Write-Host "" 
        Write-Host "   Descarga manual desde:" -ForegroundColor Yellow
        Write-Host "   $OSM_URL" -ForegroundColor White
        exit 1
    }
}

# ============================================================================
# 2. DESCARGAR GRAPHHOPPER JAR
# ============================================================================
if (Test-Path $GRAPHHOPPER_JAR) {
    Write-Host "[OK] GraphHopper JAR ya existe: $GRAPHHOPPER_JAR" -ForegroundColor Green
} else {
    Write-Host "[2/7] Descargando GraphHopper $GRAPHHOPPER_VERSION..." -ForegroundColor Yellow
    Write-Host "   URL: $GRAPHHOPPER_URL" -ForegroundColor Gray
    
    try {
        # Usar Invoke-WebRequest con barra de progreso
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $GRAPHHOPPER_URL -OutFile $GRAPHHOPPER_JAR -UseBasicParsing
        $ProgressPreference = 'Continue'
        
        $jarSize = (Get-Item $GRAPHHOPPER_JAR).Length / 1MB
        $jarSizeMB = [math]::Round($jarSize, 2)
        Write-Host "[OK] GraphHopper JAR descargado: $jarSizeMB MB" -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] Error descargando GraphHopper:" -ForegroundColor Red
        Write-Host "   $_" -ForegroundColor Red
        Write-Host "" 
        Write-Host "   Descarga manual desde:" -ForegroundColor Yellow
        Write-Host "   $GRAPHHOPPER_URL" -ForegroundColor White
        exit 1
    }
}

# ============================================================================
# 3. DESCARGAR GTFS (si no existe)
# ============================================================================
if (-Not (Test-Path "data")) {
    New-Item -ItemType Directory -Path "data" -Force | Out-Null
}

if (Test-Path $GTFS_FILE) {
    Write-Host "[OK] GTFS ya existe: $GTFS_FILE" -ForegroundColor Green
} else {
    Write-Host "[3/7] Descargando GTFS de DTPM Santiago..." -ForegroundColor Yellow
    
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $GTFS_URL -OutFile $GTFS_FILE -UseBasicParsing
        $ProgressPreference = 'Continue'
        
        Write-Host "[OK] GTFS descargado correctamente" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] No se pudo descargar GTFS (continuando sin el)" -ForegroundColor Yellow
    }
}

# ============================================================================
# 4. VERIFICAR JAVA
# ============================================================================
Write-Host ""
Write-Host "[4/7] Verificando Java..." -ForegroundColor Yellow
try {
    $javaVersion = java -version 2>&1 | Select-String "version" | Select-Object -First 1
    Write-Host "[OK] Java encontrado: $javaVersion" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Java no esta instalado o no esta en el PATH" -ForegroundColor Red
    Write-Host "   Descarga Java 17+ desde:" -ForegroundColor Red
    Write-Host "   https://adoptium.net/" -ForegroundColor White
    exit 1
}
# ============================================================================
# 5. CREAR ARCHIVO DE CONFIGURACION
# ============================================================================
Write-Host ""
Write-Host "[5/7] Creando archivo de configuracion..." -ForegroundColor Yellow

$templatePath = Join-Path $PSScriptRoot "graphhopper-config.template.yml"
if (-Not (Test-Path $templatePath)) {
        Write-Host "[ERROR] Plantilla no encontrada: $templatePath" -ForegroundColor Red
        Write-Host "        Asegurate de que graphhopper-config.template.yml exista." -ForegroundColor Red
        exit 1
}

$configContent = Get-Content -Path $templatePath -Raw
$configContent = $configContent.Replace("{{OSM_FILE}}", $OSM_FILE)
$configContent = $configContent.Replace("{{GTFS_FILE}}", $GTFS_FILE)

$configContent | Out-File -FilePath "graphhopper-config.yml" -Encoding UTF8
Write-Host "[OK] Configuracion creada: graphhopper-config.yml" -ForegroundColor Green

# ============================================================================
# 6. GENERAR GRAPH-CACHE
# ============================================================================
Write-Host ""
Write-Host "[6/7] Generando graph-cache (esto puede tomar varios minutos)..." -ForegroundColor Yellow
$osmSizeRounded = [math]::Round($osmSize, 0)
Write-Host "   Procesando OSM de Santiago (~$osmSizeRounded MB)..." -ForegroundColor Gray
Write-Host ""

if (Test-Path "graph-cache") {
    Write-Host "[WARN] graph-cache ya existe. Deseas regenerarlo? (S/N)" -ForegroundColor Yellow
    $response = Read-Host
    if ($response -eq "S" -or $response -eq "s") {
        Remove-Item -Recurse -Force "graph-cache"
        Write-Host "[OK] graph-cache anterior eliminado" -ForegroundColor Green
    } else {
        Write-Host "[OK] Usando graph-cache existente" -ForegroundColor Green
        Write-Host ""
        Write-Host "[DONE] Setup completado!" -ForegroundColor Green
        Write-Host ""
        Write-Host "Para iniciar GraphHopper:" -ForegroundColor Cyan
        Write-Host "  java -Xmx8g -Xms2g -jar $GRAPHHOPPER_JAR server graphhopper-config.yml" -ForegroundColor White
        Write-Host ""
        Write-Host "O ejecuta el backend Go que lo iniciará automáticamente:" -ForegroundColor Cyan
        Write-Host "  go run .\cmd\server\" -ForegroundColor White
        exit 0
    }
}

# Ejecutar GraphHopper import
Write-Host "Ejecutando: java -Xmx8g -Xms2g -jar $GRAPHHOPPER_JAR import graphhopper-config.yml" -ForegroundColor Gray
Write-Host ""

try {
    $process = Start-Process -FilePath "java" `
        -ArgumentList "-Xmx8g", "-Xms2g", "-jar", $GRAPHHOPPER_JAR, "import", "graphhopper-config.yml" `
        -NoNewWindow -PassThru -Wait

    if ($process.ExitCode -eq 0) {
        Write-Host ""
        Write-Host "[OK] Graph-cache generado exitosamente!" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "[ERROR] Error generando graph-cache (codigo: $($process.ExitCode))" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "[ERROR] ERROR ejecutando GraphHopper import:" -ForegroundColor Red
    Write-Host "   $_" -ForegroundColor Red
    exit 1
}

# ============================================================================
# 7. VERIFICAR GRAPH-CACHE
# ============================================================================
Write-Host ""
Write-Host "[7/7] Verificando graph-cache..." -ForegroundColor Yellow

if (Test-Path "graph-cache") {
    $cacheSize = (Get-ChildItem -Path "graph-cache" -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB
    $cacheSizeMB = [math]::Round($cacheSize, 2)
    Write-Host "[OK] graph-cache creado: $cacheSizeMB MB" -ForegroundColor Green
} else {
    Write-Host "[WARN] graph-cache no encontrado" -ForegroundColor Yellow
}

# ============================================================================
# 8. COMPLETADO
# ============================================================================
Write-Host ""
Write-Host "[DONE] Setup completado exitosamente!" -ForegroundColor Green
Write-Host ""
Write-Host "Archivos creados:" -ForegroundColor Cyan
Write-Host "  [OK] $GRAPHHOPPER_JAR" -ForegroundColor White
Write-Host "  [OK] graphhopper-config.yml" -ForegroundColor White
Write-Host "  [OK] graph-cache/" -ForegroundColor White
Write-Host ""
Write-Host "Para iniciar GraphHopper manualmente:" -ForegroundColor Cyan
Write-Host "  java -Xmx8g -Xms2g -jar $GRAPHHOPPER_JAR server graphhopper-config.yml" -ForegroundColor White
Write-Host ""
Write-Host "O ejecuta el backend Go (iniciará GraphHopper automáticamente):" -ForegroundColor Cyan
Write-Host "  go run .\cmd\server\" -ForegroundColor White
Write-Host ""
Write-Host "GraphHopper estará disponible en: http://localhost:8989" -ForegroundColor Cyan
Write-Host ""
