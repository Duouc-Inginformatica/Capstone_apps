# ============================================================================
# Script de Limpieza: Archivos TTS Neural Obsoletos
# ============================================================================
# Este script elimina los archivos Kotlin de TTS neural que ya no se usan
# después de volver al TTS clásico de Flutter.
# ============================================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Limpieza: TTS Neural Obsoleto       " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Archivos a eliminar
$filesToDelete = @(
    "app\src\main\kotlin\com\example\wayfindcl\MultiModelPiperTtsPlugin.kt",
    "app\src\main\kotlin\com\example\wayfindcl\PiperTtsPlugin.kt",
    "app\src\main\kotlin\com\example\wayfindcl\NeuralTtsPlugin.kt",
    "app\src\main\kotlin\com\example\wayfindcl\EspeakPhonemizer.kt",
    "app\src\main\kotlin\com\wayfindcl\VitsTtsPlugin.kt"
)

Write-Host "🔍 Archivos a eliminar:" -ForegroundColor Yellow
foreach ($file in $filesToDelete) {
    if (Test-Path $file) {
        Write-Host "   ✓ $file" -ForegroundColor White
    } else {
        Write-Host "   ⊘ $file (no existe)" -ForegroundColor DarkGray
    }
}
Write-Host ""

# Confirmar eliminación
$response = Read-Host "¿Deseas eliminar estos archivos? (s/n)"
if ($response -ne 's' -and $response -ne 'S') {
    Write-Host "❌ Operación cancelada" -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "🗑️  Eliminando archivos..." -ForegroundColor Yellow

$deletedCount = 0
$notFoundCount = 0

foreach ($file in $filesToDelete) {
    if (Test-Path $file) {
        try {
            Remove-Item $file -Force
            Write-Host "   ✓ Eliminado: $file" -ForegroundColor Green
            $deletedCount++
        } catch {
            Write-Host "   ❌ Error eliminando: $file" -ForegroundColor Red
            Write-Host "      $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "   ⊘ No existe: $file" -ForegroundColor DarkGray
        $notFoundCount++
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Resumen de Limpieza                 " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Archivos eliminados: $deletedCount" -ForegroundColor Green
Write-Host "   Archivos no encontrados: $notFoundCount" -ForegroundColor DarkGray
Write-Host ""

if ($deletedCount -gt 0) {
    Write-Host "✅ Limpieza completada exitosamente!" -ForegroundColor Green
    Write-Host ""
    Write-Host "📝 Cambios realizados:" -ForegroundColor Cyan
    Write-Host "   • Eliminados plugins de TTS neural (ONNX Runtime)" -ForegroundColor White
    Write-Host "   • MainActivity ya no registra MultiModelPiperTtsPlugin" -ForegroundColor White
    Write-Host "   • Se mantiene NpuDetectorPlugin para badge IA" -ForegroundColor White
    Write-Host "   • TTS ahora usa flutter_tts clásico" -ForegroundColor White
    Write-Host ""
    Write-Host "🔄 Próximo paso:" -ForegroundColor Cyan
    Write-Host "   Ejecuta: flutter clean && flutter pub get" -ForegroundColor Yellow
    Write-Host "   Luego: flutter run" -ForegroundColor Yellow
} else {
    Write-Host "⚠️  No se eliminaron archivos" -ForegroundColor Yellow
}

Write-Host ""
