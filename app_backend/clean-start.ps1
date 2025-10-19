# ============================================================================
# Script de Limpieza Rapida - WayFindCL Backend
# ============================================================================
# Elimina cache de GraphHopper y reinicia servidor
# Util cuando cambias la configuracion de perfiles
# ============================================================================

Write-Host "[LIMPIEZA] Eliminando cache de GraphHopper..." -ForegroundColor Yellow

if (Test-Path "graph-cache") {
    try {
        Remove-Item -Path "graph-cache" -Recurse -Force
        Write-Host "[OK] Cache eliminado correctamente" -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] Error al eliminar cache: $_" -ForegroundColor Red
        Write-Host "[INFO] Ejecuta manualmente: rm -r -fo graph-cache" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "[INFO] No existe cache para limpiar" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "[INICIO] Iniciando backend..." -ForegroundColor Green
Write-Host ""

go run .\cmd\server\
