# ============================================================================
# Script de Migración: Autenticación Biométrica
# ============================================================================
# Este script aplica la migración de la base de datos para soportar
# autenticación biométrica en la tabla users.
# ============================================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  MIGRACIÓN: Autenticación Biométrica  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Cargar variables de entorno desde .env
if (Test-Path ".env") {
    Write-Host "📄 Cargando configuración desde .env..." -ForegroundColor Yellow
    Get-Content .env | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]*)\s*=\s*(.*)$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            Set-Item -Path "env:$name" -Value $value
        }
    }
} else {
    Write-Host "⚠️  Archivo .env no encontrado, usando valores por defecto" -ForegroundColor Yellow
}

# Configuración de base de datos
$DB_HOST = if ($env:DB_HOST) { $env:DB_HOST } else { "localhost" }
$DB_PORT = if ($env:DB_PORT) { $env:DB_PORT } else { "3306" }
$DB_USER = if ($env:DB_USER) { $env:DB_USER } else { "root" }
$DB_PASSWORD = if ($env:DB_PASSWORD) { $env:DB_PASSWORD } else { "" }
$DB_NAME = if ($env:DB_NAME) { $env:DB_NAME } else { "wayfindcl" }

Write-Host "🔧 Configuración de base de datos:" -ForegroundColor Cyan
Write-Host "   Host: $DB_HOST" -ForegroundColor White
Write-Host "   Puerto: $DB_PORT" -ForegroundColor White
Write-Host "   Usuario: $DB_USER" -ForegroundColor White
Write-Host "   Base de datos: $DB_NAME" -ForegroundColor White
Write-Host ""

# Verificar si mysql está disponible
$mysqlPath = Get-Command mysql -ErrorAction SilentlyContinue
if (-not $mysqlPath) {
    Write-Host "❌ ERROR: mysql no está disponible en el PATH" -ForegroundColor Red
    Write-Host "   Por favor, instala MySQL/MariaDB o agrega mysql.exe al PATH" -ForegroundColor Yellow
    exit 1
}

# Construir comando mysql
$mysqlCmd = "mysql"
$mysqlArgs = @(
    "-h", $DB_HOST,
    "-P", $DB_PORT,
    "-u", $DB_USER
)

if ($DB_PASSWORD) {
    $mysqlArgs += "-p$DB_PASSWORD"
}

$mysqlArgs += $DB_NAME

Write-Host "🔄 Aplicando migración..." -ForegroundColor Yellow
Write-Host ""

# Ejecutar migración
try {
    Get-Content "sql\migrate_biometric_auth.sql" | & $mysqlCmd @mysqlArgs
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "✅ ¡Migración aplicada exitosamente!" -ForegroundColor Green
        Write-Host ""
        Write-Host "📊 Cambios aplicados:" -ForegroundColor Cyan
        Write-Host "   ✓ Campo password_hash ahora es opcional (NULL permitido)" -ForegroundColor White
        Write-Host "   ✓ Agregada columna biometric_id (SHA-256 hash único)" -ForegroundColor White
        Write-Host "   ✓ Agregada columna auth_type (password/biometric)" -ForegroundColor White
        Write-Host "   ✓ Agregada columna device_info (opcional)" -ForegroundColor White
        Write-Host "   ✓ Índice único creado en biometric_id" -ForegroundColor White
        Write-Host "   ✓ Índice creado en auth_type" -ForegroundColor White
        Write-Host ""
        Write-Host "🎯 Ahora el sistema soporta:" -ForegroundColor Cyan
        Write-Host "   • Registro con password tradicional" -ForegroundColor White
        Write-Host "   • Registro con autenticación biométrica" -ForegroundColor White
        Write-Host "   • Verificación de tokens biométricos duplicados" -ForegroundColor White
        Write-Host ""
        Write-Host "📡 Endpoints disponibles:" -ForegroundColor Cyan
        Write-Host "   POST /api/register (con biometric_token opcional)" -ForegroundColor White
        Write-Host "   POST /api/biometric/check (verifica si huella existe)" -ForegroundColor White
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "❌ Error aplicando migración (código: $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "❌ Error ejecutando migración:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Migración completada                 " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
