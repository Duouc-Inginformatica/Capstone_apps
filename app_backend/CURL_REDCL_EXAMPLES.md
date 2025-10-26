# 🚌 Ejemplos cURL - Scraper Red.cl

## 🔧 Mejoras Implementadas

✅ **Detección automática de navegadores** (Edge, Chrome, Brave, Chromium)  
✅ **Modo headless** (sin ventana visible)  
✅ **URL correcta de Red.cl** (`?codsimt=PC615`)  
✅ **Parser mejorado** para estructura HTML de Red.cl  
✅ **Extracción precisa** de: ruta, dirección, distancia, tiempo, estado

---

## 📍 Ejemplo Básico

```bash
curl "http://localhost:8080/api/bus-arrivals/PC615"
```

### Respuesta Esperada
```json
{
  "stop_code": "PC615",
  "stop_name": "Avenida Las Condes / esq. La Cabaña",
  "arrivals": [
    {
      "route_number": "C01",
      "direction": "Metro Francisco Bilbao",
      "distance_km": 0.3,
      "estimated_minutes": 0,
      "estimated_time": "",
      "status": "Llegando"
    },
    {
      "route_number": "C13",
      "direction": "Cantagallo",
      "distance_km": 7.4,
      "estimated_minutes": 19,
      "estimated_time": "",
      "status": "Distante"
    },
    {
      "route_number": "C19",
      "direction": "Metro Escuela Militar",
      "distance_km": 0.2,
      "estimated_minutes": 4,
      "estimated_time": "",
      "status": "Muy cerca"
    }
  ],
  "last_updated": "2025-10-25T15:45:00Z"
}
```

---

## 🎯 Casos de Prueba

### 1. Paradero con buses llegando
```bash
curl "http://localhost:8080/api/bus-arrivals/PC615"
```

### 2. Paradero con formato JSON pretty
```bash
curl -s "http://localhost:8080/api/bus-arrivals/PC615" | python -m json.tool
```

### 3. PowerShell con formato
```powershell
(curl "http://localhost:8080/api/bus-arrivals/PC615" | ConvertFrom-Json) | ConvertTo-Json -Depth 5
```

### 4. Extraer solo rutas próximas (< 5 min)
```bash
curl -s "http://localhost:8080/api/bus-arrivals/PC615" | jq '.arrivals[] | select(.estimated_minutes < 5)'
```

### 5. Ver solo buses "Llegando"
```bash
curl -s "http://localhost:8080/api/bus-arrivals/PC615" | jq '.arrivals[] | select(.status == "Llegando")'
```

---

## 🔍 Análisis de Datos

### Contar buses disponibles
```bash
curl -s "http://localhost:8080/api/bus-arrivals/PC615" | jq '.arrivals | length'
```

### Listar todas las rutas
```bash
curl -s "http://localhost:8080/api/bus-arrivals/PC615" | jq -r '.arrivals[].route_number'
```

### Bus más cercano
```bash
curl -s "http://localhost:8080/api/bus-arrivals/PC615" | jq '.arrivals[0]'
```

---

## 🚦 Estados Posibles

| Estado | Descripción | Minutos |
|--------|-------------|---------|
| `Llegando` | Bus a punto de llegar | ≤ 2 min |
| `Muy cerca` | Bus muy próximo | 3-5 min |
| `En camino` | Bus aproximándose | 6-10 min |
| `Distante` | Bus lejano | > 10 min |
| `Fuera de servicio` | Ruta sin servicio | N/A |

---

## 📊 Monitoreo en Tiempo Real

### Loop cada 30 segundos (Bash)
```bash
while true; do
  clear
  echo "🚌 Buses en PC615 - $(date)"
  curl -s "http://localhost:8080/api/bus-arrivals/PC615" | jq '.arrivals[] | "\(.route_number): \(.estimated_minutes)min - \(.status)"'
  sleep 30
done
```

### Loop cada 30 segundos (PowerShell)
```powershell
while ($true) {
    Clear-Host
    Write-Host "🚌 Buses en PC615 - $(Get-Date)" -ForegroundColor Cyan
    $data = curl "http://localhost:8080/api/bus-arrivals/PC615" | ConvertFrom-Json
    $data.arrivals | ForEach-Object {
        Write-Host "$($_.route_number): $($_.estimated_minutes)min - $($_.status)"
    }
    Start-Sleep -Seconds 30
}
```

---

## 🛠️ Troubleshooting

### ❌ Error: "No se encontró navegador compatible"
**Solución**: Instalar Edge (viene por defecto en Windows 10/11) o Chrome:
- Edge: Ya instalado en Windows
- Chrome: https://www.google.com/chrome/

### ❌ Error: "No arrivals found"
**Posibles causas**:
1. Código de paradero inválido
2. Paradero sin servicio actualmente
3. JavaScript no cargó a tiempo

**Solución**:
- Verificar código en https://www.red.cl/planifica-tu-viaje/cuando-llega/?codsimt=PC615
- Esperar 30 segundos y reintentar

### ❌ Error: "timeout"
**Solución**: Aumentar timeout en scraper o verificar conexión a internet

---

## 💡 Integración con Apps

### JavaScript/TypeScript
```typescript
async function getBusArrivals(stopCode: string) {
  const response = await fetch(`http://localhost:8080/api/bus-arrivals/${stopCode}`);
  const data = await response.json();
  
  const nextBus = data.arrivals[0];
  console.log(`Próximo bus: ${nextBus.route_number} en ${nextBus.estimated_minutes} min`);
  
  return data;
}

getBusArrivals('PC615');
```

### Python
```python
import requests

def get_bus_arrivals(stop_code):
    response = requests.get(f'http://localhost:8080/api/bus-arrivals/{stop_code}')
    data = response.json()
    
    for arrival in data['arrivals']:
        print(f"{arrival['route_number']}: {arrival['estimated_minutes']}min - {arrival['status']}")
    
    return data

get_bus_arrivals('PC615')
```

---

## 📱 Uso en App de Accesibilidad

```javascript
// Para usuarios con discapacidad visual
async function announceNextBus(stopCode) {
  const data = await fetch(`http://localhost:8080/api/bus-arrivals/${stopCode}`).then(r => r.json());
  
  if (data.arrivals.length === 0) {
    speak("No hay buses próximos en este paradero");
    return;
  }
  
  const next = data.arrivals[0];
  const message = `El próximo bus es el ${next.route_number}, 
                   hacia ${next.direction}, 
                   llegará en ${next.estimated_minutes} minutos`;
  
  speak(message);
}
```

---

## 🔗 Enlaces Útiles

- Red.cl: https://www.red.cl/planifica-tu-viaje/cuando-llega/
- GTFS Santiago: https://www.dtpm.cl/
- API Docs: http://localhost:8080/api/health

---

**Nota**: El scraper funciona con Edge (pre-instalado en Windows), Chrome, Brave o Chromium en modo headless (sin ventana visible).
