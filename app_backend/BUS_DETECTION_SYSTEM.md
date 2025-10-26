# 🚌 Detección de Buses que Pasaron - Red.cl

## 🎯 Funcionalidad

El scraper ahora detecta automáticamente cuando un bus **pasó por el paradero** comparando consultas sucesivas.

## 📊 Casos Detectados

### Caso 1: Bus Desapareció
```
Consulta 1: C01 a 0.5km
Consulta 2: C01 no aparece
→ Resultado: "C01 pasó por el paradero"
```

### Caso 2: Bus Reinició Ruta
```
Consulta 1: 409 a 0.8km
Consulta 2: 409 a 7.2km
→ Resultado: "409 pasó y comenzó nueva vuelta"
```

## 🔧 Implementación

### Estructura de Caché
```go
type busCache struct {
    RouteNumber string
    DistanceKm  float64
    LastSeen    time.Time
}
```

### Lógica de Detección

1. **Bus desaparece**: Si estaba a ≤ 2km y ya no aparece → **Pasó**
2. **Bus se aleja**: Si estaba a ≤ 1km y ahora está a > 5km → **Pasó y reinició**
3. **Timeout**: Caché se limpia cada 15 minutos

## 📝 Ejemplo de Respuesta

### Primera Consulta
```bash
curl "http://localhost:8080/api/bus-arrivals/PC615"
```

```json
{
  "stop_code": "PC615",
  "stop_name": "Av. Las Condes / esq. La Cabaña",
  "arrivals": [
    {
      "route_number": "C01",
      "distance_km": 0.5
    },
    {
      "route_number": "409",
      "distance_km": 1.2
    }
  ],
  "last_updated": "2025-10-25T14:30:00Z"
}
```

### Segunda Consulta (30 segundos después)
```json
{
  "stop_code": "PC615",
  "stop_name": "Av. Las Condes / esq. La Cabaña",
  "arrivals": [
    {
      "route_number": "409",
      "distance_km": 0.9
    },
    {
      "route_number": "C13",
      "distance_km": 3.5
    }
  ],
  "busses_passed": ["C01"],
  "last_updated": "2025-10-25T14:30:30Z"
}
```

## 🎯 Casos de Uso

### 1. Notificación en Tiempo Real
```javascript
async function monitorBusStop(stopCode) {
  const response = await fetch(`http://localhost:8080/api/bus-arrivals/${stopCode}`);
  const data = await response.json();
  
  if (data.busses_passed && data.busses_passed.length > 0) {
    // Notificar al usuario
    for (const bus of data.busses_passed) {
      notify(`¡El bus ${bus} acaba de pasar!`);
    }
  }
}

// Consultar cada 30 segundos
setInterval(() => monitorBusStop('PC615'), 30000);
```

### 2. Registro de Historial
```python
import requests
import time

def track_bus_arrivals(stop_code, duration_minutes=60):
    """Rastrea buses durante X minutos"""
    end_time = time.time() + (duration_minutes * 60)
    passed_buses = []
    
    while time.time() < end_time:
        response = requests.get(f'http://localhost:8080/api/bus-arrivals/{stop_code}')
        data = response.json()
        
        if 'busses_passed' in data and data['busses_passed']:
            for bus in data['busses_passed']:
                passed_buses.append({
                    'route': bus,
                    'time': data['last_updated']
                })
                print(f"✓ Bus {bus} pasó a las {data['last_updated']}")
        
        time.sleep(30)  # Consultar cada 30 segundos
    
    return passed_buses

# Ejemplo
history = track_bus_arrivals('PC615', duration_minutes=10)
print(f"Total de buses detectados: {len(history)}")
```

### 3. App de Accesibilidad
```javascript
// Para usuarios con discapacidad visual
let lastBusses = new Set();

async function announceUpdates(stopCode) {
  const data = await fetch(`http://localhost:8080/api/bus-arrivals/${stopCode}`)
    .then(r => r.json());
  
  // Anunciar buses que pasaron
  if (data.busses_passed && data.busses_passed.length > 0) {
    for (const bus of data.busses_passed) {
      speak(`El bus ${bus} acaba de pasar por el paradero`);
    }
  }
  
  // Anunciar buses que se acercan (< 1km)
  const approaching = data.arrivals.filter(a => a.distance_km < 1.0);
  if (approaching.length > 0) {
    const routes = approaching.map(a => a.route_number).join(', ');
    speak(`Buses próximos: ${routes}`);
  }
}

// Actualizar cada 20 segundos
setInterval(() => announceUpdates('PC615'), 20000);
```

## ⚙️ Configuración

### Umbrales Ajustables

Puedes modificar estos valores en `scraper.go`:

```go
// Detección de buses que pasaron
const (
    DISTANCE_THRESHOLD_DISAPPEAR = 2.0  // km - bus desaparece si estaba ≤ 2km
    DISTANCE_THRESHOLD_CLOSE     = 1.0  // km - bus estaba cerca
    DISTANCE_THRESHOLD_FAR       = 5.0  // km - bus ahora está lejos
    CACHE_TIMEOUT               = 15    // minutos - tiempo de caché
    MAX_TIME_SINCE_SEEN         = 10    // minutos - máximo para considerar
)
```

## 📊 Logs del Servidor

```
🔍 [PARSER] Iniciando parseo del HTML
  ✓ Bus: C01 (0.5km)
  ✓ Bus: 409 (1.2km)
📊 [PARSER] Total parseado: 2 llegadas únicas
🚌 [PASSED] Bus C01 desapareció (estaba a 0.5km)
✅ [RED.CL] Encontradas 2 llegadas para PC615
```

## 🧪 Testing

### Script de Monitoreo (PowerShell)
```powershell
$stopCode = "PC615"
$previousBusses = @()

while ($true) {
    $data = curl "http://localhost:8080/api/bus-arrivals/$stopCode" | ConvertFrom-Json
    
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Paradero $stopCode" -ForegroundColor Cyan
    
    # Mostrar buses que pasaron
    if ($data.busses_passed -and $data.busses_passed.Count -gt 0) {
        Write-Host "  🚌 PASARON: $($data.busses_passed -join ', ')" -ForegroundColor Yellow
    }
    
    # Mostrar buses actuales
    Write-Host "  📍 Actuales:" -ForegroundColor Green
    foreach ($bus in $data.arrivals) {
        Write-Host "     • $($bus.route_number): $($bus.distance_km)km"
    }
    
    Start-Sleep -Seconds 30
}
```

### Script de Monitoreo (Bash)
```bash
#!/bin/bash
stop_code="PC615"

while true; do
    echo -e "\n[\033[36m$(date +%H:%M:%S)\033[0m] Paradero $stop_code"
    
    response=$(curl -s "http://localhost:8080/api/bus-arrivals/$stop_code")
    
    # Buses que pasaron
    passed=$(echo "$response" | jq -r '.busses_passed[]? // empty')
    if [ ! -z "$passed" ]; then
        echo -e "  \033[33m🚌 PASARON: $passed\033[0m"
    fi
    
    # Buses actuales
    echo -e "  \033[32m📍 Actuales:\033[0m"
    echo "$response" | jq -r '.arrivals[] | "     • \(.route_number): \(.distance_km)km"'
    
    sleep 30
done
```

## 🔔 Integraciones

### Webhook Notification
```javascript
async function sendNotification(stopCode) {
  const data = await fetch(`http://localhost:8080/api/bus-arrivals/${stopCode}`)
    .then(r => r.json());
  
  if (data.busses_passed && data.busses_passed.length > 0) {
    // Enviar a Discord/Slack/etc
    await fetch('https://discord.com/api/webhooks/YOUR_WEBHOOK', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        content: `🚌 Buses que pasaron en ${stopCode}: ${data.busses_passed.join(', ')}`
      })
    });
  }
}
```

## ⚠️ Notas Importantes

1. **Primera consulta**: No detecta buses pasados (no hay caché previo)
2. **Frecuencia**: Consultar cada 20-30 segundos para mejor detección
3. **Precisión**: Depende de la actualización de Red.cl
4. **Caché**: Se limpia automáticamente después de 15 minutos
5. **Thread-safe**: Usa mutex para acceso concurrente seguro

## 🎯 Ventajas

✅ Detecta buses que pasaron sin necesidad de GPS  
✅ No requiere API adicional  
✅ Funciona solo con web scraping  
✅ Caché automático con limpieza  
✅ Thread-safe para múltiples usuarios  
✅ Útil para notificaciones en tiempo real  

---

**Tip**: Combina esto con notificaciones push en tu app móvil para alertar a usuarios con discapacidad visual cuando su bus acaba de pasar.
