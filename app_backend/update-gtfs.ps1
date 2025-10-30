# ============================================================================
# SCRIPT DE ACTUALIZACIÓN DE GTFS PARA GRAPHHOPPER
# ============================================================================
# Propósito: Descargar GTFS mejorado de BusMaps para uso de GraphHopper
# Archivo destino: data/gtfs-santiago.zip
# Fuente: https://s3.transitpdf.com/files/uran/improved-gtfs-transantiago-metrodesantiago.zip
# ============================================================================

param(
    [switch]$Force,
    [switch]$SkipBackup
)

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "   ACTUALIZACIÓN DE GTFS PARA GRAPHHOPPER" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Asegurar que estamos en el directorio app_backend
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$GtfsUrl = "https://s3.transitpdf.com/files/uran/improved-gtfs-transantiago-metrodesantiago.zip"
$DataDir = Join-Path $ScriptDir "data"
$DestFile = Join-Path $DataDir "gtfs-santiago.zip"
$BackupFile = Join-Path $DataDir "gtfs-santiago.backup.zip"

# Verificar si el directorio data existe
if (-not (Test-Path $DataDir)) {
    Write-Host "📁 Creando directorio data..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $DataDir | Out-Null
}

# Verificar si ya existe el archivo
if (Test-Path $DestFile) {
    if (-not $Force) {
        Write-Host "⚠️ El archivo $DestFile ya existe" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Opciones:" -ForegroundColor White
        Write-Host "  1. Actualizar (sobrescribir)" -ForegroundColor White
        Write-Host "  2. Mantener archivo actual" -ForegroundColor White
        Write-Host "  3. Ver información del archivo actual" -ForegroundColor White
        Write-Host ""
        
        $Choice = Read-Host "Selecciona una opción (1/2/3)"
        
        if ($Choice -eq "3") {
            $FileInfo = Get-Item $DestFile
            Write-Host ""
            Write-Host "📊 INFORMACIÓN DEL ARCHIVO ACTUAL:" -ForegroundColor Cyan
            Write-Host "   Tamaño: $([math]::Round($FileInfo.Length / 1MB, 2)) MB" -ForegroundColor White
            Write-Host "   Fecha: $($FileInfo.LastWriteTime)" -ForegroundColor White
            Write-Host ""
            
            $Continue = Read-Host "¿Deseas actualizar? (S/N)"
            if ($Continue -ne "S" -and $Continue -ne "s") {
                Write-Host "❌ Actualización cancelada" -ForegroundColor Yellow
                exit 0
            }
        } elseif ($Choice -eq "2") {
            Write-Host "✅ Manteniendo archivo actual" -ForegroundColor Green
            exit 0
        } elseif ($Choice -ne "1") {
            Write-Host "❌ Opción inválida - Cancelando" -ForegroundColor Red
            exit 1
        }
    }
    
    # Crear backup si no se especificó -SkipBackup
    if (-not $SkipBackup) {
        Write-Host "💾 Creando backup del archivo actual..." -ForegroundColor Yellow
        
        try {
            Copy-Item $DestFile $BackupFile -Force
            Write-Host "   ✅ Backup creado: $BackupFile" -ForegroundColor Green
        } catch {
            Write-Host "   ⚠️ No se pudo crear backup: $_" -ForegroundColor Yellow
        }
    }
}

# Descargar nuevo GTFS
Write-Host ""
Write-Host "📥 Descargando GTFS mejorado de BusMaps..." -ForegroundColor Yellow
Write-Host "   Fuente: $GtfsUrl" -ForegroundColor Cyan
Write-Host "   Destino: $DestFile" -ForegroundColor Cyan
Write-Host ""

try {
    $ProgressPreference = 'SilentlyContinue'  # Ocultar barra de progreso de Invoke-WebRequest
    
    Write-Host "   ⏳ Descargando... (9.45 MB)" -ForegroundColor Cyan
    
    $StartTime = Get-Date
    Invoke-WebRequest -Uri $GtfsUrl -OutFile $DestFile -UseBasicParsing
    $EndTime = Get-Date
    $Duration = ($EndTime - $StartTime).TotalSeconds
    
    $ProgressPreference = 'Continue'
    
    # Verificar descarga
    if (Test-Path $DestFile) {
        $FileInfo = Get-Item $DestFile
        $FileSizeMB = [math]::Round($FileInfo.Length / 1MB, 2)
        
        Write-Host ""
        Write-Host "   ✅ Descarga completada en $([math]::Round($Duration, 1)) segundos" -ForegroundColor Green
        Write-Host "   📊 Tamaño del archivo: $FileSizeMB MB" -ForegroundColor Cyan
        Write-Host "   📅 Fecha de descarga: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
        
        # Validar que es un archivo ZIP válido
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $Zip = [System.IO.Compression.ZipFile]::OpenRead($DestFile)
            $FileCount = $Zip.Entries.Count
            $Zip.Dispose()
            
            Write-Host "   📦 Archivos en ZIP: $FileCount" -ForegroundColor Cyan
            
            # Verificar archivos GTFS esperados
            $RequiredFiles = @(
                "stops.txt",
                "routes.txt",
                "trips.txt",
                "stop_times.txt"
            )
            
            $Zip = [System.IO.Compression.ZipFile]::OpenRead($DestFile)
            $ZipFiles = $Zip.Entries | Select-Object -ExpandProperty Name
            $Zip.Dispose()
            
            $MissingFiles = @()
            foreach ($File in $RequiredFiles) {
                if ($ZipFiles -notcontains $File) {
                    $MissingFiles += $File
                }
            }
            
            if ($MissingFiles.Count -gt 0) {
                Write-Host ""
                Write-Host "   ⚠️ ADVERTENCIA: Archivos GTFS faltantes:" -ForegroundColor Yellow
                foreach ($File in $MissingFiles) {
                    Write-Host "      - $File" -ForegroundColor Yellow
                }
            } else {
                Write-Host "   ✅ Todos los archivos GTFS requeridos presentes" -ForegroundColor Green
            }
            
            # Mostrar archivos adicionales
            $OptionalFiles = @(
                "shapes.txt",
                "calendar.txt",
                "calendar_dates.txt",
                "agency.txt",
                "transfers.txt",
                "frequencies.txt",
                "feed_info.txt"
            )
            
            Write-Host ""
            Write-Host "   📋 Archivos opcionales encontrados:" -ForegroundColor Cyan
            foreach ($File in $OptionalFiles) {
                if ($ZipFiles -contains $File) {
                    Write-Host "      ✅ $File" -ForegroundColor Green
                }
            }
            
        } catch {
            Write-Host "   ⚠️ No se pudo validar contenido del ZIP: $_" -ForegroundColor Yellow
        }
        
    } else {
        Write-Host "   ❌ Error: El archivo no se descargó correctamente" -ForegroundColor Red
        exit 1
    }
    
} catch {
    Write-Host ""
    Write-Host "   ❌ Error descargando GTFS: $_" -ForegroundColor Red
    Write-Host ""
    
    # Restaurar backup si existe
    if ((Test-Path $BackupFile) -and -not $SkipBackup) {
        Write-Host "   🔄 Restaurando backup..." -ForegroundColor Yellow
        Copy-Item $BackupFile $DestFile -Force
        Write-Host "   ✅ Backup restaurado" -ForegroundColor Green
    }
    
    exit 1
}

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "   ✅ ACTUALIZACIÓN COMPLETADA" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "📝 SIGUIENTE PASO:" -ForegroundColor Yellow
Write-Host "   GraphHopper necesita re-importar los datos GTFS" -ForegroundColor White
Write-Host ""
Write-Host "   OPCIÓN 1: Limpiar caché y reiniciar (recomendado)" -ForegroundColor Cyan
Write-Host "   Remove-Item -Recurse -Force graph-cache" -ForegroundColor White
Write-Host "   .\clean-start.ps1" -ForegroundColor White
Write-Host ""
Write-Host "   OPCIÓN 2: Re-importar sin limpiar caché (más rápido)" -ForegroundColor Cyan
Write-Host "   java -Xmx8g -jar graphhopper-web-11.0.jar import graphhopper-config.yml" -ForegroundColor White
Write-Host ""
Write-Host "💡 INFO:" -ForegroundColor Yellow
Write-Host "   - El GTFS mejorado tiene 12,107 paradas (+10% vs DTPM)" -ForegroundColor White
Write-Host "   - 418 rutas (+4.5% vs DTPM)" -ForegroundColor White
Write-Host "   - >90% trips con shapes mejorados (+20% vs DTPM)" -ForegroundColor White
Write-Host "   - Vigencia: 2 Ago - 31 Dic 2025" -ForegroundColor White
Write-Host ""

# Preguntar si desea limpiar caché y reiniciar
Write-Host "¿Deseas limpiar el caché de GraphHopper y reiniciar ahora? (S/N)" -ForegroundColor Yellow
$CleanCache = Read-Host

if ($CleanCache -eq "S" -or $CleanCache -eq "s") {
    Write-Host ""
    Write-Host "🗑️ Limpiando caché de GraphHopper..." -ForegroundColor Yellow
    
    if (Test-Path "graph-cache") {
        Remove-Item -Recurse -Force "graph-cache"
        Write-Host "   ✅ Caché eliminado" -ForegroundColor Green
    } else {
        Write-Host "   ℹ️ No hay caché para eliminar" -ForegroundColor Cyan
    }
    
    Write-Host ""
    Write-Host "🚀 Iniciando backend (importará GTFS automáticamente)..." -ForegroundColor Yellow
    Write-Host "   ⏳ Este proceso puede tomar 10-30 minutos" -ForegroundColor Cyan
    Write-Host ""
    
    if (Test-Path "clean-start.ps1") {
        & .\clean-start.ps1
    } elseif (Test-Path "start-backend.ps1") {
        & .\start-backend.ps1
    } else {
        Write-Host "   💡 Inicia manualmente con:" -ForegroundColor Yellow
        Write-Host "   go run .\cmd\server\" -ForegroundColor White
    }
} else {
    Write-Host ""
    Write-Host "✅ GTFS actualizado. Recuerda reiniciar GraphHopper para aplicar cambios." -ForegroundColor Green
}
