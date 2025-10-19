# ============================================================================
# Script de Limpieza de Procesos - WayFindCL
# ============================================================================
# Mata todos los procesos Java y Go para limpiar zombies
# ============================================================================

Write-Host "[*] Limpiando procesos zombies..." -ForegroundColor Cyan
Write-Host ""

# Matar todos los procesos Java (GraphHopper)
Write-Host "[1/4] Deteniendo procesos Java (GraphHopper)..." -ForegroundColor Yellow
$javaProcesses = Get-Process -Name "java" -ErrorAction SilentlyContinue
if ($javaProcesses) {
    $javaProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] Procesos Java detenidos: $($javaProcesses.Count)" -ForegroundColor Green
} else {
    Write-Host "[INFO] No hay procesos Java ejecutandose" -ForegroundColor Gray
}

# Matar todos los procesos Go
Write-Host "[2/4] Deteniendo procesos Go..." -ForegroundColor Yellow
$goProcesses = Get-Process -Name "go" -ErrorAction SilentlyContinue
if ($goProcesses) {
    $goProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] Procesos Go detenidos: $($goProcesses.Count)" -ForegroundColor Green
} else {
    Write-Host "[INFO] No hay procesos Go ejecutandose" -ForegroundColor Gray
}

# Matar procesos PowerShell zombies (excepto el actual)
Write-Host "[3/4] Limpiando ventanas PowerShell zombies..." -ForegroundColor Yellow
$currentPID = $PID
$psProcesses = Get-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $currentPID }
if ($psProcesses) {
    $psProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] Ventanas PowerShell zombies cerradas: $($psProcesses.Count)" -ForegroundColor Green
} else {
    Write-Host "[INFO] No hay ventanas PowerShell zombies" -ForegroundColor Gray
}

# Liberar puerto 8080 si está ocupado
Write-Host "[4/4] Verificando puerto 8080..." -ForegroundColor Yellow
$connection = Get-NetTCPConnection -LocalPort 8080 -ErrorAction SilentlyContinue
if ($connection) {
    $processId = $connection.OwningProcess
    $processName = (Get-Process -Id $processId -ErrorAction SilentlyContinue).ProcessName
    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] Puerto 8080 liberado (proceso: $processName, PID: $processId)" -ForegroundColor Green
} else {
    Write-Host "[INFO] Puerto 8080 esta libre" -ForegroundColor Gray
}

# Esperar un momento para que se liberen los recursos
Start-Sleep -Seconds 1

Write-Host ""
Write-Host "[DONE] Limpieza completada!" -ForegroundColor Green
Write-Host ""
Write-Host "Ahora puedes ejecutar:" -ForegroundColor Cyan
Write-Host "  go run .\cmd\server\" -ForegroundColor White
Write-Host ""
