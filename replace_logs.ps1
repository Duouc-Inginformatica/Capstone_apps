# Script para reemplazar developer.log() por DebugLogger en archivos Dart
# Uso: .\replace_logs.ps1

$files = Get-ChildItem -Path "app\lib" -Filter "*.dart" -Recurse

foreach ($file in $files) {
    $content = Get-Content $file.FullName -Raw
    $originalContent = $content
    
    # Reemplazar developer.log simples con DebugLogger.info
    $content = $content -replace "developer\.log\('([^']+)'\);", "DebugLogger.info('`$1');"
    $content = $content -replace 'developer\.log\("([^"]+)"\);', 'DebugLogger.info("$1");'
    
    # Reemplazar developer.log con name: 'Navigation'
    $content = $content -replace "developer\.log\('([^']+)',\s*name:\s*'Navigation'\);", "DebugLogger.navigation('`$1');"
    $content = $content -replace "developer\.log\(([^,]+),\s*name:\s*'Navigation'\);", "DebugLogger.navigation(`$1);"
    
    # Reemplazar developer.log con name: 'Error'
    $content = $content -replace "developer\.log\('([^']+)',\s*name:\s*'Error'\);", "DebugLogger.error('`$1');"
    
    # Reemplazar import de developer si existe
    if ($content -match "import 'dart:developer' as developer;") {
        # Solo agregar import de debug_logger si no existe
        if ($content -notmatch "import.*debug_logger") {
            $content = $content -replace "(import 'dart:developer' as developer;)", "import '../services/debug_logger.dart';"
        } else {
            # Eliminar el import de developer
            $content = $content -replace "import 'dart:developer' as developer;\s*\n", ""
        }
    }
    
    # Solo guardar si hubo cambios
    if ($content -ne $originalContent) {
        Set-Content -Path $file.FullName -Value $content -NoNewline
        Write-Host "✅ Actualizado: $($file.FullName)" -ForegroundColor Green
    }
}

Write-Host "`n🎉 Proceso completado!" -ForegroundColor Cyan
