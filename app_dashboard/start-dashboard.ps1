# Script de inicio para el Debug Dashboard
# WayFindCL - Red Mobilidad

Write-Host "========================================" -ForegroundColor Red
Write-Host "  WayFindCL Debug Dashboard" -ForegroundColor White
Write-Host "  Red Mobilidad - Debugging Tool" -ForegroundColor Gray
Write-Host "========================================`n" -ForegroundColor Red

# Verificar que Bun esté instalado
if (!(Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Bun no está instalado." -ForegroundColor Red
    Write-Host "   Instala Bun desde: https://bun.sh" -ForegroundColor Yellow
    Write-Host "   O usa: npm install -g bun" -ForegroundColor Yellow
    exit 1
}

Write-Host "✅ Bun encontrado: " -NoNewline -ForegroundColor Green
bun --version

# Verificar si existen las dependencias
if (!(Test-Path "node_modules")) {
    Write-Host "`n📦 Instalando dependencias..." -ForegroundColor Cyan
    bun install
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Error al instalar dependencias" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "✅ Dependencias instaladas correctamente`n" -ForegroundColor Green
}

# Iniciar el servidor de desarrollo
Write-Host "🚀 Iniciando servidor de desarrollo en http://localhost:3000" -ForegroundColor Cyan
Write-Host "   Presiona Ctrl+C para detener el servidor`n" -ForegroundColor Gray

bun run dev
