# ============================================================================
# MIGRACIÓN AUTOMÁTICA A GTFS MEJORADO DE BUSMAPS
# ============================================================================
# Propósito: Migrar backend completo al nuevo GTFS mejorado
# Fuente: https://s3.transitpdf.com/files/uran/improved-gtfs-transantiago-metrodesantiago.zip
# Fecha: 30 Oct 2025
# ============================================================================

param(
    [string]$DbUser = "app_user",
    [string]$DbPass = "",
    [string]$DbHost = "127.0.0.1",
    [string]$DbName = "wayfindcl",
    [switch]$SkipBackup,
    [switch]$SkipMigration,
    [switch]$SkipImport
)

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "   MIGRACIÓN A GTFS MEJORADO DE BUSMAPS" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Verificar que mysql está disponible
if (-not (Get-Command mysql -ErrorAction SilentlyContinue)) {
    Write-Host "❌ ERROR: MySQL client no encontrado" -ForegroundColor Red
    Write-Host "   Instala MySQL o agrega mysql.exe al PATH" -ForegroundColor Yellow
    exit 1
}

# Solicitar contraseña si no se proporcionó
if ([string]::IsNullOrEmpty($DbPass)) {
    $SecurePass = Read-Host "Ingresa la contraseña de MySQL para $DbUser" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass)
    $DbPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
}

# ============================================================================
# PASO 1: BACKUP DE BASE DE DATOS
# ============================================================================
if (-not $SkipBackup) {
    Write-Host "📦 PASO 1: Creando backup de base de datos..." -ForegroundColor Yellow
    $BackupFile = "backup_gtfs_$(Get-Date -Format 'yyyyMMdd_HHmmss').sql"
    
    $mysqldump = "mysqldump"
    if (Get-Command mysqldump -ErrorAction SilentlyContinue) {
        & $mysqldump -u $DbUser -p$DbPass -h $DbHost $DbName `
            gtfs_feeds gtfs_stops gtfs_routes gtfs_trips gtfs_stop_times `
            > $BackupFile
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   ✅ Backup creado: $BackupFile" -ForegroundColor Green
        } else {
            Write-Host "   ⚠️ Advertencia: No se pudo crear backup completo" -ForegroundColor Yellow
        }
    } else {
        Write-Host "   ⚠️ mysqldump no encontrado - saltando backup" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ============================================================================
# PASO 2: MIGRAR SCHEMA DE BASE DE DATOS
# ============================================================================
if (-not $SkipMigration) {
    Write-Host "🔧 PASO 2: Actualizando schema de base de datos..." -ForegroundColor Yellow
    
    $MigrationScript = "sql\migrate_gtfs_busmaps.sql"
    if (-not (Test-Path $MigrationScript)) {
        Write-Host "   ❌ ERROR: Script de migración no encontrado: $MigrationScript" -ForegroundColor Red
        exit 1
    }
    
    & mysql -u $DbUser -p$DbPass -h $DbHost $DbName < $MigrationScript
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "   ✅ Schema actualizado correctamente" -ForegroundColor Green
    } else {
        Write-Host "   ❌ ERROR: Fallo al actualizar schema" -ForegroundColor Red
        Write-Host "   💡 Verifica los logs de MySQL para más detalles" -ForegroundColor Yellow
        exit 1
    }
    Write-Host ""
}

# ============================================================================
# PASO 3: ACTUALIZAR .ENV CON NUEVA URL DE GTFS
# ============================================================================
Write-Host "⚙️ PASO 3: Actualizando configuración (.env)..." -ForegroundColor Yellow

$EnvFile = ".env"
$EnvExampleFile = ".env.example"

# Crear .env si no existe
if (-not (Test-Path $EnvFile)) {
    if (Test-Path $EnvExampleFile) {
        Copy-Item $EnvExampleFile $EnvFile
        Write-Host "   📝 Creado $EnvFile desde $EnvExampleFile" -ForegroundColor Cyan
    } else {
        Write-Host "   ⚠️ Advertencia: .env.example no encontrado" -ForegroundColor Yellow
    }
}

# Actualizar GTFS_FEED_URL
if (Test-Path $EnvFile) {
    $EnvContent = Get-Content $EnvFile -Raw
    
    $NewGtfsUrl = "https://s3.transitpdf.com/files/uran/improved-gtfs-transantiago-metrodesantiago.zip"
    $FallbackUrl = "https://www.dtpm.cl/descarga.php?file=gtfs/gtfs.zip"
    
    # Reemplazar o agregar GTFS_FEED_URL
    if ($EnvContent -match "GTFS_FEED_URL=") {
        $EnvContent = $EnvContent -replace "GTFS_FEED_URL=.*", "GTFS_FEED_URL=$NewGtfsUrl"
        Write-Host "   ✅ GTFS_FEED_URL actualizado" -ForegroundColor Green
    } else {
        $EnvContent += "`nGTFS_FEED_URL=$NewGtfsUrl"
        Write-Host "   ✅ GTFS_FEED_URL agregado" -ForegroundColor Green
    }
    
    # Actualizar GTFS_FALLBACK_URL
    if ($EnvContent -match "GTFS_FALLBACK_URL=") {
        $EnvContent = $EnvContent -replace "GTFS_FALLBACK_URL=.*", "GTFS_FALLBACK_URL=$FallbackUrl"
    } else {
        $EnvContent += "`nGTFS_FALLBACK_URL=$FallbackUrl"
    }
    
    $EnvContent | Set-Content $EnvFile -NoNewline
    Write-Host "   📝 Configuración guardada en $EnvFile" -ForegroundColor Cyan
} else {
    Write-Host "   ⚠️ Advertencia: No se pudo actualizar .env" -ForegroundColor Yellow
}
Write-Host ""

# ============================================================================
# PASO 4: LIMPIAR DATOS GTFS ANTIGUOS
# ============================================================================
if (-not $SkipImport) {
    Write-Host "🗑️ PASO 4: Limpiando datos GTFS antiguos..." -ForegroundColor Yellow
    
    $CleanScript = "sql\clean_gtfs.sql"
    if (Test-Path $CleanScript) {
        & mysql -u $DbUser -p$DbPass -h $DbHost $DbName < $CleanScript
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   ✅ Datos antiguos eliminados" -ForegroundColor Green
        } else {
            Write-Host "   ⚠️ Advertencia: Algunas tablas no se pudieron limpiar" -ForegroundColor Yellow
        }
    } else {
        Write-Host "   ⚠️ clean_gtfs.sql no encontrado - saltando limpieza" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ============================================================================
# PASO 5: INICIAR BACKEND PARA IMPORTAR NUEVOS DATOS
# ============================================================================
if (-not $SkipImport) {
    Write-Host "🚀 PASO 5: Iniciando backend para importar datos de BusMaps..." -ForegroundColor Yellow
    Write-Host "   📥 Descargando GTFS mejorado (9.45 MB)..." -ForegroundColor Cyan
    Write-Host "   ⏳ Este proceso puede tomar 10-30 minutos dependiendo de tu conexión" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "   💡 OPCIONES:" -ForegroundColor Yellow
    Write-Host "   A) Iniciar servidor ahora (automático)" -ForegroundColor White
    Write-Host "   B) Iniciar manualmente después" -ForegroundColor White
    Write-Host ""
    
    $Choice = Read-Host "   Selecciona opción (A/B)"
    
    if ($Choice -eq "A" -or $Choice -eq "a") {
        Write-Host ""
        Write-Host "   🔄 Compilando backend..." -ForegroundColor Cyan
        
        & go build .\cmd\server\
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   ✅ Backend compilado" -ForegroundColor Green
            Write-Host ""
            Write-Host "   🌐 Iniciando servidor en http://localhost:8080" -ForegroundColor Cyan
            Write-Host "   📊 Monitorea los logs para ver el progreso de importación" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "   Presiona Ctrl+C para detener el servidor cuando termine la importación" -ForegroundColor Yellow
            Write-Host ""
            
            & .\server.exe
        } else {
            Write-Host "   ❌ ERROR: No se pudo compilar el backend" -ForegroundColor Red
            Write-Host "   💡 Ejecuta manualmente: go build .\cmd\server\" -ForegroundColor Yellow
        }
    } else {
        Write-Host ""
        Write-Host "   📝 Para iniciar manualmente:" -ForegroundColor Yellow
        Write-Host "   1. cd app_backend" -ForegroundColor White
        Write-Host "   2. go run .\cmd\server\" -ForegroundColor White
        Write-Host "   3. El backend descargará e importará automáticamente el GTFS" -ForegroundColor White
    }
}

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "   ✅ MIGRACIÓN COMPLETADA" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "📊 RESUMEN:" -ForegroundColor Yellow
Write-Host "   ✅ Schema actualizado con nuevas tablas GTFS" -ForegroundColor Green
Write-Host "   ✅ Configuración actualizada (.env)" -ForegroundColor Green
Write-Host "   ⏳ Importación de datos en progreso (si iniciaste el servidor)" -ForegroundColor Cyan
Write-Host ""
Write-Host "📝 SIGUIENTE PASO:" -ForegroundColor Yellow
Write-Host "   Ejecuta el script de validación:" -ForegroundColor White
Write-Host "   mysql -u $DbUser -p -h $DbHost $DbName < sql\validate_gtfs_migration.sql" -ForegroundColor Cyan
Write-Host ""
Write-Host "💡 MÉTRICAS ESPERADAS CON BUSMAPS:" -ForegroundColor Yellow
Write-Host "   - Paradas: ~12,107 (+10% vs DTPM)" -ForegroundColor White
Write-Host "   - Rutas: ~418 (+4.5% vs DTPM)" -ForegroundColor White
Write-Host "   - Shapes: >90% cobertura (+20% vs DTPM)" -ForegroundColor White
Write-Host "   - Agencias: 4 operadores" -ForegroundColor White
Write-Host ""
