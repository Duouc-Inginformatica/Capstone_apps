# ============================================================================
# SOLUCIÓN RÁPIDA: Eliminar archivos TTS neural obsoletos
# ============================================================================

Write-Host "🗑️  Eliminando archivos obsoletos de TTS neural..." -ForegroundColor Yellow
Write-Host ""

# Cambiar al directorio android
Set-Location "C:\Users\sebas\Desktop\CapstoneAPP\Capstone_apps\app\android"

# Eliminar archivos obsoletos
Remove-Item -Path "app\src\main\kotlin\com\example\wayfindcl\MultiModelPiperTtsPlugin.kt" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "app\src\main\kotlin\com\example\wayfindcl\PiperTtsPlugin.kt" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "app\src\main\kotlin\com\example\wayfindcl\NeuralTtsPlugin.kt" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "app\src\main\kotlin\com\example\wayfindcl\EspeakPhonemizer.kt" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "app\src\main\kotlin\com\wayfindcl\VitsTtsPlugin.kt" -Force -ErrorAction SilentlyContinue

Write-Host "✅ Archivos eliminados" -ForegroundColor Green
Write-Host ""
Write-Host "🔄 Ejecutando flutter clean..." -ForegroundColor Yellow

# Volver al directorio app
Set-Location ".."

# Limpiar build
flutter clean

Write-Host ""
Write-Host "✅ Limpieza completada" -ForegroundColor Green
Write-Host ""
Write-Host "📦 Ejecutando flutter pub get..." -ForegroundColor Yellow

flutter pub get

Write-Host ""
Write-Host "✅ ¡Todo listo!" -ForegroundColor Green
Write-Host ""
Write-Host "🚀 Ahora puedes ejecutar: flutter run" -ForegroundColor Cyan
